package cli

// `dit income` — a cash-income statement.
//
// Income here means money that arrived as earnings, not trading results:
// dividends (net of fees) and GIC interest (proceeds above the redeemed
// principal). Trading and GIC realized P&L live in `dit pnl`; mixing them
// into "income" would double-count what is really a capital return. Amounts
// stay in the currency they were paid in — income is a per-currency cash fact,
// and converting it would need an FX rate that may not exist for the pay date.
//
// Like pnl, income reads the ledger and never fetches.

import (
	"fmt"
	"sort"
	"strings"
	"time"

	"dit/internal/decimal"
	"dit/internal/model"
	"dit/internal/text"
)

var incomeSpecs = Registry{
	"income": &Spec{
		Run:          incomeCommand,
		ValueOptions: setOf("year", "since", "to", "account"),
	},
}

// incomeWindow resolves the reporting window. A bare run (and --year for the
// current year) stops at today; an explicit --year means THAT calendar year,
// not "from that Jan 1 up to now" — otherwise `--year 2024` would quietly
// report later years' income under a 2024 heading. --since/--to override either
// end. Returns the window plus the year the label should name.
func incomeWindow(now time.Time, values map[string]string) (model.Day, model.Day, int, error) {
	day := func(t time.Time) model.Day { return model.Day(model.DayStartUTC(t.Unix())) }
	today := day(now)
	year := now.Year()
	from := day(time.Date(year, 1, 1, 0, 0, 0, 0, time.UTC))
	to := today
	if raw, ok := values["year"]; ok {
		var y int
		if _, e := fmt.Sscanf(raw, "%d", &y); e != nil || y < 1900 || y > 9999 || len(raw) != 4 {
			return 0, 0, 0, usage(fmt.Sprintf("invalid year '%s' — expected a four-digit year", raw))
		}
		year = y
		from = day(time.Date(year, 1, 1, 0, 0, 0, 0, time.UTC))
		yearEnd := time.Date(year, 12, 31, 0, 0, 0, 0, time.UTC)
		if yearEnd.After(now) {
			yearEnd = now
		}
		to = day(yearEnd)
		// A year that has not started yet has nothing to report; clamp the whole
		// window to today rather than raising a backwards-window error for
		// something that is simply empty.
		if from > to {
			from = to
		}
	}
	if raw, ok := values["since"]; ok {
		d, e := model.ParseDay(raw)
		if e != nil || len(raw) != 10 || d.String() != raw {
			return 0, 0, 0, usage(fmt.Sprintf("invalid date '%s' — expected YYYY-MM-DD", raw))
		}
		from = d
	}
	if raw, ok := values["to"]; ok {
		d, e := model.ParseDay(raw)
		if e != nil || len(raw) != 10 || d.String() != raw {
			return 0, 0, 0, usage(fmt.Sprintf("invalid date '%s' — expected YYYY-MM-DD", raw))
		}
		to = d
	}
	if from > to {
		return 0, 0, 0, usage("--since must not be after --to")
	}
	return from, to, year, nil
}

func incomeCommand(c Context, args []string) error {
	o, err := ParseOptions(args, setOf("year", "since", "to", "account"), nil)
	if err != nil {
		return err
	}
	if len(o.Positionals) > 0 {
		return usage(fmt.Sprintf("unexpected argument '%s' — 'dit income' filters with --year/--since/--to/--account (see 'dit help income')", o.Positionals[0]))
	}
	if _, ok := o.Values["year"]; ok {
		if _, ok2 := o.Values["since"]; ok2 {
			return usage("--year and --since cannot be combined — pick one window form")
		}
		if _, ok2 := o.Values["to"]; ok2 {
			return usage("--year and --to cannot be combined — --year already fixes both ends")
		}
	}
	// Income is store-only even when market data exists (nothing to fetch).
	p, _, err := summaryLoad(c)
	if err != nil {
		return err
	}
	if p == nil {
		if c.JSON {
			return c.WriteJSON(map[string]any{"ok": true, "schema": "income/1", "data": map[string]any{"empty": true, "note": "no portfolio found — add accounts and transactions first", "store": c.PortfolioLocation()}})
		}
		c.printf("No portfolio found (store: %s).\nNothing to report — add accounts and transactions first.\n", c.PortfolioLocation())
		return nil
	}

	// Resolve the window. Default: current calendar year to today.
	now := time.Now()
	from, to, year, err := incomeWindow(now, o.Values)
	if err != nil {
		return err
	}

	// Account scope.
	accounts := p.Accounts
	if raw, ok := o.Values["account"]; ok {
		names := marketCSV(raw)
		if len(names) == 0 {
			return usage("--account needs at least one account name (see 'dit accounts')")
		}
		accounts = []model.Account{}
		for _, name := range names {
			a, e := coverageAccount(name, *p)
			if e != nil {
				return e
			}
			accounts = append(accounts, a)
		}
	}

	// Index GIC purchases so a redemption's interest can be netted against the
	// principal it redeemed. Keyed by the upper-cased purchase id.
	gicPrincipal := map[string]model.GICDetails{}
	for _, a := range accounts {
		for _, tx := range p.TransactionsIn(a.ID) {
			if tx.Kind.Type == model.KindGICPurchase && tx.Kind.GIC != nil {
				gicPrincipal[strings.ToUpper(tx.ID)] = *tx.Kind.GIC
			}
		}
	}

	type entry struct {
		date, account, source, kind, currency string
		amount                                decimal.Decimal
	}
	entries := []entry{}
	accountName := map[string]string{}
	for _, a := range p.Accounts {
		accountName[strings.ToUpper(a.ID)] = DisplayName(a)
	}
	for _, a := range accounts {
		for _, tx := range p.TransactionsIn(a.ID) {
			if tx.Date < from || tx.Date > to {
				continue
			}
			fee := decimal.Zero
			if tx.Fee != nil {
				fee = *tx.Fee
			}
			source := ""
			amount := decimal.Zero
			kind := ""
			switch tx.Kind.Type {
			case model.KindDividend:
				if tx.Kind.Dividend == nil {
					continue
				}
				amount = tx.Kind.Dividend.Amount.Sub(fee)
				source = tx.Kind.Dividend.Ticker
				kind = "dividend"
			case model.KindGICRedemption:
				if tx.Kind.Redemption == nil {
					continue
				}
				original, ok := gicPrincipal[strings.ToUpper(tx.Kind.Redemption.PurchaseID)]
				if !ok {
					continue
				}
				amount = tx.Kind.Redemption.Proceeds.Sub(fee).Sub(original.Principal)
				source = "GIC: " + original.Product
				kind = "gic-interest"
			default:
				continue
			}
			if amount.Sign() == 0 {
				continue
			}
			entries = append(entries, entry{date: tx.Date.String(), account: accountName[strings.ToUpper(tx.AccountID)], source: source, kind: kind, currency: string(tx.Currency), amount: amount})
		}
	}
	// Oldest first, then by account/source for a stable table.
	sort.SliceStable(entries, func(i, j int) bool {
		if entries[i].date != entries[j].date {
			return entries[i].date < entries[j].date
		}
		return entries[i].account < entries[j].account
	})

	// Totals per currency (income is never summed across currencies).
	totals := map[string]decimal.Decimal{}
	for _, e := range entries {
		totals[e.currency] = totals[e.currency].Add(e.amount)
	}
	currencies := make([]string, 0, len(totals))
	for ccy := range totals {
		currencies = append(currencies, ccy)
	}
	sort.Strings(currencies)

	label := "Income — " + from.String() + " to " + to.String()
	// Naming the year reads better than a date range, and is now truthful: the
	// window above really does stop at Dec 31 (or today, for the running year).
	if _, ok := o.Values["year"]; ok {
		label = fmt.Sprintf("Income — %d", year)
	}
	if c.JSON {
		rows := []map[string]any{}
		for _, e := range entries {
			rows = append(rows, map[string]any{"date": e.date, "account": e.account, "source": e.source, "kind": e.kind, "currency": e.currency, "amount": e.amount.Fixed(2)})
		}
		byCcy := map[string]string{}
		for _, ccy := range currencies {
			byCcy[ccy] = totals[ccy].Fixed(2)
		}
		note := "income is dividends and GIC interest, net of fees, in the currency paid; trading and GIC realized P&L are reported by 'dit pnl'"
		if len(currencies) > 1 {
			note += "; totals are per-currency and are not combined across currencies"
		}
		return c.WriteJSON(map[string]any{"ok": true, "schema": "income/1", "data": map[string]any{"window": label, "income": rows, "totalsByCurrency": byCcy, "note": note}})
	}

	c.printf("%s (native currency; not converted)\n", label)
	if len(entries) == 0 {
		c.printf("\n  No dividends or GIC interest recorded in this window.\n")
		c.printf("\nStore: %s\n", c.PortfolioLocation())
		return nil
	}
	c.printf("\n")
	rows := [][]string{}
	for _, e := range entries {
		rows = append(rows, []string{e.date, e.account, e.source, e.kind, e.currency + " " + text.Money(e.amount)})
	}
	for _, line := range text.Table([]string{"Date", "Account", "Source", "Kind", "Amount"}, rows, map[int]bool{0: true, 1: true, 2: true, 3: true}, boldHeaders(c)) {
		c.printf("  %s\n", line)
	}
	c.printf("\nBy currency (native; not combinable):\n")
	footRows := [][]string{}
	for _, ccy := range currencies {
		footRows = append(footRows, []string{ccy, text.Money(totals[ccy])})
	}
	for _, line := range text.Table([]string{"Ccy", "Total"}, footRows, map[int]bool{0: true}, boldHeaders(c)) {
		c.printf("  %s\n", line)
	}
	if len(currencies) > 1 {
		c.printf("\n  totals are per-currency and are not combined across currencies\n")
	}
	c.printf("\nStore: %s\n", c.PortfolioLocation())
	return nil
}
