// The network commands: serve, clone, connect, disconnect.
//
// `dit serve` publishes the local portfolio over a small HTTP protocol
// (internal/remote); `dit connect` remembers a remote as the active target so
// the ordinary commands run against it; `dit clone` pulls a remote portfolio
// into the local stores; `dit disconnect` clears the target.
package cli

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
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
}

// remoteBannerExcluded are the commands that do not run against the saved
// connection: the connection managers name their own target, serve publishes
// the local stores, and config edits the local file.
func remoteBannerExcluded(name string) bool {
	switch name {
	case "serve", "connect", "disconnect", "clone":
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
// path, or the remote address while a connection is active. The key selects
// the document so the two local stores keep distinct labels.
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
	server := &http.Server{Handler: handler, ReadHeaderTimeout: 10 * time.Second}
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
	c.printf("   press Ctrl-C to stop\n")

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
