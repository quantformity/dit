package cli

import (
	"dit/internal/decimal"
	"dit/internal/model"
	"dit/internal/text"
	"dit/internal/valuation"
	"fmt"
	"strings"
)

func pnlRange(w valuation.Window) string {
	if w.FromLedgerStart {
		return fmt.Sprintf("since first transaction (%s) … %s", w.Start, w.End)
	}
	return fmt.Sprintf("%s … %s", w.Start, w.End)
}
func pnlCell(d *decimal.Decimal, c model.Currency, r valuation.PnLReport, derived bool) string {
	v := pnlConverted(r, c, d)
	if v == nil {
		return "—"
	}
	mark := ""
	if derived {
		mark = "*"
	}
	if c != r.Reporting {
		q := r.Rates[c]
		if q.Via != "" || q.Stale > 0 {
			mark += "~"
		}
	}
	return text.Money(*v) + mark
}
func pnlQuiet(r valuation.PnLReport) string {
	if r.Activity == 0 {
		return "  No transactions in this window and no measurable price drift — nothing to report."
	}
	return fmt.Sprintf("  %d ledger line(s) in the window, none with P&L or measurable drift.", r.Activity)
}
func pnlNotes(lines []string, notes []string) []string {
	if len(notes) > 0 {
		lines = append(lines, "")
		for _, n := range notes {
			lines = append(lines, "  "+n)
		}
	}
	return lines
}
func renderPnL(r valuation.PnLReport, scope []string, bold bool) string {
	lines := []string{fmt.Sprintf("Historical P&L — %s (%s)", pnlRange(r.Window), r.Window.Label)}
	reporting := "  Reporting: " + string(r.Reporting)
	mixed := pnlMixed(r)
	if mixed {
		reporting += " (converted at the FX close on/before " + r.Window.End.String()
		if len(r.Rates) == 0 {
			reporting += " — none found: cross-currency rows dash)"
		} else {
			reporting += ")"
		}
	} else {
		reporting += " (as recorded — no conversion needed)"
	}
	lines = append(lines, reporting)
	lines = append(lines, scope...)
	if len(r.Rows) > 0 {
		lines = append(lines, "")
		headers := []string{"Symbol", "Accounts", "Realized", "Position Δ", "Total"}
		left := map[int]bool{0: true, 1: true}
		title := fmt.Sprintf("P&L (%s):", r.Reporting)
		if r.PerAccount {
			title = fmt.Sprintf("P&L (%s, per account):", r.Reporting)
			headers = []string{"Account", "Symbol", "From", "Realized", "Position Δ", "Total"}
			left[2] = true
		} else if mixed {
			title = fmt.Sprintf("P&L (%s, portfolio — 'From' marks each row's recorded currency):", r.Reporting)
			headers = []string{"Symbol", "From", "Accounts", "Realized", "Position Δ", "Total"}
			left[2] = true
		}
		lines = append(lines, title)
		rows := [][]string{}
		derived := false
		for _, row := range r.Rows {
			cells := []string{row.Symbol, strings.Join(row.Accounts, ", ")}
			if r.PerAccount {
				cells = []string{strings.Join(row.Accounts, ", "), row.Symbol, string(row.Currency)}
			} else if mixed {
				cells = []string{row.Symbol, string(row.Currency), strings.Join(row.Accounts, ", ")}
			}
			cells = append(cells, pnlCell(&row.Realized, row.Currency, r, false), pnlCell(row.Change, row.Currency, r, row.Derived), pnlCell(row.Total, row.Currency, r, row.Derived))
			rows = append(rows, cells)
			derived = derived || row.Derived
		}
		for _, l := range text.Table(headers, rows, left, bold) {
			lines = append(lines, "    "+l)
		}
		if derived {
			lines = append(lines, "    * position change uses DERIVED proxy history — approximation, not a quote")
		}
		stale := false
		for _, q := range r.Rates {
			stale = stale || q.Via != "" || q.Stale > 0
		}
		if stale {
			lines = append(lines, "    ~ FX taken from an EARLIER or DERIVED rate — dates and paths in the notes")
		}
	}
	if len(r.Totals) > 0 {
		if len(r.Rows) > 0 {
			lines = append(lines, "")
		}
		if r.Combined == nil {
			lines = append(lines, fmt.Sprintf("  Total (%s): — (not combinable — see notes; native figures stay in --json)", r.Reporting))
		} else {
			label := fmt.Sprintf("  Total (%s): %s", r.Reporting, text.Money(*r.Combined))
			rates := []string{}
			for _, t := range r.Totals {
				if q, ok := r.Rates[t.Currency]; ok {
					rates = append(rates, fmt.Sprintf("%s→%s %s (%s)", t.Currency, r.Reporting, text.Quantity(q.Rate), q.AsOf))
				}
			}
			if len(rates) > 0 {
				label += "  [converted at " + strings.Join(rates, ", ") + "]"
			}
			lines = append(lines, label)
		}
	}
	if len(r.Rows) == 0 {
		lines = append(lines, "", pnlQuiet(r))
	}
	return strings.Join(pnlNotes(lines, r.Notes), "\n")
}
func pnlSum(r valuation.PnLReport, pick func(valuation.CurrencyPnL) *decimal.Decimal) *decimal.Decimal {
	sum := decimal.Zero
	for _, t := range r.Totals {
		v := pnlConverted(r, t.Currency, pick(t))
		if v == nil {
			return nil
		}
		sum = sum.Add(*v)
	}
	return &sum
}
func renderPnLSeries(r valuation.PnLReport, s valuation.PnLSeries, forced bool, scope []string, bold bool) string {
	mixed := pnlMixed(r)
	lines := []string{fmt.Sprintf("Historical P&L over time — %s (%s)", pnlRange(r.Window), r.Window.Label)}
	reporting := "  Reporting: " + string(r.Reporting)
	if mixed {
		reporting += " (each period converted at its own end-date FX)"
	} else {
		reporting += " (as recorded — no conversion needed)"
	}
	lines = append(lines, reporting)
	lines = append(lines, scope...)
	label := "  series: " + s.Granularity + " periods"
	if forced {
		label += " (forced)"
	}
	if s.CollapsedEmpty > 0 {
		label += fmt.Sprintf(" — %d quiet period(s) collapsed", s.CollapsedEmpty)
	}
	lines = append(lines, label)
	if len(s.Points) == 0 {
		lines = append(lines, "", pnlQuiet(r))
		if s.CollapsedUnmeasurable > 0 {
			lines = append(lines, fmt.Sprintf("  %d period(s) had NO usable price pair — unmeasurable, not zero; nothing was invented for them", s.CollapsedUnmeasurable))
		}
		return strings.Join(pnlNotes(lines, r.Notes), "\n")
	}
	lines = append(lines, "", fmt.Sprintf("P&L per period (%s; — = not knowable, never zero):", r.Reporting))
	rows := [][]string{}
	marked := false
	for _, p := range s.Points {
		derived, stale := false, false
		for _, row := range p.Report.Rows {
			derived = derived || row.Derived
		}
		for _, q := range p.Report.Rates {
			stale = stale || q.Via != "" || q.Stale > 0
		}
		label := p.Label
		if derived {
			label += "*"
		}
		if stale {
			label += "~"
		}
		marked = marked || derived || stale
		if p.Report.Activity > 0 {
			label += fmt.Sprintf(" · %d tx", p.Report.Activity)
		}
		cell := func(pick func(valuation.CurrencyPnL) *decimal.Decimal) string {
			v := pnlSum(p.Report, pick)
			if v == nil {
				return "—"
			}
			return text.Money(*v)
		}
		rows = append(rows, []string{label, cell(func(t valuation.CurrencyPnL) *decimal.Decimal { return &t.Realized }), cell(func(t valuation.CurrencyPnL) *decimal.Decimal { return t.Change }), cell(func(t valuation.CurrencyPnL) *decimal.Decimal { return t.Total })})
	}
	for _, l := range text.Table([]string{"Period", "Realized", "Position Δ", "Total"}, rows, map[int]bool{0: true}, bold) {
		lines = append(lines, "  "+l)
	}
	if marked {
		lines = append(lines, "  (* derived price history · ~ FX taken from an earlier or derived rate — see notes)")
	}
	if !s.Reconciles {
		lines = append(lines, "  Σ periods ≠ window total — dashed periods are GAPS, not zeros; totals above must not be summed")
	} else if !mixed {
		lines = append(lines, "  Σ periods = window total (exact — every period measurable, single currency)")
	} else {
		sum := decimal.Zero
		complete := true
		for _, p := range s.Points {
			v := pnlSum(p.Report, func(t valuation.CurrencyPnL) *decimal.Decimal { return t.Total })
			if v == nil {
				complete = false
				break
			}
			sum = sum.Add(*v)
		}
		if !complete {
			lines = append(lines, fmt.Sprintf("  Σ %s withheld — FX history does not cover every period; nothing is summed at a guessed rate", r.Reporting))
		} else if r.Combined != nil {
			diff := sum.Sub(*r.Combined)
			if diff.Sign() < 0 {
				diff = diff.Neg()
			}
			if diff.Cmp(decimal.MustParse("0.005")) < 0 {
				lines = append(lines, "  Σ periods = window total (exact — same FX throughout)")
			} else {
				lines = append(lines, fmt.Sprintf("  Σ periods ≠ window total in %s — the difference is FX TIMING (each period converts at its own close); the native slices still add exactly", r.Reporting))
			}
		} else {
			lines = append(lines, fmt.Sprintf("  Σ %s withheld — the window total itself is not combinable (see notes)", r.Reporting))
		}
	}
	if s.CollapsedUnmeasurable > 0 {
		lines = append(lines, fmt.Sprintf("  (%d period(s) hidden with UNMEASURABLE drift (no price pair) — unmeasurable is NOT zero)", s.CollapsedUnmeasurable))
	}
	return strings.Join(pnlNotes(lines, r.Notes), "\n")
}
