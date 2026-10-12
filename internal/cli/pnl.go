package cli

import (
	"dit/internal/model"
	"dit/internal/valuation"
	_ "embed"
	"fmt"
	"sort"
	"strings"
	"time"
)

//go:embed pnl_help.txt
var pnlHelp string
var pnlSpecs = Registry{"pnl": &Spec{Run: pnlCommand, ValueOptions: setOf("horizon", "from", "to", "account", "tickers", "ccy", "reporting-ccy"), FlagOptions: setOf("time-series", "daily"), HelpText: strings.TrimSuffix(pnlHelp, "\n")}}

func pnlCommand(c Context, args []string) error { return pnlRun(c, args, time.Now()) }
func pnlRun(c Context, args []string, now time.Time) error {
	o, err := ParseOptions(args, setOf("horizon", "from", "to", "account", "tickers", "ccy", "reporting-ccy"), setOf("time-series", "daily"))
	if err != nil {
		return err
	}
	_, h := o.Values["horizon"]
	_, f := o.Values["from"]
	_, t := o.Values["to"]
	if h && (f || t) {
		return usage("--horizon and --from/--to cannot be combined — pick one window form")
	}
	want := o.Flag("time-series") != nil && *o.Flag("time-series")
	daily := o.Flag("daily") != nil && *o.Flag("daily")
	if daily && !want {
		return usage("--daily is a modifier of --time-series — use 'dit pnl --time-series --daily' (see 'dit help pnl')")
	}
	if len(o.Positionals) > 0 {
		return usage(fmt.Sprintf("unexpected argument '%s' — 'dit pnl' filters with --account/--tickers/--ccy (see 'dit help pnl')", o.Positionals[0]))
	}
	loadContext := c
	loadContext.Offline = false // pnl is store-only, even under --offline.
	p, m, err := summaryLoad(loadContext)
	if err != nil {
		return err
	}
	if p == nil {
		if c.JSON {
			return c.WriteJSON(map[string]any{"ok": true, "schema": "pnl/1", "data": map[string]any{"empty": true, "note": "no portfolio found — add accounts and transactions first", "store": c.Layout.PortfolioDir}})
		}
		c.printf("No portfolio found (store: %s at %s).\nNothing to report — add accounts and transactions first.\n", c.Layout.Backend, c.Layout.PortfolioDir)
		return nil
	}
	accounts := p.Accounts
	perAccount := false
	if raw, ok := o.Values["account"]; ok {
		names := marketCSV(raw)
		if len(names) == 0 {
			return usage("--account needs at least one account name (see 'dit accounts')")
		}
		accounts = []model.Account{}
		seen := map[string]bool{}
		for _, name := range names {
			a, e := coverageAccount(name, *p)
			if e != nil {
				return e
			}
			if !seen[a.ID] {
				accounts = append(accounts, a)
				seen[a.ID] = true
			}
		}
		perAccount = true
	}
	var symbols map[string]bool
	var ccys map[model.Currency]bool
	if raw, ok := o.Values["tickers"]; ok {
		symbols = map[string]bool{}
		for _, s := range marketCSV(raw) {
			symbols[strings.ToUpper(s)] = true
		}
		if len(symbols) == 0 {
			return usage("--tickers needs at least one symbol")
		}
	}
	if raw, ok := o.Values["ccy"]; ok {
		ccys = map[model.Currency]bool{}
		codes := marketCSV(raw)
		if len(codes) == 0 {
			return usage("--ccy needs at least one currency code")
		}
		for _, s := range codes {
			cc, e := pnlCurrency(s, "--ccy")
			if e != nil {
				return e
			}
			ccys[cc] = true
		}
	}
	reporting := c.Display
	if reporting == "" {
		reporting = model.CAD
	}
	if raw, ok := o.Values["reporting-ccy"]; ok {
		reporting, err = pnlCurrency(raw, "--reporting-ccy")
		if err != nil {
			return err
		}
	}
	var from, to *model.Day
	for _, k := range []string{"from", "to"} {
		if raw, ok := o.Values[k]; ok {
			d, e := model.ParseDay(raw)
			if e != nil || len(raw) != 10 || d.String() != raw {
				return usage(fmt.Sprintf("invalid date '%s' — expected YYYY-MM-DD", raw))
			}
			if k == "from" {
				from = &d
			} else {
				to = &d
			}
		}
	}
	var ledgerStart *model.Day
	for _, a := range accounts {
		for _, tx := range p.TransactionsIn(a.ID) {
			if ledgerStart == nil || tx.Date < *ledgerStart {
				d := tx.Date
				ledgerStart = &d
			}
		}
	}
	var horizon *string
	if h {
		raw := o.Value("horizon")
		horizon = &raw
	}
	w, err := valuation.ResolvePnLWindow(horizon, from, to, model.Day(model.DayStartUTC(now.Unix())), ledgerStart)
	if err != nil {
		return usage(err.Error())
	}
	r := valuation.ComputePnL(p, m, w, accounts, perAccount, symbols, ccys, reporting)
	var series *valuation.PnLSeries
	if want {
		g := valuation.PnLGranularity(w)
		if daily {
			g = "daily"
		}
		s := valuation.ComputePnLSeries(p, m, w, g, accounts, perAccount, symbols, ccys, reporting, r)
		series = &s
	}
	if c.JSON {
		return c.WriteJSON(pnlJSON(r, accounts, symbols, ccys, series))
	}
	scope := []string{}
	if perAccount {
		names := []string{}
		for _, a := range accounts {
			names = append(names, DisplayName(a))
		}
		scope = append(scope, "  accounts: "+strings.Join(names, ", "))
	} else if len(accounts) == 0 {
		scope = append(scope, "  accounts: none in scope")
	}
	filters := []string{}
	if symbols != nil {
		filters = append(filters, "tickers "+strings.Join(pnlSymbols(symbols), ", "))
	}
	if ccys != nil {
		filters = append(filters, "ccy "+strings.Join(pnlCurrencies(ccys), ", "))
	}
	if len(filters) > 0 {
		scope = append(scope, "  filters: "+strings.Join(filters, " · "))
	}
	if series != nil {
		c.printf("%s\n", renderPnLSeries(r, *series, daily, scope, boldHeaders(c)))
	} else {
		c.printf("%s\n", renderPnL(r, scope, boldHeaders(c)))
	}
	return nil
}
func pnlCurrency(raw, option string) (model.Currency, error) {
	for _, cc := range model.KnownCurrencies() {
		if strings.EqualFold(raw, string(cc)) {
			return cc, nil
		}
	}
	return "", usage(fmt.Sprintf("unknown currency '%s' for %s — use e.g. CAD, USD, JPY, or GBp", raw, option))
}
func pnlSymbols(m map[string]bool) []string {
	out := []string{}
	for s := range m {
		out = append(out, s)
	}
	sort.Strings(out)
	return out
}
func pnlCurrencies(m map[model.Currency]bool) []string {
	out := []string{}
	for c := range m {
		out = append(out, string(c))
	}
	sort.Strings(out)
	return out
}
