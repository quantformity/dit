package cli

import (
	"bufio"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"dit/internal/bundle"
	"dit/internal/config"
	"dit/internal/model"
	"dit/internal/store"
	"github.com/mattn/go-isatty"
)

var transferSpecs = Registry{
	"backup":       {Run: portfolioBackup, SkipParse: true, HelpText: backupHelp},
	"rollback":     {Run: portfolioRollback, SkipParse: true, HelpText: rollbackHelp},
	"store export": {Run: storeExport, ValueOptions: setOf("to", "account")},
	"store backup": {Run: storeBackup, ValueOptions: setOf("to")},
	"store import": {Run: storeImport, FlagOptions: setOf("merge", "force", "yes")},
	"export":       {Run: bundleExport, ValueOptions: setOf("to"), FlagOptions: setOf("portfolio-only", "market-only")},
	"import":       {Run: bundleImport, FlagOptions: setOf("merge", "force", "yes")},
}

func fileStamp() string { return time.Now().UTC().Format("20060102-150405") }

// writeFailure renders a failed export like the Swift original does. The ENOENT
// case carries Foundation's exact wording (curly quotes included — the Swift
// binary prints that, so a switching user sees the same message either way);
// every other failure stays a normal Go OS error with the target named.
func writeFailure(target string, err error) string {
	if errors.Is(err, syscall.ENOENT) {
		return "could not write '" + target + "': The folder \u201c" + filepath.Base(target) + "\u201d doesn\u2019t exist."
	}
	return fmt.Sprintf("could not write '%s': %v", target, err)
}
func absolute(path string) string {
	p, err := filepath.Abs(path)
	if err != nil {
		return path
	}
	return p
}
func transferOptions(name string, args []string) (Options, error) {
	switch name {
	case "store export":
		return ParseOptions(args, setOf("to", "account"), nil)
	case "store backup":
		return ParseOptions(args, setOf("to"), nil)
	case "export":
		return ParseOptions(args, setOf("to"), setOf("portfolio-only", "market-only"))
	default:
		return ParseOptions(args, nil, setOf("merge", "force", "yes"))
	}
}
func transferTarget(c Context, o Options, prefix string) string {
	if raw, ok := o.Values["to"]; ok {
		return absolute(raw)
	}
	base := c.Layout.PortfolioDir
	if c.Layout.Backend == config.SQLite {
		base = filepath.Dir(base)
	}
	return absolute(filepath.Join(base, prefix+fileStamp()+".json"))
}

// Import must not use Context.Stores: its constructors create directories and
// sqlite schema even when validation will refuse the file.
func transferRead(c Context, path, key string) ([]byte, error) {
	if c.Layout.Backend != config.SQLite {
		raw, err := os.ReadFile(filepath.Join(path, store.SanitizeKey(key)+".dat"))
		if os.IsNotExist(err) {
			return nil, nil
		}
		return raw, err
	}
	if _, err := os.Stat(path); os.IsNotExist(err) {
		return nil, nil
	} else if err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlite", "file:"+absolute(path)+"?mode=ro")
	if err != nil {
		return nil, err
	}
	defer db.Close()
	var raw []byte
	err = db.QueryRow("SELECT payload FROM store WHERE key = ?", key).Scan(&raw)
	if err == sql.ErrNoRows {
		return nil, nil
	}
	return raw, err
}
func transferLedger(c Context) (*model.Portfolio, error) {
	raw, err := transferRead(c, c.Layout.PortfolioDir, store.PortfolioKey)
	if err != nil || raw == nil {
		return nil, err
	}
	var p model.Portfolio
	if err = json.Unmarshal(raw, &p); err != nil {
		return nil, err
	}
	return &p, nil
}
func transferMarket(c Context) (model.MarketData, error) {
	m := store.EmptyMarket()
	raw, err := transferRead(c, c.Layout.MarketDir, store.MarketKey)
	if err != nil {
		return m, err
	}
	if raw != nil {
		_ = json.Unmarshal(raw, &m)
	}
	return m, nil
}
func transferLoad(c Context) (*model.Portfolio, model.MarketData, error) {
	p, err := transferLedger(c)
	if err != nil {
		return nil, model.MarketData{}, err
	}
	m, err := transferMarket(c)
	return p, m, err
}
func displayAccount(a model.Account) string {
	if a.Name != nil && strings.TrimSpace(*a.Name) != "" {
		return strings.TrimSpace(*a.Name)
	}
	id := strings.ToUpper(a.ID)
	if len(id) > 4 {
		id = id[:4]
	}
	return "Account " + id
}
func transferAccount(ref string, p model.Portfolio) (model.Account, error) {
	ref = strings.TrimSpace(ref)
	if ref == "" {
		return model.Account{}, Runtime("empty account reference")
	}
	hex := strings.ToUpper(strings.ReplaceAll(ref, "-", ""))
	looksHex := len(hex) >= 4
	for _, r := range hex {
		if !strings.ContainsRune("0123456789ABCDEF", r) {
			looksHex = false
		}
	}
	found := []model.Account{}
	if looksHex {
		for _, a := range p.Accounts {
			key := strings.ToUpper(strings.ReplaceAll(a.ID, "-", ""))
			if key == hex {
				return a, nil
			}
			if strings.HasPrefix(key, hex) {
				found = append(found, a)
			}
		}
	}
	if len(found) == 0 {
		for _, a := range p.Accounts {
			if a.Name != nil && strings.EqualFold(strings.TrimSpace(*a.Name), ref) {
				found = append(found, a)
			}
		}
	}
	if len(found) == 1 {
		return found[0], nil
	}
	if len(found) == 0 {
		return model.Account{}, Runtime(fmt.Sprintf("no account matches '%s' — use the exact name (see 'dit accounts') or a UUID prefix; if this portfolio should have one, start with 'dit account add'", ref))
	}
	names := []string{}
	for _, a := range found {
		names = append(names, displayAccount(a))
	}
	return model.Account{}, Runtime(fmt.Sprintf("'%s' is ambiguous — it matches: %s. Use a longer name or the full UUID.", ref, strings.Join(names, ", ")))
}
func atomicExport(path string, data []byte) error {
	f, err := os.CreateTemp(filepath.Dir(path), ".dit-export-*")
	if err != nil {
		return err
	}
	name := f.Name()
	defer os.Remove(name)
	_, err = f.Write(data)
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(name, path)
}
func storeExport(c Context, args []string) error {
	o, err := transferOptions("store export", args)
	if err != nil {
		return err
	}
	if err = o.RejectStrayPositionals("dit store export [--to FILE] [--account NAME]"); err != nil {
		return err
	}
	p, err := transferLedger(c)
	if err != nil {
		return err
	}
	if p == nil {
		return Runtime("no portfolio found at " + absolute(c.Layout.PortfolioDir))
	}
	scoped := *p
	scope := "the full portfolio"
	if ref, ok := o.Values["account"]; ok {
		a, err := transferAccount(ref, *p)
		if err != nil {
			return err
		}
		scoped = model.Portfolio{Accounts: []model.Account{a}, Transactions: p.TransactionsIn(a.ID), Tickers: []model.EquityTicker{}}
		symbols := map[string]bool{}
		for _, t := range scoped.Transactions {
			symbols[t.TickerSymbol()] = true
		}
		for _, t := range p.Tickers {
			if symbols[t.Symbol] {
				scoped.Tickers = append(scoped.Tickers, t)
			}
		}
		scope = "account '" + displayAccount(a) + "'"
	}
	data, err := json.MarshalIndent(scoped, "", "  ")
	if err != nil {
		return err
	}
	target := transferTarget(c, o, "dit-portfolio-")
	if err = atomicExport(target, data); err != nil {
		return Runtime(writeFailure(target, err))
	}
	c.printf("Exported %s: %d account(s), %d transaction(s), %d ticker(s) registered\n  → %s\n", scope, len(scoped.Accounts), len(scoped.Transactions), len(scoped.Tickers), target)
	if len(scoped.Accounts) != 1 {
		c.printf("  note: this is a multi-account export — 'dit store import' needs one account per file; re-run with --account <name>\n")
	}
	return nil
}

func bundleExport(c Context, args []string) error {
	o, err := transferOptions("export", args)
	if err != nil {
		return err
	}
	if err = o.RejectStrayPositionals("dit export [--to FILE] [--portfolio-only|--market-only]"); err != nil {
		return err
	}
	if o.Has("portfolio-only") && o.Has("market-only") {
		return usage("--portfolio-only and --market-only contradict each other — pass one, or neither to write the ledger and the prices in one file")
	}
	var p *model.Portfolio
	m := store.EmptyMarket()
	if !o.Has("market-only") {
		p, err = transferLedger(c)
		if err != nil {
			return err
		}
	}
	if !o.Has("portfolio-only") {
		m, err = transferMarket(c)
		if err != nil {
			return err
		}
	}
	d := bundle.Document{Schema: bundle.Schema, CreatedAt: model.Stamp(time.Now().UnixNano()) / 1e9}
	notes := []string{}
	if o.Has("market-only") {
		notes = append(notes, "ledger skipped (--market-only)")
	} else if p != nil {
		d.Portfolio = p
	} else {
		notes = append(notes, "no portfolio document at "+absolute(c.Layout.PortfolioDir))
	}
	if o.Has("portfolio-only") {
		notes = append(notes, "market data skipped (--portfolio-only)")
	} else if !m.IsEmpty() {
		d.Market = &m
	} else {
		notes = append(notes, "no market data at "+absolute(c.Layout.MarketDir)+" ('dit update' fetches prices)")
	}
	if d.Portfolio == nil && d.Market == nil {
		return Runtime("nothing to export — " + strings.Join(notes, "; "))
	}
	data, err := bundle.Encode(d)
	if err != nil {
		return Runtime("could not encode the bundle: " + err.Error())
	}
	target := transferTarget(c, o, "dit-bundle-")
	if err = atomicExport(target, data); err != nil {
		return Runtime(writeFailure(target, err))
	}
	c.printf("Exported a dit bundle (bundle/1):\n")
	if d.Portfolio != nil {
		c.printf("  ledger: %d account(s), %d transaction(s), %d ticker(s) registered\n", len(p.Accounts), len(p.Transactions), len(p.Tickers))
	}
	if d.Market != nil {
		c.printf("  market data: %d daily close(s) across %d series, %d latest quote(s), %d FX rate(s)\n", m.TotalPoints(), len(m.Series), len(m.LatestQuotes), len(m.LatestRates))
	}
	for _, n := range notes {
		c.printf("  note: %s\n", n)
	}
	c.printf("  → %s\n  restore with: dit import %s\n", target, target)
	return nil
}

func transferInput(o Options, name string) (string, []byte, error) {
	hint := "dit " + name + " FILE [--merge] [--force] [--yes]"
	if len(o.Positionals) == 0 {
		return "", nil, usage("usage: " + hint)
	}
	if len(o.Positionals) > 1 {
		return "", nil, usage(fmt.Sprintf("unexpected argument '%s' — use: %s", o.Positionals[1], hint))
	}
	raw := o.Positionals[0]
	data, err := os.ReadFile(raw)
	if err != nil {
		return "", nil, usage(fmt.Sprintf("cannot read '%s': %v", raw, err))
	}
	return raw, data, nil
}
func transferConfirm(c Context, question string, yes bool, plural bool) error {
	if yes {
		return nil
	}
	if !isatty.IsTerminal(os.Stdin.Fd()) {
		fmt.Fprintln(c.Err, question)
		return confirmationRefusal("refusing to continue without --yes on a non-interactive terminal")
	}
	c.printf("%s\nType 'yes' to confirm: ", question)
	line, _ := bufio.NewReader(os.Stdin).ReadString('\n')
	if strings.EqualFold(strings.TrimSpace(line), "yes") {
		return nil
	}
	if plural {
		return Runtime("aborted — the stores are unchanged")
	}
	return Runtime("aborted — the store is unchanged")
}
func bundleImport(c Context, args []string) error {
	o, err := transferOptions("import", args)
	if err != nil {
		return err
	}
	file, data, err := transferInput(o, "import")
	if err != nil {
		return err
	}
	d, err := bundle.Decode(data)
	if err != nil {
		return usage(err.Error())
	}
	p, m, err := transferLoad(c)
	if err != nil {
		return err
	}
	if p == nil {
		p = &model.Portfolio{}
	}
	mode := bundle.Replace
	if o.Has("merge") {
		mode = bundle.Merge
	}
	applied, err := bundle.Apply(d, *p, m, mode)
	if err != nil {
		return usage(err.Error())
	}
	if mode == bundle.Replace {
		changes := []string{}
		if applied.WritesPortfolio {
			changes = append(changes, fmt.Sprintf("the portfolio (%d account(s), %d transaction(s))", len(p.Accounts), len(p.Transactions)))
		}
		if applied.WritesMarket {
			changes = append(changes, fmt.Sprintf("the market data (%d daily close(s))", m.TotalPoints()))
		}
		question := fmt.Sprintf("Replace %s with what '%s' holds?", strings.Join(changes, " and "), filepath.Base(file))
		if err = transferConfirm(c, question, o.Has("yes"), true); err != nil {
			return err
		}
		if !o.Has("force") {
			copies, err := backupForRestore(c)
			if err != nil {
				fmt.Fprintf(c.Err, "warning: automatic pre-import backup failed: %v — continuing without a backup\n", err)
			} else if len(copies) > 0 {
				c.printf("Stores backed up before import:\n")
				for _, p := range copies {
					c.printf("  → %s\n", p)
				}
			}
		}
	}
	var ledger *model.Portfolio
	var prices *model.MarketData
	if applied.WritesPortfolio {
		ledger = &applied.Portfolio
	}
	if applied.WritesMarket {
		prices = &applied.Market
	}
	if err = transferSave(c, ledger, prices); err != nil {
		return Runtime("could not write the stores: " + err.Error())
	}
	for _, n := range applied.Notes {
		c.printf("%s\n", n)
	}
	c.printf("Store: %s\nMarket store: %s\n", absolute(c.Layout.PortfolioDir), absolute(c.Layout.MarketDir))
	return nil
}

func storeImport(c Context, args []string) error {
	o, err := transferOptions("store import", args)
	if err != nil {
		return err
	}
	file, data, err := transferInput(o, "store import")
	if err != nil {
		return err
	}
	if bundle.IsBundle(data) {
		return usage("the import file contains no accounts — imports are account-scoped; re-export with 'dit store export --account <account>'")
	}
	incoming, err := bundle.DecodePortfolio(data)
	if err != nil {
		return usage(fmt.Sprintf("'%s' is not a dit portfolio export (decode failed: %v)", file, portfolioDecodeMessage(data, err)))
	}
	if len(incoming.Accounts) == 0 {
		return usage("the import file contains no accounts — imports are account-scoped; re-export with 'dit store export --account <account>'")
	}
	if len(incoming.Accounts) != 1 {
		return Runtime(fmt.Sprintf("the import file contains %d accounts — imports are single-account: re-export the one you want with 'dit store export --account <account>'", len(incoming.Accounts)))
	}
	a := incoming.Accounts[0]
	for _, t := range incoming.Transactions {
		if !strings.EqualFold(t.AccountID, a.ID) {
			return usage(fmt.Sprintf("the import file has a transaction for account %s, which is not among the file's accounts — the export is not self-consistent", strings.ToUpper(t.AccountID)))
		}
	}
	current, err := transferLedger(c)
	if err != nil {
		return err
	}
	if current == nil {
		current = &model.Portfolio{}
	}
	// Copy slices before appending or removing: apply must not mutate the loaded value.
	result := model.Portfolio{Accounts: append([]model.Account{}, current.Accounts...), Transactions: append([]model.Transaction{}, current.Transactions...), Tickers: append([]model.EquityTicker{}, current.Tickers...)}
	added := 0
	symbols := map[string]bool{}
	for _, t := range current.Tickers {
		symbols[t.Symbol] = true
	}
	for _, t := range incoming.Tickers {
		if !symbols[t.Symbol] {
			result.Tickers = append(result.Tickers, t)
			added++
		}
	}
	note := ""
	if o.Has("merge") {
		newAccount := current.AccountByID(a.ID) == nil
		if newAccount {
			result.Accounts = append(result.Accounts, a)
		}
		known := map[string]bool{}
		for _, t := range current.Transactions {
			known[strings.ToUpper(t.ID)] = true
		}
		fresh, skipped := 0, 0
		for _, t := range incoming.Transactions {
			if known[strings.ToUpper(t.ID)] {
				skipped++
			} else {
				result.Transactions = append(result.Transactions, t)
				fresh++
			}
		}
		note = fmt.Sprintf("imported (merge) '%s': %d new transaction(s)", displayAccount(a), fresh)
		if skipped > 0 {
			note += fmt.Sprintf(", %d already present (skipped)", skipped)
		}
		if newAccount {
			note += "; account created (new ID)"
		} else {
			note += "; existing account kept"
		}
	} else {
		index := -1
		for i, other := range result.Accounts {
			if strings.EqualFold(other.ID, a.ID) {
				index = i
				break
			}
		}
		if index < 0 {
			result.Accounts = append(result.Accounts, a)
		} else {
			result.Accounts[index] = a
		}
		removed := 0
		kept := []model.Transaction{}
		for _, t := range result.Transactions {
			if strings.EqualFold(t.AccountID, a.ID) {
				removed++
			} else {
				kept = append(kept, t)
			}
		}
		result.Transactions = append(kept, incoming.Transactions...)
		note = fmt.Sprintf("imported (replace) '%s': %d transaction(s) from the file replaced %d previously recorded for that account", displayAccount(a), len(incoming.Transactions), removed)
		if err = transferConfirm(c, fmt.Sprintf("Replace the record and ledger of '%s' with %d imported transaction(s)?", displayAccount(a), len(incoming.Transactions)), o.Has("yes"), false); err != nil {
			return err
		}
		if !o.Has("force") {
			copies, err := backupConfiguration(c.Layout.Backend, c.Layout.PortfolioDir, "", true)
			if err != nil {
				fmt.Fprintf(c.Err, "warning: automatic pre-import backup failed: %v — continuing without a backup\n", err)
			} else {
				c.printf("Store backed up before import:\n")
				for _, p := range copies {
					c.printf("  → %s\n", p)
				}
			}
		}
	}
	if added > 0 {
		note += fmt.Sprintf("; %d new ticker(s) registered", added)
	}
	if err = transferSave(c, &result, nil); err != nil {
		return Runtime("could not save the portfolio: " + err.Error())
	}
	c.printf("%s\nStore: %s\n", note, absolute(c.Layout.PortfolioDir))
	return nil
}

func copyLocation(source, destination string) error {
	info, err := os.Lstat(source)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		target, err := os.Readlink(source)
		if err != nil {
			return err
		}
		return os.Symlink(target, destination)
	}
	if info.IsDir() {
		if err = os.MkdirAll(destination, info.Mode().Perm()); err != nil {
			return err
		}
		entries, err := os.ReadDir(source)
		if err != nil {
			return err
		}
		for _, e := range entries {
			if err = copyLocation(filepath.Join(source, e.Name()), filepath.Join(destination, e.Name())); err != nil {
				return err
			}
		}
		return nil
	}
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(destination, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, info.Mode().Perm())
	if err != nil {
		return err
	}
	_, err = io.Copy(out, in)
	closeErr := out.Close()
	if err != nil {
		return err
	}
	return closeErr
}
func backupConfiguration(backend config.Backend, path, to string, required bool) ([]string, error) {
	path = absolute(path)
	stamp := fileStamp()
	copies := []string{}
	if backend == config.File {
		entries, err := os.ReadDir(path)
		if err != nil || len(entries) == 0 {
			if required {
				return nil, Runtime(fmt.Sprintf("the file store at '%s' is missing or empty — nothing to back up", path))
			}
			return copies, nil
		}
		if to == "" {
			to = filepath.Dir(path)
		}
		to = absolute(to)
		destination := filepath.Join(to, filepath.Base(path)+".bak-"+stamp)
		// A backup inside its source would recursively copy itself.
		if strings.HasPrefix(destination, path+string(os.PathSeparator)) {
			return nil, fmt.Errorf("backup destination is inside the store")
		}
		if err = os.MkdirAll(to, 0755); err != nil {
			return nil, err
		}
		if err = os.RemoveAll(destination); err != nil {
			return nil, err
		}
		if err = copyLocation(path, destination); err != nil {
			return nil, err
		}
		return []string{destination}, nil
	}
	if _, err := os.Stat(path); err != nil {
		if required {
			return nil, Runtime(fmt.Sprintf("the sqlite database at '%s' does not exist yet — nothing to back up", path))
		}
		return copies, nil
	}
	if to == "" {
		to = filepath.Dir(path)
	}
	to = absolute(to)
	if err := os.MkdirAll(to, 0755); err != nil {
		return nil, err
	}
	// Swift's backup names use .wal/.shm, not SQLite's usual -wal/-shm.
	for _, suffix := range []string{"", ".wal", ".shm"} {
		source := path + suffix
		if _, err := os.Stat(source); err != nil {
			continue
		}
		destination := filepath.Join(to, filepath.Base(path)+".bak-"+stamp+suffix)
		if err := os.RemoveAll(destination); err != nil {
			return nil, err
		}
		if err := copyLocation(source, destination); err != nil {
			return nil, err
		}
		copies = append(copies, destination)
	}
	return copies, nil
}
func backupForRestore(c Context) ([]string, error) {
	copies, err := backupConfiguration(c.Layout.Backend, c.Layout.PortfolioDir, "", false)
	if err != nil {
		return nil, err
	}
	if c.Layout.Backend == config.File && strings.HasPrefix(absolute(c.Layout.MarketDir), absolute(c.Layout.PortfolioDir)+string(os.PathSeparator)) {
		return copies, nil
	}
	if absolute(c.Layout.MarketDir) == absolute(c.Layout.PortfolioDir) {
		return copies, nil
	}
	market, err := backupConfiguration(c.Layout.Backend, c.Layout.MarketDir, "", false)
	return append(copies, market...), err
}
func storeBackup(c Context, args []string) error {
	o, err := transferOptions("store backup", args)
	if err != nil {
		return err
	}
	if err = o.RejectStrayPositionals("dit store backup [--to DIR]"); err != nil {
		return err
	}
	directory := ""
	if raw, ok := o.Values["to"]; ok {
		directory = absolute(raw)
	}
	copies, err := backupConfiguration(c.Layout.Backend, c.Layout.PortfolioDir, directory, true)
	if err != nil {
		return err
	}
	c.printf("Backed up the store:\n")
	for _, p := range copies {
		c.printf("  → %s\n", p)
	}
	return nil
}

// Stage both documents before replacing either. SQLite uses one transaction
// across attached databases; file stores retain the old bytes for rollback.
func transferSave(c Context, p *model.Portfolio, m *model.MarketData) error {
	committed := false
	createdDirs := []string{}
	defer func() {
		if !committed {
			for _, dir := range createdDirs {
				_ = os.Remove(dir)
			}
		}
	}()
	ensureDirectory := func(directory string) error {
		missing := []string{}
		for path := absolute(directory); ; path = filepath.Dir(path) {
			if _, err := os.Stat(path); !os.IsNotExist(err) {
				break
			}
			missing = append(missing, path)
			if path == filepath.Dir(path) {
				break
			}
		}
		// Deepest first removes only newly created, empty directories on failed staging.
		createdDirs = append(missing, createdDirs...)
		return os.MkdirAll(directory, 0755)
	}
	type write struct {
		path, key string
		data, old []byte
		temp      string
		existed   bool
	}
	writes := []write{}
	if p != nil {
		data, err := json.Marshal(p)
		if err != nil {
			return err
		}
		writes = append(writes, write{path: c.Layout.PortfolioDir, key: store.PortfolioKey, data: data})
	}
	if m != nil {
		data, err := json.Marshal(m)
		if err != nil {
			return err
		}
		writes = append(writes, write{path: c.Layout.MarketDir, key: store.MarketKey, data: data})
	}
	if len(writes) == 0 {
		return nil
	}
	if c.Layout.Backend == config.SQLite {
		created := []string{}
		success := false
		defer func() {
			if !success {
				for _, path := range created {
					_ = os.Remove(path)
				}
			}
		}()
		for _, w := range writes {
			if _, err := os.Stat(w.path); os.IsNotExist(err) {
				created = append(created, w.path)
			}
			if err := ensureDirectory(filepath.Dir(w.path)); err != nil {
				return err
			}
		}
		db, err := sql.Open("sqlite", "file:"+absolute(writes[0].path))
		if err != nil {
			return err
		}
		defer db.Close()
		db.SetMaxOpenConns(1)
		schemas := []string{"main"}
		if len(writes) > 1 {
			if absolute(writes[1].path) == absolute(writes[0].path) {
				schemas = append(schemas, "main")
			} else {
				if _, err = db.Exec("ATTACH DATABASE ? AS prices", absolute(writes[1].path)); err != nil {
					return err
				}
				schemas = append(schemas, "prices")
			}
		}
		tx, err := db.Begin()
		if err != nil {
			return err
		}
		defer tx.Rollback()
		for i, w := range writes {
			if _, err = tx.Exec("CREATE TABLE IF NOT EXISTS " + schemas[i] + ".store (key TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)"); err != nil {
				return err
			}
			if _, err = tx.Exec("INSERT INTO "+schemas[i]+".store (key,payload) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload", w.key, w.data); err != nil {
				return err
			}
		}
		if err = tx.Commit(); err != nil {
			return err
		}
		success = true
		committed = true
		return nil
	}
	defer func() {
		for _, w := range writes {
			if w.temp != "" {
				_ = os.Remove(w.temp)
			}
		}
	}()
	for i := range writes {
		w := &writes[i]
		directory := w.path
		w.path = filepath.Join(directory, w.key+".dat")
		old, err := os.ReadFile(w.path)
		if err != nil && !os.IsNotExist(err) {
			return err
		}
		w.old = old
		w.existed = err == nil
		if err = ensureDirectory(directory); err != nil {
			return err
		}
		f, err := os.CreateTemp(directory, ".dit-import-*")
		if err != nil {
			return err
		}
		w.temp = f.Name()
		_, err = f.Write(w.data)
		closeErr := f.Close()
		if err != nil {
			return err
		}
		if closeErr != nil {
			return closeErr
		}
	}
	for i, w := range writes {
		if err := os.Rename(w.temp, w.path); err != nil {
			for _, previous := range writes[:i] {
				if previous.existed {
					_ = atomicExport(previous.path, previous.old)
				} else {
					_ = os.Remove(previous.path)
				}
			}
			return err
		}
	}
	committed = true
	return nil
}
