package valuation

// Historical windows use AccountBalance's replay at both boundaries. Only the
// report orchestration lives here: cost-basis and booked-income math stays in
// that single replay.
import (
	"dit/internal/decimal"
	"dit/internal/model"
	"dit/internal/text"
	"fmt"
	"sort"
	"strings"
)

type Window struct {
	Start, End      model.Day
	Label           string
	FromLedgerStart bool
}
type PnLRow struct {
	Symbol        string
	Cash          bool
	Accounts      []string
	Currency      model.Currency
	Realized      decimal.Decimal
	Change, Total *decimal.Decimal
	Derived       bool
}
type CurrencyPnL struct {
	Currency      model.Currency
	Realized      decimal.Decimal
	Change, Total *decimal.Decimal
	Incomplete    int
}
type FXQuote struct {
	Rate  decimal.Decimal
	AsOf  model.Day
	Via   string
	Stale int
}
type PnLReport struct {
	Window     Window
	PerAccount bool
	Reporting  model.Currency
	Rows       []PnLRow
	Totals     []CurrencyPnL
	Combined   *decimal.Decimal
	Rates      map[model.Currency]FXQuote
	Notes      []string
	Activity   int
}

// HistoricalRate never consults snapshot rates. Each leg must be at most
// seven UTC days old, including legs in a USD-hub route.
func HistoricalRate(m model.MarketData, from, to model.Currency, day model.Day) *FXQuote {
	if from == to || from == "" || to == "" {
		return nil
	}
	leg := func(a, b model.Currency) *model.DailyPrice {
		p, ok := m.CloseOnOrBefore(string(a)+"/"+string(b), day)
		if !ok || (day-p.Day)/86400 > 7 {
			return nil
		}
		return &p
	}
	if p := leg(from, to); p != nil {
		return &FXQuote{p.Price, p.Day, p.Via, int((day - p.Day) / 86400)}
	}
	if p := leg(to, from); p != nil && !p.Price.IsZero() {
		return &FXQuote{decimal.FromInt(1).Div(p.Price, 38), p.Day, "inverted " + string(to) + "/" + string(from), int((day - p.Day) / 86400)}
	}
	hub := func(a, b model.Currency) *FXQuote {
		if p := leg(a, b); p != nil {
			return &FXQuote{Rate: p.Price, AsOf: p.Day, Stale: int((day - p.Day) / 86400)}
		}
		if p := leg(b, a); p != nil && !p.Price.IsZero() {
			return &FXQuote{Rate: decimal.FromInt(1).Div(p.Price, 38), AsOf: p.Day, Stale: int((day - p.Day) / 86400)}
		}
		return nil
	}
	if from != model.USD && to != model.USD {
		a, b := hub(from, model.USD), hub(model.USD, to)
		if a != nil && b != nil && !a.Rate.IsZero() {
			at := a.AsOf
			if b.AsOf > at {
				at = b.AsOf
			}
			stale := a.Stale
			if b.Stale > stale {
				stale = b.Stale
			}
			return &FXQuote{a.Rate.Mul(b.Rate), at, fmt.Sprintf("derived via USD (%s→USD→%s)", from, to), stale}
		}
	}
	return nil
}

func pnlMark(m model.MarketData, day model.Day) Mark {
	return Mark{Price: func(c model.Currency, s string) *Observed {
		series := m.SeriesFor(s)
		if series == nil || (series.Currency != "" && series.Currency != c) {
			return nil
		}
		p, ok := m.CloseOnOrBefore(s, day)
		if !ok {
			return nil
		}
		return &Observed{p.Price, p.Day, p.Via}
	}, Baseline: func(model.Currency, string) *model.DailyPrice { return nil }, Rate: func(model.Currency, model.Currency) *decimal.Decimal { return nil }}
}

func ComputePnL(p *model.Portfolio, m model.MarketData, w Window, accounts []model.Account, perAccount bool, symbols map[string]bool, ccys map[model.Currency]bool, reporting model.Currency) PnLReport {
	out := PnLReport{Window: w, PerAccount: perAccount, Reporting: reporting, Rows: []PnLRow{}, Totals: []CurrencyPnL{}, Rates: map[model.Currency]FXQuote{}, Notes: []string{}}
	unmeasured := map[string]bool{}
	shorts := []Short{}
	for _, a := range accounts {
		history := p.TransactionsIn(a.ID)
		for _, tx := range history {
			if tx.Date >= w.Start && tx.Date <= w.End {
				out.Activity++
			}
		}
		before := AccountBalance(a, history, pnlMark(m, w.Start-86400), w.Start-86400)
		after := AccountBalance(a, history, pnlMark(m, w.End), w.End)
		open, close := map[key]Position{}, map[key]Position{}
		bookedBefore, bookedAfter := map[key]decimal.Decimal{}, map[key]decimal.Decimal{}
		keys := map[key]bool{}
		for _, pos := range before.Positions {
			k := key{pos.Currency, pos.Symbol}
			open[k] = pos
			keys[k] = true
		}
		for _, pos := range after.Positions {
			k := key{pos.Currency, pos.Symbol}
			close[k] = pos
			keys[k] = true
		}
		for _, v := range before.Income {
			k := key{v.Currency, v.Symbol}
			bookedBefore[k] = v.Amount
			keys[k] = true
		}
		for _, v := range after.Income {
			k := key{v.Currency, v.Symbol}
			bookedAfter[k] = v.Amount
			keys[k] = true
		}
		ordered := make([]key, 0, len(keys))
		for k := range keys {
			ordered = append(ordered, k)
		}
		sort.Slice(ordered, func(i, j int) bool {
			if ordered[i].c != ordered[j].c {
				return ordered[i].c < ordered[j].c
			}
			return ordered[i].s < ordered[j].s
		})
		for _, k := range ordered {
			cash := strings.HasPrefix(k.s, "GIC:")
			if symbols != nil && !cash && !symbols[k.s] {
				continue
			}
			if ccys != nil && !ccys[k.c] {
				continue
			}
			o, c := open[k], close[k]
			booked := bookedAfter[k].Sub(bookedBefore[k])
			change := ptr(decimal.Zero)
			derived := false
			if !cash {
				om, cm := decimal.Zero, decimal.Zero
				if o.Shares.Sign() > 0 {
					if o.Basis == "cost" {
						change = nil
					} else {
						om = o.Value.Sub(o.Cost)
						derived = o.Basis == "derived"
					}
				}
				if c.Shares.Sign() > 0 {
					if c.Basis == "cost" {
						change = nil
					} else {
						cm = c.Value.Sub(c.Cost)
						derived = derived || c.Basis == "derived"
					}
				}
				if change != nil {
					change = ptr(cm.Sub(om))
				}
			}
			if change == nil {
				unmeasured[k.s] = true
			}
			if booked.IsZero() && (change == nil || change.IsZero()) {
				continue
			}
			row := PnLRow{Symbol: k.s, Cash: cash, Accounts: []string{Name(a)}, Currency: k.c, Realized: booked, Change: change, Derived: derived}
			if change != nil {
				row.Total = ptr(booked.Add(*change))
			}
			out.Rows = append(out.Rows, row)
		}
		prevShort := map[key]decimal.Decimal{}
		for _, s := range before.Shorts {
			prevShort[key{s.Currency, s.Symbol}] = s.Shares
		}
		for _, s := range after.Shorts {
			s.Shares = s.Shares.Sub(prevShort[key{s.Currency, s.Symbol}])
			if s.Shares.Sign() > 0 && (symbols == nil || symbols[s.Symbol]) && (ccys == nil || ccys[s.Currency]) {
				shorts = append(shorts, s)
			}
		}
	}
	if !perAccount {
		groups := map[key]PnLRow{}
		for _, r := range out.Rows {
			k := key{r.Currency, r.Symbol}
			g, ok := groups[k]
			if !ok {
				g = r
			} else {
				g.Accounts = append(g.Accounts, r.Accounts...)
				g.Realized = g.Realized.Add(r.Realized)
				if g.Change == nil || r.Change == nil {
					g.Change = nil
				} else {
					g.Change = ptr(g.Change.Add(*r.Change))
				}
				g.Derived = g.Derived || r.Derived
			}
			groups[k] = g
		}
		out.Rows = []PnLRow{}
		for _, g := range groups {
			sort.Strings(g.Accounts)
			names := []string{}
			for _, n := range g.Accounts {
				if len(names) == 0 || names[len(names)-1] != n {
					names = append(names, n)
				}
			}
			g.Accounts = names
			g.Total = nil
			if g.Change != nil {
				g.Total = ptr(g.Realized.Add(*g.Change))
			}
			out.Rows = append(out.Rows, g)
		}
	}
	sort.SliceStable(out.Rows, func(i, j int) bool {
		a, b := out.Rows[i], out.Rows[j]
		if a.Currency != b.Currency {
			return a.Currency < b.Currency
		}
		return a.Symbol < b.Symbol
	})
	totals := map[model.Currency]CurrencyPnL{}
	proxy := map[string]bool{}
	for _, r := range out.Rows {
		t, ok := totals[r.Currency]
		if !ok {
			t = CurrencyPnL{Currency: r.Currency, Change: ptr(decimal.Zero)}
		}
		t.Realized = t.Realized.Add(r.Realized)
		if r.Change == nil {
			t.Incomplete++
			t.Change = nil
		} else if t.Change != nil {
			t.Change = ptr(t.Change.Add(*r.Change))
		}
		totals[r.Currency] = t
		if r.Derived {
			proxy[r.Symbol] = true
		}
	}
	for _, t := range totals {
		if t.Change != nil {
			t.Total = ptr(t.Realized.Add(*t.Change))
		}
		out.Totals = append(out.Totals, t)
	}
	sort.Slice(out.Totals, func(i, j int) bool { return out.Totals[i].Currency < out.Totals[j].Currency })
	combined := decimal.Zero
	complete := true
	unconverted := []string{}
	for _, t := range out.Totals {
		var rate *FXQuote
		if t.Currency != reporting {
			rate = HistoricalRate(m, t.Currency, reporting, w.End)
			if rate == nil {
				unconverted = append(unconverted, string(t.Currency)+"→"+string(reporting))
				complete = false
			} else {
				out.Rates[t.Currency] = *rate
			}
		}
		if t.Total == nil {
			complete = false
			continue
		}
		if t.Currency == reporting {
			combined = combined.Add(*t.Total)
		} else if rate != nil {
			combined = combined.Add(t.Total.Mul(rate.Rate))
		}
	}
	if complete {
		out.Combined = ptr(combined)
	}
	if len(unmeasured) > 0 {
		out.Notes = append(out.Notes, "no usable daily history for: "+strings.Join(pnlSorted(unmeasured), ", ")+" — rows involving those symbols carry dashed Position Δ/Total (quiet ones are left out of the table entirely); fill the store with 'dit market history --all'. Withheld totals are never guessed — and drop out of the combined total")
	}
	if len(proxy) > 0 {
		out.Notes = append(out.Notes, "position changes marked * used DERIVED proxy history ("+strings.Join(pnlSorted(proxy), ", ")+") — approximations, not quotes")
	}
	for _, s := range shorts {
		out.Notes = append(out.Notes, fmt.Sprintf("untracked short: %s sold %s %s (%s) beyond its holding — the short itself is not tracked, totals for its window are incomplete", s.AccountName, text.Quantity(s.Shares), s.Symbol, s.Currency))
	}
	if len(unconverted) > 0 {
		out.Notes = append(out.Notes, "no stored FX history for "+strings.Join(unconverted, ", ")+" on or before "+w.End.String()+" — those amounts are dashed in the reporting view, never converted at a guessed rate (native figures stay in --json; fill FX history with 'dit market history --all' or 'dit market import')")
	}
	dated := []string{}
	for _, t := range out.Totals {
		q, ok := out.Rates[t.Currency]
		if !ok {
			continue
		}
		label := fmt.Sprintf("%s→%s %s (close of %s", t.Currency, reporting, text.Quantity(q.Rate), q.AsOf)
		if q.Stale > 0 {
			label += fmt.Sprintf(", %dd earlier", q.Stale)
		}
		if q.Via != "" {
			label += ", " + q.Via
		}
		dated = append(dated, label+")")
	}
	if len(dated) > 0 {
		out.Notes = append(out.Notes, "converted at the stored FX close on/before "+w.End.String()+": "+strings.Join(dated, "; "))
	}
	return out
}
func pnlSorted(m map[string]bool) []string {
	out := []string{}
	for s := range m {
		out = append(out, s)
	}
	sort.Strings(out)
	return out
}
