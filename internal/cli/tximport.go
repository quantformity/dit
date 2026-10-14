package cli

// `dit tx import FILE` — bulk-load transactions from a CSV file.
//
// Three decisions shape this importer, and they are deliberate:
//
//   - All-or-nothing. Every row is parsed and validated against a working copy
//     before a single byte is written. One bad line aborts the whole import;
//     there is no "imported 40 of 41" half-portfolio. A ledger you cannot trust
//     is worse than no ledger, so a failed import leaves the store exactly as it
//     was.
//   - Idempotent. Each row has a canonical fingerprint; a transaction that
//     already exists (in the store or earlier in the same file) is skipped, not
//     duplicated. Re-running an import is safe.
//   - Offline. Prices come from the file, never a live lookup, so a big import
//     is deterministic and does not hammer a price provider.
//
// Supported types: deposit, withdraw, buy, sell, dividend. GICs and FX
// conversions involve cross-references (a redemption names its purchase) and
// stay with the interactive `tx gic` / `tx fx` commands.

import (
	"encoding/csv"
	"fmt"
	"os"
	"strings"

	"dit/internal/decimal"
	"dit/internal/ledger"
	"dit/internal/model"
	"dit/internal/mutate"
	"dit/internal/store"
)

var txImportSpecs = Registry{
	"tx import": &Spec{
		Run:         txImport,
		FlagOptions: setOf("dry-run", "allow-duplicates"),
	},
}

// importColumns is the fixed field order. A header line, if present, must use
// these names (case-insensitive) so a mis-ordered file is refused rather than
// silently mis-read.
var importColumns = []string{"date", "account", "type", "ticker", "currency", "quantity", "price", "amount", "fee", "notes"}

func txImport(c Context, args []string) error {
	o, err := ParseOptions(args, nil, setOf("dry-run", "allow-duplicates"))
	if err != nil {
		return err
	}
	if len(o.Positionals) == 0 {
		return usage("usage: dit tx import FILE [--dry-run] [--allow-duplicates] (see 'dit help tx import')")
	}
	if len(o.Positionals) > 1 {
		return usage(fmt.Sprintf("unexpected argument '%s' — 'tx import' takes one file", o.Positionals[1]))
	}
	path := o.Positionals[0]
	raw, err := os.ReadFile(path)
	if err != nil {
		return Runtime("cannot read '" + path + "': " + err.Error())
	}
	rows, headerSkipped, err := parseImportCSV(string(raw))
	if err != nil {
		return usage(path + ": " + err.Error())
	}
	if len(rows) == 0 {
		return usage(path + ": no data rows" + map[bool]string{true: " (header only)", false: ""}[headerSkipped])
	}

	// Snapshot the ledger bytes as they are BEFORE we read them, so the
	// changed-under-you check at save time can detect anything that landed in
	// between (a background sync, a second `dit`).
	orig := originalPortfolioBytes(c)

	p, err := c.Ledger()
	if err != nil {
		return err
	}
	if p == nil {
		p = &model.Portfolio{}
	}
	if len(p.Accounts) == 0 {
		return usage("no accounts in the portfolio — add accounts first (see 'dit account add') before importing transactions")
	}

	// Fingerprints of transactions already recorded, so a re-import skips them.
	seen := map[string]bool{}
	if !o.Has("allow-duplicates") {
		for _, t := range p.Transactions {
			seen[txFingerprint(t)] = true
		}
	}

	// Work on a copy; only commit at the very end, and only if every row was
	// valid. This is the failing-command-no-mutation guarantee.
	working := *p
	working.Transactions = append([]model.Transaction(nil), p.Transactions...)

	dryRun := o.Has("dry-run")
	added, skipped := 0, 0
	type planned struct {
		line int
		text string
	}
	var addedLines []planned
	var notes []string

	for i, row := range rows {
		lineNumber := i + 1 + b2i(headerSkipped) // 1-based, counting the header if present
		tx, err := buildImportTx(&working, row, lineNumber, path)
		if err != nil {
			// One bad row aborts everything; nothing has been written yet.
			return usage(err.Error())
		}
		key := txFingerprint(tx)
		if !o.Has("allow-duplicates") && seen[key] {
			skipped++
			continue
		}
		updated, addNotes, err := mutate.Add(working, tx)
		if err != nil {
			return usage(fmt.Sprintf("%s line %d: %s", path, lineNumber, err.Error()))
		}
		working = updated
		seen[key] = true
		added++
		if len(addedLines) < 20 {
			addedLines = append(addedLines, planned{lineNumber, ledgerSummarySafe(tx)})
		}
		for _, n := range addNotes {
			if strings.HasPrefix(n, "warning") {
				notes = append(notes, fmt.Sprintf("line %d: %s", lineNumber, n))
			}
		}
	}

	if dryRun {
		c.printf("dry run — nothing written\n")
		c.printf("  planned: %d transaction(s) to add, %d already present (skipped)\n", added, skipped)
		for _, p := range addedLines {
			c.printf("  + line %d: %s\n", p.line, p.text)
		}
		if added > len(addedLines) {
			c.printf("  … and %d more\n", added-len(addedLines))
		}
		printImportNotes(c, notes)
		if added == 0 && skipped == 0 {
			c.printf("  (nothing to change)\n")
		}
		return nil
	}
	if added == 0 {
		c.printf("imported '%s': nothing to add (%d already present)\n", strings.TrimSpace(path), skipped)
		return nil
	}
	// Guard: if the store changed while we were reading and validating, refuse
	// rather than clobber the newer contents.
	if err := changedUnderYou(c, orig, c.Layout.PortfolioDir, store.PortfolioKey, "portfolio"); err != nil {
		return err
	}
	if err := txSave(c, &working); err != nil {
		return Runtime("could not save the portfolio: " + err.Error())
	}
	c.printf("imported '%s': %d transaction(s) added, %d already present (skipped)\n", strings.TrimSpace(path), added, skipped)
	printImportNotes(c, notes)
	c.printf("Store: %s\n", c.PortfolioLocation())
	return nil
}

// parseImportCSV splits the file, tolerates a header line, and validates the
// shape of every row before any of it is interpreted.
func parseImportCSV(text string) (rows [][]string, headerSkipped bool, err error) {
	reader := csv.NewReader(strings.NewReader(text))
	reader.FieldsPerRecord = -1
	reader.TrimLeadingSpace = true
	records, err := reader.ReadAll()
	if err != nil {
		return nil, false, fmt.Errorf("not a readable CSV file: %v", err)
	}
	if len(records) > 0 {
		first := records[0]
		if len(first) > 0 && strings.EqualFold(strings.TrimSpace(first[0]), "date") {
			headerSkipped = true
			// A header is only trusted if it matches the expected columns.
			want := strings.ToLower(strings.Join(importColumns, ","))
			got := strings.ToLower(strings.Join(trimAll(first), ","))
			if got != want {
				return nil, false, fmt.Errorf("unexpected header; expected: %s", strings.Join(importColumns, ","))
			}
			records = records[1:]
		}
	}
	out := [][]string{}
	for _, rec := range records {
		if len(rec) == 1 && strings.TrimSpace(rec[0]) == "" {
			continue // blank line
		}
		if len(rec) != len(importColumns) {
			return nil, headerSkipped, fmt.Errorf("row %q has %d fields, expected %d (date,account,type,ticker,currency,quantity,price,amount,fee,notes)", strings.Join(rec, ","), len(rec), len(importColumns))
		}
		out = append(out, rec)
	}
	return out, headerSkipped, nil
}

func trimAll(row []string) []string {
	out := make([]string, len(row))
	for i, s := range row {
		out[i] = strings.TrimSpace(s)
	}
	return out
}

// buildImportTx turns one CSV row into a transaction, resolving the account and
// currency and validating amounts. It does not touch the store.
func buildImportTx(p *model.Portfolio, row []string, lineNumber int, path string) (model.Transaction, error) {
	where := func(msg string) (model.Transaction, error) {
		return model.Transaction{}, fmt.Errorf("%s line %d: %s", path, lineNumber, msg)
	}
	fields := map[string]string{}
	for i, name := range importColumns {
		fields[name] = strings.TrimSpace(row[i])
	}
	if fields["date"] == "" || fields["account"] == "" || fields["type"] == "" {
		return where("date, account and type are required")
	}
	day, e := model.ParseDay(fields["date"])
	if e != nil || len(fields["date"]) != 10 || day.String() != fields["date"] {
		return where(fmt.Sprintf("invalid date '%s' — expected YYYY-MM-DD", fields["date"]))
	}
	account, e := txWriteAccount(fields["account"], p)
	if e != nil {
		// txWriteAccount already names the account; keep the line prefix.
		return model.Transaction{}, fmt.Errorf("%s line %d: account '%s': %s", path, lineNumber, fields["account"], e.Error())
	}
	typeRaw := strings.ToLower(fields["type"])
	id, e := txUUID()
	if e != nil {
		return where(e.Error())
	}
	tx := model.Transaction{ID: id, AccountID: account.ID, Currency: account.ReportingCurrency}
	tx = model.TransactionDate(tx, day)
	num := func(name string) (decimal.Decimal, error) { return txNumber(fields[name], name) }
	amount := func(name string) (decimal.Decimal, error) {
		if fields[name] == "" {
			return decimal.Zero, fmt.Errorf("'%s' needs a value in the %s column", typeRaw, name)
		}
		v, err := num(name)
		if err != nil {
			return decimal.Zero, err
		}
		if v.Sign() <= 0 {
			return decimal.Zero, fmt.Errorf("%s must be greater than 0", name)
		}
		return v, nil
	}

	switch typeRaw {
	case "deposit", "withdraw", "withdrawal":
		amt, e := amount("amount")
		if e != nil {
			return where(e.Error())
		}
		kind := model.KindDeposit
		if typeRaw != "deposit" {
			kind = model.KindWithdrawal
		}
		tx.Kind = model.Kind{Type: kind, Amount: amt}
	case "buy", "sell":
		if fields["ticker"] == "" {
			return where(fmt.Sprintf("'%s' needs a ticker", typeRaw))
		}
		if fields["quantity"] == "" || fields["price"] == "" {
			return where(fmt.Sprintf("'%s' needs quantity (shares) and price", typeRaw))
		}
		shares, e := amount("quantity")
		if e != nil {
			return where(e.Error())
		}
		price, e := num("price")
		if e != nil {
			return where(e.Error())
		}
		if price.Sign() < 0 {
			return where("price cannot be negative")
		}
		symbol := strings.ToUpper(fields["ticker"])
		kind := model.KindStockPurchase
		if typeRaw == "sell" {
			kind = model.KindStockSale
		}
		tx.Kind = model.Kind{Type: kind, Stock: &model.StockDetails{Ticker: symbol, Shares: shares, Price: price}}
		if t := p.TickerBySymbol(symbol); t != nil && t.Currency != model.Unknown {
			tx.Currency = t.Currency
		}
	case "dividend":
		if fields["ticker"] == "" {
			return where("'dividend' needs a ticker")
		}
		amt, e := amount("amount")
		if e != nil {
			return where(e.Error())
		}
		symbol := strings.ToUpper(fields["ticker"])
		tx.Kind = model.Kind{Type: model.KindDividend, Dividend: &model.DividendDetails{Ticker: symbol, Amount: amt}}
		if t := p.TickerBySymbol(symbol); t != nil && t.Currency != model.Unknown {
			tx.Currency = t.Currency
		}
	default:
		return where(fmt.Sprintf("unknown type '%s' — use deposit, withdraw, buy, sell or dividend (GICs and FX use 'dit tx gic' / 'dit tx fx')", fields["type"]))
	}

	// An explicit currency wins over the account/ticker default.
	if fields["currency"] != "" {
		ccy, e := txCurrency(fields["currency"], "currency")
		if e != nil {
			return where(e.Error())
		}
		tx.Currency = ccy
	}
	// Fee is net-of: the ledger stores the gross amount and the fee separately.
	if fields["fee"] != "" {
		fee, e := num("fee")
		if e != nil {
			return where(e.Error())
		}
		if fee.Sign() < 0 {
			return where("fee cannot be negative")
		}
		if fee.Sign() != 0 {
			tx.Fee = &fee
		}
	}
	if fields["notes"] != "" {
		n := fields["notes"]
		tx.Notes = &n
	}
	return tx, nil
}

// txFingerprint is a transaction's identity for de-duplication: same account,
// day, kind, instrument, currency and numbers. IDs and notes are excluded so a
// re-export of the same trades is recognised, not treated as new.
func txFingerprint(tx model.Transaction) string {
	key := strings.Join([]string{
		strings.ToUpper(tx.AccountID), tx.Date.String(), string(tx.Kind.Type), string(tx.Currency),
	}, "|")
	switch tx.Kind.Type {
	case model.KindDeposit, model.KindWithdrawal:
		key += "|" + tx.Kind.Amount.String()
	case model.KindStockPurchase, model.KindStockSale:
		if s := tx.Kind.Stock; s != nil {
			key += "|" + s.Ticker + "|" + s.Shares.String() + "|" + s.Price.String()
		}
	case model.KindDividend:
		if d := tx.Kind.Dividend; d != nil {
			key += "|" + d.Ticker + "|" + d.Amount.String()
		}
	}
	if tx.Fee != nil {
		key += "|fee=" + tx.Fee.String()
	}
	return key
}

func ledgerSummarySafe(tx model.Transaction) string {
	defer func() { _ = recover() }()
	return ledger.SummaryLine(tx)
}

func printImportNotes(c Context, notes []string) {
	if len(notes) == 0 {
		return
	}
	c.printf("\nNotes:\n")
	for _, n := range notes {
		c.printf("  - %s\n", n)
	}
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

// originalPortfolioBytes snapshots the ledger for the changed-under-you guard.
// A read failure is treated as "no change to defend" (nil), matching transfer
// import: the guard only blocks a replace when the bytes actually differ.
func originalPortfolioBytes(c Context) []byte {
	raw, _ := transferRead(c, c.Layout.PortfolioDir, store.PortfolioKey)
	return raw
}
