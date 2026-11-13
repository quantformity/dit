// The network commands: serve, clone, connect, disconnect.
//
// `dit serve` publishes the local portfolio over a small HTTP protocol
// (internal/remote); `dit connect` remembers a remote as the active target so
// the ordinary commands run against it; `dit clone` pulls a remote portfolio
// into the local stores; `dit disconnect` clears the target.
package cli

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"dit/internal/bundle"
	"dit/internal/config"
	"dit/internal/model"
	"dit/internal/remote"
	"dit/internal/store"
	"github.com/mattn/go-isatty"
)

var netSpecs = Registry{
	"serve":      {Run: serveCommand, SkipParse: true, HelpText: serveHelp},
	"clone":      {Run: cloneCommand, SkipParse: true, HelpText: cloneHelp},
	"connect":    {Run: connectCommand, SkipParse: true, HelpText: connectHelp},
	"disconnect": {Run: disconnectCommand, SkipParse: true, HelpText: disconnectHelp},
	"upgrade":    {Run: upgradeCommand, SkipParse: true, HelpText: upgradeHelp},
}

// remoteBannerExcluded are the commands that do not run against the saved
// connection: the connection managers name their own target, serve publishes
// the local stores, upgrade is local housekeeping, and config edits the
// local file.
func remoteBannerExcluded(name string) bool {
	switch name {
	case "serve", "connect", "disconnect", "clone", "upgrade":
		return true
	}
	return strings.HasPrefix(name, "config ") || name == "config"
}

// printRemoteBanner prefixes the output of a command that runs against the
// saved connection, so a remote result is never mistaken for a local one.
// JSON mode keeps stdout machine-readable: the tag goes to stderr.
func (c Context) printRemoteBanner() {
	if c.Layout.RemoteTarget == "" {
		return
	}
	line := remoteBannerLine(c.Layout.RemoteTarget, c.Layout.RemoteReadOnly)
	if c.JSON {
		fmt.Fprintln(c.Err, line)
		return
	}
	if isatty.IsTerminal(os.Stdout.Fd()) {
		c.printf("\x1b[1;36m%s\x1b[0m\n", line) // bold cyan
		return
	}
	c.printf("%s\n", line)
}

// remoteBannerLine builds the one-line tag for a connection target. The
// target may be a raw HOST:PORT or a full URL (env var, saved config);
// the tag always shows the clean address and port.
func remoteBannerLine(target string, readOnly bool) string {
	mutation := "mutable"
	if readOnly {
		mutation = "read-only"
	}
	address, _, err := remote.NormalizeTarget(target)
	if err != nil {
		address = target
	}
	return "━━━ 🌐 REMOTE " + address + " · " + mutation + " ━━━"
}

// storeLocationLabel is the line a command prints after writing: the local
// portfolio path or remote address while a connection is active. The key
// selects the document so the two local stores keep distinct labels.
func (c Context) storeLocationLabel(key string) string {
	if c.Layout.RemoteTarget == "" {
		if key == store.MarketKey {
			return absolute(c.Layout.MarketDir)
		}
		return absolute(c.Layout.PortfolioDir)
	}
	address, _, err := remote.NormalizeTarget(c.Layout.RemoteTarget)
	if err != nil {
		address = c.Layout.RemoteTarget
	}
	return "remote://" + address + "/" + key
}

// localContext returns a copy of the context that ignores the saved
// connection: serve, clone and the connection managers act on the local
// stores no matter what is connected.
func localContext(c Context) Context {
	layout := c.Layout
	layout.RemoteTarget = ""
	layout.RemoteToken = ""
	layout.RemoteReadOnly = false
	c.Layout = layout
	return c
}

func generateToken() (string, error) {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw), nil
}

// The run-endpoint allowlist. Reads are always served; the market-write
// commands (the refetchable price cache) only on a mutable server. The
// ledger is never written through the endpoint: portfolio editing stays with
// the CLI on the machine that owns the data.
var runReadCommands = map[string]bool{
	"summary": true, "accounts": true, "account list": true, "account show": true,
	"pnl": true, "income": true, "quote": true,
	"market coverage": true, "market history": true, "market show": true,
	"tx list": true, "tx show": true,
	"ticker list": true, "ticker show": true,
	"store path": true,
}

var runWriteCommands = map[string]bool{
	"market latest":   true,
	"market backfill": true,
	"update":          true,
}

// NewServeRunner builds the in-process command runner for the serve run
// endpoint: it dispatches commands against the given documents with the given
// layout (used for the location labels in reports).
func NewServeRunner(ledger, market store.Store, layout config.Layout, immutable bool, version string) remote.Runner {
	return &serveRunner{ledger: ledger, market: market, layout: layout, immutable: immutable, version: version}
}

// serveRunner executes the run endpoint in-process. It runs the command
// through the same Dispatch the CLI uses, with the served documents
// installed as Context.StoreSource: the commands read and write exactly the
// documents the server serves, and the store-opening fallbacks (local files,
// the saved connection) never fire.
type serveRunner struct {
	ledger    store.Store
	market    store.Store
	layout    config.Layout
	immutable bool
	version   string
}

// liftRunGlobals extracts the global options the run endpoint controls.
// --json is always forced — the endpoint exists for machine consumers, so the
// response is always dit's --json envelope. --offline and --display pass
// through; every other word stays in place as the command's own argument.
func liftRunGlobals(args []string) (offline bool, display model.Currency, displaySet bool, rest []string) {
	display = model.Currency("CAD")
	rest = make([]string, 0, len(args))
	for i := 0; i < len(args); i++ {
		name, inline, hasInline := strings.Cut(args[i], "=")
		switch name {
		case "--offline":
			offline = true
		case "--json":
			// forced by the endpoint; an explicit --json is a no-op
		case "--display":
			value := inline
			consumed := false
			if !hasInline {
				if i+1 >= len(args) {
					rest = append(rest, args[i]) // malformed; the command's parser reports it
					continue
				}
				i++
				value = args[i]
				consumed = true
			}
			normalized := strings.ToUpper(strings.TrimSpace(value))
			for _, known := range KnownDisplayCurrencies() {
				if string(known) == normalized {
					display = known
					displaySet = true
					break
				}
			}
			if displaySet {
				continue
			}
			// unknown code: pass the words through — the command reports it
			rest = append(rest, args[i])
			if consumed {
				rest = append(rest, value)
			}
		default:
			rest = append(rest, args[i])
		}
	}
	return
}

// runRefusal renders the --json failure envelope a refused command must
// return: one document, keys alphabetical, matching docs/json.md. Marshalled
// (not formatted) so the message can carry any characters.
func runRefusal(kind, message string) (int, string, string) {
	envelope, _ := json.Marshal(map[string]any{"ok": false, "kind": kind, "error": message})
	return 2, string(envelope), ""
}

func (r *serveRunner) Run(args []string) (int, string, string) {
	name := ResolveCommandName(args)
	if name == "" {
		return runRefusal("usage", "no command — the run endpoint takes {\"args\": [\"command\", …]}, e.g. {\"args\": [\"summary\"]}")
	}
	if runWriteCommands[name] {
		if r.immutable {
			return runRefusal("runtime", "'"+name+"' would change the market data — this server is running with --immutable")
		}
	} else if !runReadCommands[name] {
		return runRefusal("usage", "'"+name+"' is not available on the remote — available: "+r.availableList())
	}
	offline, display, displaySet, rest := liftRunGlobals(args)
	var stdout, stderr bytes.Buffer
	// --json is forced where a schema is documented; where it is not (the
	// market-write commands), the command runs in its normal text mode and
	// the client gets the rendered output verbatim.
	ctx := Context{
		Layout:     r.layout,
		Version:    r.version,
		JSON:       JSONDocumented(name),
		Offline:    offline,
		Display:    display,
		DisplaySet: displaySet,
		Out:        &stdout,
		Err:        &stderr,
		StoreSource: func() (store.Store, store.Store, error) {
			return r.ledger, r.market, nil
		},
	}
	code := Dispatch(ctx, rest)
	return code, stdout.String(), stderr.String()
}

// KeepsLock reports whether this run mutates the market document, so the
// server holds its lock for the whole read-modify-write: market-write
// commands fetch from the network and then save, and a concurrent document
// PUT landing between the read and the write would be silently lost.
func (r *serveRunner) KeepsLock(args []string) bool {
	return !r.immutable && runWriteCommands[ResolveCommandName(args)]
}

// availableList is the refusal text for THIS server (writes only when it is
// mutable).
func (r *serveRunner) availableList() string {
	var names []string
	for name := range runReadCommands {
		names = append(names, "'"+name+"'")
	}
	if !r.immutable {
		for name := range runWriteCommands {
			names = append(names, "'"+name+"'")
		}
	}
	sort.Strings(names)
	return strings.Join(names, ", ")
}

// serveCommand publishes the local stores: `dit serve [PORT]`.
func serveCommand(c Context, args []string) error {
	o, err := ParseOptions(args, map[string]bool{"token": true, "host": true}, map[string]bool{"immutable": true})
	if err != nil {
		return err
	}
	if len(o.Positionals) > 1 {
		return usage("unexpected argument '" + o.Positionals[1] + "' — use: dit serve [PORT] [--host ADDR] [--token TOKEN] [--immutable]")
	}
	port := remote.DefaultServePort
	if len(o.Positionals) == 1 {
		n, convErr := strconv.Atoi(o.Positionals[0])
		if convErr != nil || n < 1 || n > 65535 {
			return usage(fmt.Sprintf("'%s' is not a port (1–65535)", o.Positionals[0]))
		}
		port = n
	}
	host := o.Value("host")
	if host == "" {
		host = "0.0.0.0"
	}
	if c.JSON {
		return usage("--json is not supported for 'serve' — it runs until you stop it")
	}

	// serve always publishes the LOCAL stores, never the connected remote.
	lc := localContext(c)
	ledger, market, err := lc.Stores()
	if err != nil {
		return Runtime("cannot open the local stores: " + err.Error())
	}
	token := o.Value("token")
	tokenGenerated := false
	if _, specified := o.Values["token"]; specified && token == "" {
		token, err = generateToken()
		if err != nil {
			return Runtime("cannot generate a token: " + err.Error())
		}
		tokenGenerated = true
	}

	listener, err := net.Listen("tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		return Runtime("cannot listen on " + net.JoinHostPort(host, strconv.Itoa(port)) + ": " + err.Error())
	}
	defer listener.Close()
	handler := remote.NewServer(ledger, market, token, o.Has("immutable"), c.Version)
	// The run endpoint executes commands in-process on the served documents:
	// this is what lets a remote UI (the iPhone client) render real dit
	// reports instead of raw store bytes.
	handler.SetRunner(NewServeRunner(ledger, market, lc.Layout, o.Has("immutable"), c.Version))
	// Announce clients as they arrive and log each request, so the person
	// running the server can see exactly who is reading or changing the
	// portfolio, in real time.
	// ready gates the first log line on the banner.
	ready := make(chan struct{})
	log := &serveRequestLog{c: c, ready: ready}
	server := &http.Server{Handler: log.Wrap(handler), ReadHeaderTimeout: 10 * time.Second}
	serveErr := make(chan error, 1)
	go func() {
		serveErr <- server.Serve(listener)
	}()

	// Banner: where to reach it, how to connect, what clients may do.
	if host == "0.0.0.0" {
		c.printf("🌐 dit serve — the local portfolio is now reachable at %s\n", serveAddress(port))
	} else {
		c.printf("🌐 dit serve — the local portfolio is now reachable at %s\n", net.JoinHostPort(host, strconv.Itoa(port)))
	}
	if token != "" {
		tokenNote := ""
		if tokenGenerated {
			tokenNote = " (generated)"
		}
		c.printf("   token: %s%s\n", token, tokenNote)
		c.printf("   clients: dit connect %s --token %s\n", serveAddress(port), token)
	} else {
		writable := ""
		if !o.Has("immutable") {
			writable = " and change it"
		}
		c.printf("   ⚠ no authentication — anyone who can reach this port can read the portfolio%s\n", writable)
		c.printf("   use --token to require authentication; serve only on a trusted network\n")
	}
	if o.Has("immutable") {
		c.printf("   read-only: remote commands can read but not change the portfolio\n")
	} else {
		c.printf("   mutable: remote commands can change the portfolio (re-run with --immutable to forbid that)\n")
	}
	c.printf("   store: %s\n", lc.PortfolioLocation())
	c.printf("   client connections and requests are logged as they happen\n")
	c.printf("   press Ctrl-C to stop\n")
	close(ready)

	interrupt := make(chan os.Signal, 1)
	signal.Notify(interrupt, os.Interrupt)
	select {
	case sig := <-interrupt:
		_ = server.Close()
		signal.Stop(interrupt)
		c.printf("stopped (%s) — the portfolio is no longer being served\n", sig)
	case err := <-serveErr:
		signal.Stop(interrupt)
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			return Runtime("serve stopped: " + err.Error())
		}
	}
	return nil
}

// serveRequestLog is the serve-side activity log: the first request from a
// client IP is announced as a connection, and every request (with the
// server's status) is logged, so the host can see who is reading or changing
// the portfolio in real time. Clients are keyed by IP, not by the ephemeral
// socket address: a reconnecting client must not be re-announced. The ready
// channel (closed once the banner has printed) keeps the log ordered after
// the banner even if a request arrives before it.
type serveRequestLog struct {
	c     Context
	ready chan struct{}
	mu    sync.Mutex
	seen  map[string]bool
}

// Wrap returns a handler that logs every request, announcing a client on
// first sight.
func (l *serveRequestLog) Wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil {
			ip = r.RemoteAddr
		}
		l.mu.Lock()
		if l.seen == nil {
			l.seen = map[string]bool{}
		}
		first := !l.seen[ip]
		l.seen[ip] = true
		l.mu.Unlock()
		if first {
			<-l.ready
			l.c.printf("🔗 client %s connected\n", ip)
		}
		sw := &statusWriter{ResponseWriter: w, status: 200}
		next.ServeHTTP(sw, r)
		l.c.printf("→ %s  %s %s  %d\n", ip, r.Method, r.URL.Path, sw.status)
	})
}

// statusWriter records the response status for the activity log.
type statusWriter struct {
	http.ResponseWriter
	status int
}

func (w *statusWriter) WriteHeader(code int) {
	w.status = code
	w.ResponseWriter.WriteHeader(code)
}

// serveAddress picks the first non-loopback IPv4 for the user-facing line.
func serveAddress(port int) string {
	suffix := ":" + strconv.Itoa(port)
	if addrs, err := net.InterfaceAddrs(); err == nil {
		for _, a := range addrs {
			if ipnet, ok := a.(*net.IPNet); ok && !ipnet.IP.IsLoopback() && ipnet.IP.To4() != nil {
				return ipnet.IP.String() + suffix
			}
		}
	}
	return "127.0.0.1" + suffix
}

// connectCommand saves a remote as the active target: `dit connect HOST:PORT`.
func connectCommand(c Context, args []string) error {
	o, err := ParseOptions(args, map[string]bool{"token": true}, nil)
	if err != nil {
		return err
	}
	if len(o.Positionals) > 1 {
		return usage("unexpected argument '" + o.Positionals[1] + "' — use: dit connect HOST:PORT [--token TOKEN]")
	}
	saved, err := config.LoadRemoteConnection()
	if err != nil {
		return Runtime("cannot read the user config: " + err.Error())
	}
	target := saved.URL
	token := ""
	if len(o.Positionals) == 1 {
		target = o.Positionals[0]
		// Reconnecting to the saved target keeps its token: a plain
		// 'dit connect 1.2.3.4' after a token-authenticated connect must
		// not silently drop the credential.
		if saved.URL != "" {
			targetAddr, _, terr := remote.NormalizeTarget(target)
			savedAddr, _, serr := remote.NormalizeTarget(saved.URL)
			if terr == nil && serr == nil && targetAddr == savedAddr {
				token = saved.Token
			}
		}
	} else {
		if saved.URL == "" {
			return usage("no target — usage: dit connect HOST:PORT [--token TOKEN]")
		}
		token = saved.Token // re-verifying a saved connection keeps its token
	}
	if value, ok := o.Values["token"]; ok {
		token = value
	}
	conn, err := remote.NewConnection(target, token, false)
	if err != nil {
		return usage(err.Error())
	}
	info, err := conn.Verify()
	if err != nil {
		if clientErr, ok := err.(*remote.ClientError); ok && clientErr.Status == http.StatusUnauthorized {
			return Runtime("the remote at " + conn.Address + " requires a token — re-run: dit connect " + conn.Address + " --token <TOKEN>")
		}
		return Runtime("cannot reach the remote at " + conn.Address + ": " + err.Error())
	}
	if err := config.SaveRemoteConnection(config.RemoteConnection{
		URL:      conn.Address, // canonical user-facing form: HOST:PORT
		Token:    token,
		ReadOnly: info.Immutable,
	}); err != nil {
		return Runtime("connected to " + conn.Address + " but could not save the connection: " + err.Error())
	}
	// The banner belongs to the NEW connection state, so it is printed by the
	// command (and by every later command through the dispatch hook).
	if isatty.IsTerminal(os.Stdout.Fd()) {
		c.printf("\x1b[1;36m%s\x1b[0m\n", remoteBannerLine(conn.Address, info.Immutable))
	} else {
		c.printf("%s\n", remoteBannerLine(conn.Address, info.Immutable))
	}
	mode := ""
	if info.Immutable {
		mode = " (read-only: it is running with --immutable)"
	} else {
		mode = " (it accepts changes)"
	}
	c.printf("Connected — subsequent commands run against the remote portfolio%s.\n", mode)
	if info.Version != "" {
		c.printf("Server: dit %s\n", info.Version)
	}
	if info.AuthEnabled {
		c.printf("Authentication: on (the token is saved in %s)\n", config.RemoteConfigPath())
	} else {
		c.printf("Authentication: off — the server accepts anyone on the network\n")
	}
	c.printf("Stop with 'dit disconnect'. 'dit clone %s' pulls it into the local stores.\n", conn.Address)
	return nil
}

// disconnectCommand clears the saved target.
func disconnectCommand(c Context, args []string) error {
	o, err := ParseOptions(args, nil, nil)
	if err != nil {
		return err
	}
	if err := o.RejectStrayPositionals("dit disconnect"); err != nil {
		return err
	}
	saved, err := config.LoadRemoteConnection()
	if err != nil {
		return Runtime("cannot read the user config: " + err.Error())
	}
	if saved.URL == "" {
		return Runtime("not connected — there is no saved remote (see 'dit connect')")
	}
	address, _, err := remote.NormalizeTarget(saved.URL)
	if err != nil {
		address = saved.URL
	}
	if err := config.ClearRemoteConnection(); err != nil {
		return Runtime("cannot update the user config: " + err.Error())
	}
	c.printf("Disconnected from %s — commands now use the local stores again.\n", address)
	if saved.ReadOnly {
		c.printf("Note: the remote was read-only; its data was never changed locally.\n")
	}
	return nil
}

// cloneCommand pulls a remote portfolio into the local stores:
// `dit clone [HOST:PORT]`. Without a target it clones the saved connection.
func cloneCommand(c Context, args []string) error {
	o, err := ParseOptions(args, map[string]bool{"token": true}, map[string]bool{"yes": true, "force": true})
	if err != nil {
		return err
	}
	if len(o.Positionals) > 1 {
		return usage("unexpected argument '" + o.Positionals[1] + "' — use: dit clone [HOST:PORT] [--token TOKEN] [--yes] [--force]")
	}
	saved, err := config.LoadRemoteConnection()
	if err != nil {
		return Runtime("cannot read the user config: " + err.Error())
	}
	var target, token string
	if len(o.Positionals) == 1 {
		target = o.Positionals[0]
	} else {
		target = saved.URL
	}
	if target == "" {
		return usage("no remote to clone — pass HOST:PORT, or 'dit connect' first")
	}
	if value, ok := o.Values["token"]; ok {
		token = value
	} else {
		// Reuse the saved token when this target is the saved connection.
		if targetAddr, _, err := remote.NormalizeTarget(target); err == nil && saved.URL != "" {
			if savedAddr, _, err := remote.NormalizeTarget(saved.URL); err == nil && targetAddr == savedAddr {
				token = saved.Token
			}
		}
	}
	conn, err := remote.NewConnection(target, token, false)
	if err != nil {
		return usage(err.Error())
	}
	info, err := conn.Verify()
	if err != nil {
		if clientErr, ok := err.(*remote.ClientError); ok && clientErr.Status == http.StatusUnauthorized {
			return Runtime("the remote at " + conn.Address + " requires a token — re-run with --token <TOKEN>")
		}
		return Runtime("cannot reach the remote at " + conn.Address + ": " + err.Error())
	}
	raw, err := conn.Bundle()
	if err != nil {
		return Runtime("the remote at " + conn.Address + " has no cloneable portfolio: " + err.Error())
	}
	d, err := bundle.Decode(raw)
	if err != nil {
		return Runtime("the bundle from " + conn.Address + " is not readable: " + err.Error())
	}

	// Clone writes the LOCAL stores, whatever is connected.
	lc := localContext(c)
	p, m, err := transferLoad(lc)
	if err != nil {
		return err
	}
	if p == nil {
		p = &model.Portfolio{}
	}
	applied, err := bundle.Apply(d, *p, m, bundle.Replace)
	if err != nil {
		return usage(err.Error())
	}
	if !applied.WritesPortfolio && !applied.WritesMarket {
		c.printf("Nothing to clone — the remote at %s has no data.\n", conn.Address)
		return nil
	}

	// The changed-under-you guard must span the WHOLE replace: capture the
	// current local bytes before the confirmation prompt and the backup, so
	// a local change landing during that window aborts the clone instead of
	// being silently overwritten.
	origP, err := transferRead(lc, lc.Layout.PortfolioDir, store.PortfolioKey)
	if err != nil {
		return err
	}
	origM, err := transferRead(lc, lc.Layout.MarketDir, store.MarketKey)
	if err != nil {
		return err
	}

	changes := []string{}
	if applied.WritesPortfolio {
		changes = append(changes, fmt.Sprintf("the local portfolio (%d account(s), %d transaction(s))",
			len(applied.Portfolio.Accounts), len(applied.Portfolio.Transactions)))
	}
	if applied.WritesMarket {
		changes = append(changes, fmt.Sprintf("the local market data (%d daily close(s))", applied.Market.TotalPoints()))
	}
	question := "Replace " + strings.Join(changes, " and ") + " with the remote portfolio at " + conn.Address + "?"
	if err := transferConfirm(lc, question, o.Has("yes"), true); err != nil {
		return err
	}
	if !o.Has("force") {
		copies, err := backupForRestore(lc)
		if err != nil {
			fmt.Fprintf(lc.Err, "warning: automatic pre-clone backup failed: %v — continuing without a backup\n", err)
		} else if len(copies) > 0 {
			lc.printf("Local stores backed up before clone:\n")
			for _, p := range copies {
				lc.printf("  → %s\n", p)
			}
		}
	}
	// Guard against local changes landing between the read and the replace.
	var ledger *model.Portfolio
	var prices *model.MarketData
	if applied.WritesPortfolio {
		ledger = &applied.Portfolio
	}
	if applied.WritesMarket {
		prices = &applied.Market
	}
	if ledger != nil {
		if err := changedUnderYou(lc, origP, lc.Layout.PortfolioDir, store.PortfolioKey, "portfolio"); err != nil {
			return err
		}
	}
	if prices != nil {
		if err := changedUnderYou(lc, origM, lc.Layout.MarketDir, store.MarketKey, "market data"); err != nil {
			return err
		}
	}
	if err := transferSave(lc, ledger, prices); err != nil {
		return Runtime("could not write the local stores: " + err.Error())
	}
	for _, n := range applied.Notes {
		lc.printf("  %s\n", n)
	}
	c.printf("%s\n", remoteBannerLine(conn.Address, info.Immutable))
	c.printf("Cloned the remote portfolio from %s into the local stores.\n", conn.Address)
	if ledger != nil {
		c.printf("  ledger: %d account(s), %d transaction(s), %d ticker(s) registered\n",
			len(ledger.Accounts), len(ledger.Transactions), len(ledger.Tickers))
	}
	if prices != nil {
		c.printf("  market data: %d daily close(s) across %d series\n", prices.TotalPoints(), len(prices.Series))
	}
	c.printf("Store: %s\n", absolute(lc.Layout.PortfolioDir))
	return nil
}

// remoteConnection builds the client for the saved connection, or nil when no
// connection is saved. This is the single routing point: every command that
// goes through Context.Stores / the transfer helpers runs against the remote
// portfolio once 'dit connect' has saved a target.
func (c Context) remoteConnection() (*remote.Connection, error) {
	if c.Layout.RemoteTarget == "" {
		return nil, nil
	}
	return remote.NewConnection(c.Layout.RemoteTarget, c.Layout.RemoteToken, c.Layout.RemoteReadOnly)
}
