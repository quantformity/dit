package cli

import (
	"dit/internal/decimal"
	"dit/internal/model"
	"dit/internal/text"
	"dit/internal/valuation"
	"fmt"
	"strings"
)

func pnlMoney(d *decimal.Decimal) any {
	if d == nil {
		return nil
	}
	return text.Fixed(*d, 2)
}
func pnlConverted(r valuation.PnLReport, c model.Currency, d *decimal.Decimal) *decimal.Decimal {
	if d == nil {
		return nil
	}
	if c == r.Reporting {
		return d
	}
	q, ok := r.Rates[c]
	if !ok {
		return nil
	}
	v := d.Mul(q.Rate)
	return &v
}
func pnlMixed(r valuation.PnLReport) bool {
	for _, t := range r.Totals {
		if t.Currency != r.Reporting {
			return true
		}
	}
	return false
}
func pnlCurrencyJSON(r valuation.PnLReport, reported bool) []any {
	out := []any{}
	for _, t := range r.Totals {
		j := map[string]any{"currency": string(t.Currency), "realized": text.Fixed(t.Realized, 2), "positionChange": pnlMoney(t.Change), "total": pnlMoney(t.Total), "incompletePositions": t.Incomplete}
		if reported && t.Currency != r.Reporting {
			j["reported"] = pnlMoney(pnlConverted(r, t.Currency, t.Total))
		}
		out = append(out, j)
	}
	return out
}
func pnlJSON(r valuation.PnLReport, accounts []model.Account, symbols map[string]bool, ccys map[model.Currency]bool, series *valuation.PnLSeries) map[string]any {
	var accountScope any = "all"
	if r.PerAccount {
		names := []string{}
		for _, a := range accounts {
			names = append(names, DisplayName(a))
		}
		accountScope = names
	}
	var symbolScope any = "all"
	if symbols != nil {
		symbolScope = pnlSymbols(symbols)
	}
	var currencyScope any = "all"
	if ccys != nil {
		currencyScope = pnlCurrencies(ccys)
	}
	positions := []any{}
	for _, row := range r.Rows {
		kind := "position"
		if row.Cash {
			kind = "cash"
		}
		var basis any
		if row.Change != nil {
			basis = "observed"
			if row.Derived {
				basis = "derived"
			}
		}
		j := map[string]any{"symbol": row.Symbol, "kind": kind, "accounts": row.Accounts, "currency": string(row.Currency), "realized": text.Fixed(row.Realized, 2), "positionChange": pnlMoney(row.Change), "total": pnlMoney(row.Total), "basis": basis}
		if row.Currency != r.Reporting {
			j["reported"] = map[string]any{"realized": pnlMoney(pnlConverted(r, row.Currency, &row.Realized)), "positionChange": pnlMoney(pnlConverted(r, row.Currency, row.Change)), "total": pnlMoney(pnlConverted(r, row.Currency, row.Total))}
		}
		positions = append(positions, j)
	}
	var combined any
	if r.Combined != nil {
		rates := []string{}
		for _, t := range r.Totals {
			if q, ok := r.Rates[t.Currency]; ok {
				rates = append(rates, fmt.Sprintf("%s→%s %s at %s", t.Currency, r.Reporting, text.Quantity(q.Rate), q.AsOf))
			}
		}
		var ratesJSON any
		if len(rates) > 0 {
			ratesJSON = strings.Join(rates, "; ")
		}
		combined = map[string]any{"currency": string(r.Reporting), "value": pnlMoney(r.Combined), "at": r.Window.End.String(), "rates": ratesJSON}
	}
	data := map[string]any{"window": map[string]any{"label": r.Window.Label, "start": r.Window.Start.String(), "end": r.Window.End.String(), "fromLedgerStart": r.Window.FromLedgerStart}, "scope": map[string]any{"accounts": accountScope, "tickers": symbolScope, "currencies": currencyScope, "reportingCurrency": string(r.Reporting), "perAccount": r.PerAccount}, "positions": positions, "currencyTotals": pnlCurrencyJSON(r, true), "activityCount": r.Activity, "notes": r.Notes, "combined": combined}
	if series != nil {
		points := []any{}
		for _, p := range series.Points {
			j := map[string]any{"label": p.Label, "start": p.Start.String(), "end": p.End.String(), "currencyTotals": pnlCurrencyJSON(p.Report, false)}
			if pnlMixed(r) {
				j["reportedTotal"] = pnlMoney(p.Report.Combined)
			}
			points = append(points, j)
		}
		data["series"] = map[string]any{"granularity": series.Granularity, "reconciles": series.Reconciles, "collapsedEmpty": series.CollapsedEmpty, "collapsedUnmeasurable": series.CollapsedUnmeasurable, "points": points}
	}
	return map[string]any{"ok": true, "schema": "pnl/1", "data": data}
}
