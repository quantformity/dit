package cli

import (
	"bufio"
	"fmt"
	"os"
	"reflect"
	"sort"
	"strings"
	"time"

	"dit/internal/decimal"
	"dit/internal/ledger"
	"dit/internal/model"
	"dit/internal/text"
	"dit/internal/valuation"
	"github.com/google/uuid"
	"github.com/mattn/go-isatty"
)

var acctmgktSpecs Registry

func init() { acctmgktSpecs = makeAcctmgktSpecs() }

func makeAcctmgktSpecs() Registry {
	r := Registry{}
	for name, run := range map[string]Command{"account add": accountAdd, "account edit": accountEdit, "account close": accountClose, "account delete": accountDelete, "account show": accountShow, "ticker": tickerList, "ticker list": tickerList, "ticker show": tickerShow, "ticker add": tickerAdd, "ticker edit": tickerEdit, "ticker delete": tickerDelete} {
		s := &Spec{Run: run, HelpText: acctmgktHelp[name]}
		switch name {
		case "account add", "account edit":
			s.ValueOptions = setOf("currency", "name", "institution", "number", "opened", "closed", "notes")
			s.FlagOptions = setOf("taxable", "non-taxable")
		case "account close":
			s.ValueOptions = setOf("date")
		case "account delete":
			s.FlagOptions = setOf("force", "yes")
		case "account show":
			s.FlagOptions = setOf("history")
		case "ticker add", "ticker edit":
			s.ValueOptions = setOf("name", "currency", "tags", "notes")
		case "ticker delete":
			s.FlagOptions = setOf("yes")
		}
		if strings.HasPrefix(name, "ticker") {
			s.HelpText = acctmgktHelp["ticker"]
		}
		r[name] = s
	}
	return r
}
func managementOptions(name string, args []string) (Options, error) {
	return acctmgktSpecs[name].ParseFor(args)
}
func managementPortfolio(c Context, required bool) (*model.Portfolio, error) {
	p, e := transferLedger(c)
	if e != nil {
		return nil, e
	}
	if p == nil {
		if required {
			return nil, Runtime("no portfolio found at " + absolute(c.Layout.PortfolioDir))
		}
		p = &model.Portfolio{}
	}
	return p, nil
}
func managementCurrency(raw string) (model.Currency, error) {
	code := model.Currency(strings.ToUpper(raw))
	if code.IsKnown() {
		return code, nil
	}
	return model.Unknown, usage(fmt.Sprintf("unknown currency '%s' for --currency — use e.g. CAD, USD, JPY, or GBp", raw))
}
func managementDate(raw string) (*model.Day, error) {
	d, e := model.ParseDay(raw)
	if e != nil {
		return nil, usage("invalid date '" + raw + "' — expected YYYY-MM-DD")
	}
	return &d, nil
}
func managementTaxable(o Options) (*bool, error) {
	t, n := o.Flag("taxable"), o.Flag("non-taxable")
	if n != nil {
		v := !*n
		if t != nil && *t != v {
			return nil, usage("--taxable and --non-taxable contradict each other")
		}
		return &v, nil
	}
	return t, nil
}
func managementString(o Options, key string) *string {
	v, ok := o.Values[key]
	if !ok {
		return nil
	}
	return &v
}
func duplicateAccount(p *model.Portfolio, a model.Account) error {
	name := strings.TrimSpace(OrEmpty(a.Name))
	if name == "" {
		return nil
	}
	for _, b := range p.Accounts {
		if b.ID != a.ID && strings.EqualFold(strings.TrimSpace(OrEmpty(b.Name)), name) {
			return Runtime(fmt.Sprintf("an account is already named '%s' — accounts need distinct names so the CLI can resolve them unambiguously (rename one with 'dit account edit', or use a new name)", name))
		}
	}
	return nil
}
func accountAdd(c Context, args []string) error {
	o, e := managementOptions("account add", args)
	if e != nil {
		return e
	}
	if len(o.Positionals) > 0 {
		return usage("unexpected argument '" + o.Positionals[0] + "' — account add takes no positionals")
	}
	raw, e := o.Require("currency")
	if e != nil {
		return e
	}
	ccy, e := managementCurrency(raw)
	if e != nil {
		return e
	}
	tax, e := managementTaxable(o)
	if e != nil {
		return e
	}
	a := model.Account{ID: strings.ToUpper(uuid.NewString()), ReportingCurrency: ccy, Taxable: true, Name: managementString(o, "name"), Institution: managementString(o, "institution"), AccountNumber: managementString(o, "number"), Notes: managementString(o, "notes")}
	if tax != nil {
		a.Taxable = *tax
	}
	for _, field := range []struct {
		key  string
		dest **model.Day
	}{{"opened", &a.OpenedDate}, {"closed", &a.ClosedDate}} {
		if v, ok := o.Values[field.key]; ok {
			*field.dest, e = managementDate(v)
			if e != nil {
				return e
			}
		}
	}
	p, e := managementPortfolio(c, false)
	if e != nil {
		return e
	}
	if e = duplicateAccount(p, a); e != nil {
		return e
	}
	p.Accounts = append(p.Accounts, a)
	if e = transferSave(c, p, nil); e != nil {
		return e
	}
	status := "taxable"
	if !a.Taxable {
		status = "non-taxable"
	}
	c.printf("added account '%s' (%s, %s)\nid: %s\n", displayAccount(a), string(ccy), status, a.ID)
	return nil
}
func accountEdit(c Context, args []string) error  { return accountUpdate(c, args, false) }
func accountClose(c Context, args []string) error { return accountUpdate(c, args, true) }
func accountUpdate(c Context, args []string, close bool) error {
	name := "account edit"
	hint := "usage: dit account edit <account> [options]"
	if close {
		name = "account close"
		hint = "usage: dit account close <account> [--date YYYY-MM-DD]"
	}
	o, e := managementOptions(name, args)
	if e != nil {
		return e
	}
	if len(o.Positionals) == 0 {
		return usage(hint)
	}
	p, e := managementPortfolio(c, false)
	if e != nil {
		return e
	}
	a, e := transferAccount(o.Positionals[0], *p)
	if e != nil {
		return e
	}
	changes := []string{}
	if close {
		if raw, ok := o.Values["date"]; ok {
			o.Values["closed"] = raw
		} else {
			// Without --date the reference stamps the account with *now* (a full
			// point in time, not a calendar day). Record whole seconds: the same
			// moment every display command can surface, and the probe's
			// "both sides wrote now" comparison then holds.
			d := model.Day(time.Now().UTC().Truncate(time.Second).Unix())
			a.ClosedDate = &d
			changes = append(changes, "closed → "+d.String())
		}
	}
	for _, field := range []struct {
		key  string
		dest **string
	}{{"name", &a.Name}, {"institution", &a.Institution}, {"number", &a.AccountNumber}} {
		if v, ok := o.Values[field.key]; ok && (*field.dest == nil || **field.dest != v) {
			changes = append(changes, field.key+" → '"+v+"'")
			*field.dest = &v
		}
	}
	if v, ok := o.Values["currency"]; ok {
		ccy, err := managementCurrency(v)
		if err != nil {
			return err
		}
		if ccy != a.ReportingCurrency {
			changes = append(changes, "currency → "+string(ccy))
			a.ReportingCurrency = ccy
		}
	}
	tax, e := managementTaxable(o)
	if e != nil {
		return e
	}
	if tax != nil && *tax != a.Taxable {
		a.Taxable = *tax
		v := "now taxable"
		if !*tax {
			v = "now non-taxable"
		}
		changes = append(changes, v)
	}
	for _, field := range []struct {
		key  string
		dest **model.Day
	}{{"opened", &a.OpenedDate}, {"closed", &a.ClosedDate}} {
		if v, ok := o.Values[field.key]; ok {
			d, err := managementDate(v)
			if err != nil {
				return err
			}
			if *field.dest == nil || **field.dest != *d {
				changes = append(changes, field.key+" → "+d.String())
				*field.dest = d
			}
		}
	}
	if v, ok := o.Values["notes"]; ok && (a.Notes == nil || *a.Notes != v) {
		changes = append(changes, "notes → '"+v+"'")
		a.Notes = &v
	}
	if len(changes) == 0 {
		return Runtime("no changes — every supplied value already matches account " + strings.ToUpper(a.ID))
	}
	if a.OpenedDate != nil && a.ClosedDate != nil && *a.ClosedDate < *a.OpenedDate {
		return Runtime(fmt.Sprintf("closed date (%s) precedes opened date (%s)", a.ClosedDate.String(), a.OpenedDate.String()))
	}
	if e = duplicateAccount(p, a); e != nil {
		return e
	}
	for i := range p.Accounts {
		if p.Accounts[i].ID == a.ID {
			p.Accounts[i] = a
		}
	}
	if e = transferSave(c, p, nil); e != nil {
		return e
	}
	c.printf("updated '%s': %s\n", displayAccount(a), strings.Join(changes, ", "))
	return nil
}
func managementConfirm(c Context, impact string, yes bool) (bool, error) {
	if yes {
		return true, nil
	}
	if !isatty.IsTerminal(os.Stdin.Fd()) {
		fmt.Fprintln(c.Err, impact)
		return false, confirmationRefusal("refusing to continue without --yes on a non-interactive terminal")
	}
	c.printf("%s\nType 'yes' to confirm: ", impact)
	line, _ := bufio.NewReader(os.Stdin).ReadString('\n')
	return strings.EqualFold(strings.TrimSpace(line), "yes"), nil
}

func managementPlural(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}
func accountDelete(c Context, args []string) error {
	o, e := managementOptions("account delete", args)
	if e != nil {
		return e
	}
	if len(o.Positionals) == 0 {
		return usage("usage: dit account delete <account> [--force] [--yes]")
	}
	p, e := managementPortfolio(c, false)
	if e != nil {
		return e
	}
	a, e := transferAccount(o.Positionals[0], *p)
	if e != nil {
		return e
	}
	n := len(p.TransactionsIn(a.ID))
	impact := "This will remove account '" + displayAccount(a) + "'"
	if n > 0 {
		if !o.Has("force") {
			return usage(fmt.Sprintf("account '%s' has %d transaction%s and deleting the account removes them too — add --force if that is really what you want", displayAccount(a), n, managementPlural(n)))
		}
		impact += fmt.Sprintf(" and its %d transaction%s", n, managementPlural(n))
	}
	if confirmed, err := managementConfirm(c, impact+".", o.Has("yes")); err != nil {
		return err
	} else if !confirmed {
		c.printf("cancelled\n")
		return nil
	}
	accounts := []model.Account{}
	for _, b := range p.Accounts {
		if b.ID != a.ID {
			accounts = append(accounts, b)
		}
	}
	p.Accounts = accounts
	txs := []model.Transaction{}
	for _, t := range p.Transactions {
		if !strings.EqualFold(t.AccountID, a.ID) {
			txs = append(txs, t)
		}
	}
	p.Transactions = txs
	if e = transferSave(c, p, nil); e != nil {
		return e
	}
	note := "removed account '" + displayAccount(a) + "'"
	if n > 0 {
		note += fmt.Sprintf(" and %d transaction%s", n, managementPlural(n))
	}
	c.printf("%s\n", note)
	return nil
}
func managementSymbol(raw string) (string, error) {
	s := model.NormalizeSymbol(raw)
	if s == "" {
		return "", usage("--ticker cannot be empty")
	}
	return s, nil
}
func managementTags(raw string) []string {
	out := []string{}
	seen := map[string]bool{}
	for _, v := range strings.Split(raw, ",") {
		v = strings.ToLower(strings.TrimSpace(v))
		if v != "" && !seen[v] {
			seen[v] = true
			out = append(out, v)
		}
	}
	sort.Strings(out)
	return out
}
func managementDisplayTags(tags []string) string {
	out := append([]string{}, tags...)
	sort.Strings(out)
	for i, v := range out {
		out[i] = strings.Title(v)
	}
	return strings.Join(out, ", ")
}
func tickerList(c Context, args []string) error {
	p, e := transferLedger(c)
	if e != nil {
		return e
	}
	if p == nil {
		c.printf("No portfolio found (store: %s at %s).\n", c.Layout.Backend, absolute(c.Layout.PortfolioDir))
		return nil
	}
	if len(p.Tickers) == 0 {
		c.printf("The ticker registry is empty — 'dit ticker add SYM' registers an instrument.\n")
		return nil
	}
	entries := append([]model.EquityTicker{}, p.Tickers...)
	sort.Slice(entries, func(i, j int) bool { return entries[i].Symbol < entries[j].Symbol })
	rows := [][]string{}
	for _, t := range entries {
		name := "—"
		if t.Name != nil {
			name = *t.Name
		}
		rows = append(rows, []string{t.Symbol, name, t.Currency.String(), managementDisplayTags(t.Tags), fmt.Sprint(len(p.TransactionsFor(t.Symbol)))})
	}
	c.printf("Registry:\n")
	managementTable(c, []string{"Symbol", "Name", "Ccy", "Tags", "Txns"}, rows, "  ", nil)
	return nil
}
func tickerShow(c Context, args []string) error {
	o, e := managementOptions("ticker show", args)
	if e != nil {
		return e
	}
	if len(o.Positionals) == 0 {
		return usage("usage: dit ticker show <symbol>")
	}
	s, e := managementSymbol(o.Positionals[0])
	if e != nil {
		return e
	}
	p, e := managementPortfolio(c, true)
	if e != nil {
		return e
	}
	t := p.TickerBySymbol(s)
	if t == nil {
		return Runtime(fmt.Sprintf("no registry entry for '%s' — 'dit ticker add %s' creates one", s, s))
	}
	name, notes, tags, ccy := "—", "—", "—", "unknown"
	if t.Name != nil {
		name = *t.Name
	}
	if t.Notes != nil {
		notes = *t.Notes
	}
	if len(t.Tags) > 0 {
		tags = managementDisplayTags(t.Tags)
	}
	if t.Currency != model.Unknown {
		ccy = string(t.Currency)
	}
	c.printf("Ticker: %s\n  Name:      %s\n  Currency:  %s\n  Tags:      %s\n  Notes:     %s\n  Referenced by %d transaction(s)\n", s, name, ccy, tags, notes, len(p.TransactionsFor(s)))
	return nil
}
func tickerAdd(c Context, args []string) error  { return tickerUpdate(c, args, false) }
func tickerEdit(c Context, args []string) error { return tickerUpdate(c, args, true) }
func tickerUpdate(c Context, args []string, edit bool) error {
	name, verb := "ticker add", "add"
	if edit {
		name = "ticker edit"
		verb = "edit"
	}
	o, e := managementOptions(name, args)
	if e != nil {
		return e
	}
	if len(o.Positionals) == 0 || !edit && len(o.Positionals) != 1 {
		return usage("usage: dit ticker " + verb + " <symbol> [--name NAME] [--currency CCY] [--tags a,b] [--notes TEXT]")
	}
	if edit && len(o.Values) == 0 {
		return usage("nothing to edit — pass --name, --currency, --tags, or --notes")
	}
	ccy := model.Unknown
	if v, ok := o.Values["currency"]; ok {
		ccy, e = managementCurrency(v)
		if e != nil {
			return e
		}
	}
	s, e := managementSymbol(o.Positionals[0])
	if e != nil {
		return e
	}
	p, e := managementPortfolio(c, false)
	if e != nil {
		return e
	}
	existing := p.TickerBySymbol(s)
	if !edit && existing != nil {
		return Runtime(fmt.Sprintf("the ticker '%s' is already registered — update it with 'dit ticker edit %s'", s, s))
	}
	if edit && existing == nil {
		return Runtime(fmt.Sprintf("no registry entry for '%s' — create one with 'dit ticker add %s'", s, s))
	}
	t := model.EquityTicker{Symbol: s, Currency: ccy, Name: managementString(o, "name"), Notes: managementString(o, "notes"), Tags: managementTags(o.Value("tags"))}
	note := "registered " + s
	if edit {
		t = *existing
		changes := []string{}
		if v, ok := o.Values["name"]; ok && (t.Name == nil || *t.Name != v) {
			changes = append(changes, "name → '"+v+"'")
			t.Name = &v
		}
		if _, ok := o.Values["currency"]; ok && t.Currency != ccy {
			changes = append(changes, "currency → "+string(ccy))
			t.Currency = ccy
		}
		if v, ok := o.Values["tags"]; ok {
			tags := managementTags(v)
			old := managementTags(strings.Join(t.Tags, ","))
			if !reflect.DeepEqual(tags, old) {
				desc := "tags cleared"
				if len(tags) > 0 {
					desc = "tags → " + managementDisplayTags(tags)
				}
				changes = append(changes, desc)
				t.Tags = tags
			}
		}
		if v, ok := o.Values["notes"]; ok && (t.Notes == nil || *t.Notes != v) {
			changes = append(changes, "notes → '"+v+"'")
			t.Notes = &v
		}
		if len(changes) == 0 {
			return Runtime("no changes — every supplied value already matches the entry for '" + s + "'")
		}
		note = "updated registry entry '" + s + "': " + strings.Join(changes, ", ")
		for i := range p.Tickers {
			if p.Tickers[i].Symbol == s {
				p.Tickers[i] = t
			}
		}
	} else {
		if n := strings.TrimSpace(OrEmpty(t.Name)); n != "" {
			note += " ('" + n + "')"
		}
		currency := string(ccy)
		if ccy == model.Unknown {
			currency = "unknown (set with 'dit ticker edit')"
		}
		note += " — trades in " + currency
		p.Tickers = append(p.Tickers, t)
	}
	if e = transferSave(c, p, nil); e != nil {
		return e
	}
	c.printf("%s\n", note)
	return nil
}
func tickerDelete(c Context, args []string) error {
	o, e := managementOptions("ticker delete", args)
	if e != nil {
		return e
	}
	if len(o.Positionals) == 0 {
		return usage("usage: dit ticker delete <symbol> [--yes]")
	}
	s, e := managementSymbol(o.Positionals[0])
	if e != nil {
		return e
	}
	p, e := managementPortfolio(c, true)
	if e != nil {
		return e
	}
	t := p.TickerBySymbol(s)
	if t == nil {
		return Runtime("no registry entry for '" + s + "' — nothing to remove")
	}
	n := len(p.TransactionsFor(s))
	if n > 0 {
		impact := fmt.Sprintf("This will remove the registry entry '%s'. %d transaction%s reference it; they are unaffected (the registry is display metadata only).", s, n, managementPlural(n))
		if confirmed, err := managementConfirm(c, impact, o.Has("yes")); err != nil {
			return err
		} else if !confirmed {
			c.printf("cancelled\n")
			return nil
		}
	}
	note := "unregistered "
	if name := strings.TrimSpace(OrEmpty(t.Name)); name != "" {
		note += "'" + name + "' "
	}
	note += "(" + s + ")"
	if n > 0 {
		note += fmt.Sprintf(" — %d transaction%s still reference %s; they are unaffected", n, managementPlural(n), s)
	}
	entries := []model.EquityTicker{}
	for _, v := range p.Tickers {
		if v.Symbol != s {
			entries = append(entries, v)
		}
	}
	p.Tickers = entries
	if e = transferSave(c, p, nil); e != nil {
		return e
	}
	c.printf("%s\n", note)
	return nil
}
func managementTable(c Context, headers []string, rows [][]string, indent string, left map[int]bool) {
	for _, line := range text.Table(headers, rows, left, boldHeaders(c)) {
		c.printf("%s%s\n", indent, line)
	}
}
func accountShow(c Context, args []string) error {
	o, e := managementOptions("account show", args)
	if e != nil {
		return e
	}
	if len(o.Positionals) == 0 {
		return usage("usage: dit account show <account> [--history]")
	}
	p, e := managementPortfolio(c, true)
	if e != nil {
		return e
	}
	a, e := transferAccount(o.Positionals[0], *p)
	if e != nil {
		return e
	}
	txs := p.TransactionsIn(a.ID)
	sort.SliceStable(txs, func(i, j int) bool { return txs[i].Date < txs[j].Date })
	mark := valuation.Mark{Price: func(model.Currency, string) *valuation.Observed { return nil }, Baseline: func(model.Currency, string) *model.DailyPrice { return nil }, Rate: func(from, to model.Currency) *decimal.Decimal {
		if from == to {
			v := decimal.FromInt(1)
			return &v
		}
		return nil
	}}
	b := valuation.AccountBalance(a, txs, mark, model.Day(1<<62))
	if c.JSON {
		return managementAccountJSON(c, a, b, txs, o.Has("history"))
	}
	now := time.Now()
	scoped := &model.Portfolio{Accounts: []model.Account{a}, Transactions: txs, Tickers: p.Tickers}
	day := model.Day(model.DayStartUTC(now.Unix()))
	display := a.ReportingCurrency
	notes := []string{}
	var summary valuation.Summary
	stalePriced := false
	if c.Offline {
		summary = valuation.CostSummary(scoped, display, day)
		notes = append(notes, "offline mode: positions at cost basis, no FX conversion")
	} else {
		_, market, err := summaryLoad(c)
		if err != nil {
			return err
		}
		summary, _, stalePriced = runLive(scoped, market, display, now, &notes)
	}
	for _, short := range summary.Shorts {
		notes = append(notes, fmt.Sprintf("untracked short: %s sold %s %s (%s) beyond its holding — cash shows the proceeds, the short itself is not tracked, so totals here are incomplete", short.AccountName, summaryQuantity(short.Shares), short.Symbol, short.Currency))
	}
	if stalePriced {
		c.printf("No live quote could be fetched. Positions below are priced from stored closes, " +
			"which are NOT today's prices — see Notes.\n\n")
	}
	report := RenderSummary(summary, now, notes, boldHeaders(c))
	report = strings.Replace(report, "Portfolio summary —", "Account summary — "+displayAccount(a)+" —", 1)
	c.printf("%s\n", report)

	c.printf("\nAccount details:\n  ID:        %s\n", strings.ToUpper(a.ID))
	if a.Institution != nil {
		c.printf("  Institution: %s\n", *a.Institution)
	}
	if a.AccountNumber != nil {
		c.printf("  Number:    %s\n", *a.AccountNumber)
	}
	tax := "no"
	if a.Taxable {
		tax = "yes"
	}
	c.printf("  Taxable:   %s\n", tax)
	opened, closed := "—", "—"
	if a.OpenedDate != nil {
		opened = a.OpenedDate.String()
	}
	if a.ClosedDate != nil {
		closed = a.ClosedDate.String()
	}
	c.printf("  Opened:    %s\n  Closed:    %s\n", opened, closed)
	if a.Notes != nil {
		c.printf("  Notes:     %s\n", *a.Notes)
	}
	c.printf("\nStore: %s\n", c.PortfolioLocation())
	if o.Has("history") {
		c.printf("\nHistory (%d transaction(s), oldest first):\n", len(txs))
		if len(txs) == 0 {
			c.printf("  — no activity recorded —\n")
		} else {
			rows := [][]string{}
			for _, tx := range txs {
				rows = append(rows, []string{ledger.ShortID(tx.ID), tx.Date.String(), string(tx.Kind.Type), ledger.SummaryLine(tx)})
			}
			managementTable(c, []string{"ID", "Date", "Kind", "Detail"}, rows, "  ", map[int]bool{0: true, 1: true, 2: true, 3: true})
			c.printf("\n  Filter deeper: 'dit tx list --account \"%s\" --kind/--ticker/--since/--until/--limit'; edit with 'dit tx show <id>'.\n", displayAccount(a))
		}
	}
	return nil
}
func managementAmounts(values valuation.Amounts) string {
	keys := []model.Currency{}
	for key := range values {
		keys = append(keys, key)
	}
	sort.Slice(keys, func(i, j int) bool { return keys[i] < keys[j] })
	out := []string{}
	for _, key := range keys {
		out = append(out, string(key)+" "+text.Money(values[key]))
	}
	if len(out) == 0 {
		return "—"
	}
	return strings.Join(out, ", ")
}
func managementAccountJSON(c Context, a model.Account, b valuation.Account, txs []model.Transaction, history bool) error {
	amounts := func(m valuation.Amounts) map[string]string {
		out := map[string]string{}
		for c, v := range m {
			out[string(c)] = v.Fixed(2)
		}
		return out
	}
	status := "open"
	if a.ClosedDate != nil {
		status = "closed " + a.ClosedDate.String()
	}
	positions := []any{}
	for _, p := range b.Positions {
		positions = append(positions, map[string]any{"avgCost": p.AverageCost.Fixed(2), "ccy": string(p.Currency), "costBasis": p.Cost.Fixed(2), "shares": summaryQuantity(p.Shares), "symbol": p.Symbol})
	}
	shorts := []any{}
	for _, s := range b.Shorts {
		shorts = append(shorts, map[string]any{"ccy": string(s.Currency), "shares": summaryQuantity(s.Shares), "symbol": s.Symbol})
	}
	data := map[string]any{"account": map[string]any{"currency": string(a.ReportingCurrency), "id": strings.ToUpper(a.ID), "name": displayAccount(a), "status": status, "taxable": a.Taxable}, "balances": map[string]any{"cashByCurrency": amounts(b.CashByCurrency), "dayChangeByCurrency": amounts(b.DayByCurrency), "dividendsByCurrency": amounts(b.DividendsByCurrency), "gicByCurrency": amounts(b.GICByCurrency), "realizedPnlByCurrency": amounts(b.RealizedByCurrency), "unrealizedPnlByCurrency": amounts(b.UnrealizedByCurrency)}, "positions": positions, "untrackedShorts": shorts}
	if history {
		rows := []any{}
		for _, tx := range txs {
			rows = append(rows, map[string]any{"currency": string(tx.Currency), "date": tx.Date.String(), "detail": ledger.SummaryLine(tx), "id": strings.ToUpper(tx.ID), "kind": string(tx.Kind.Type)})
		}
		data["history"] = rows
	}
	return c.WriteJSON(map[string]any{"ok": true, "schema": "account/1", "data": data})
}
