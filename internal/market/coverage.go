// Package market computes offline facts over stored observations and ledger values.
package market

import (
	"dit/internal/decimal"
	"dit/internal/model"
	"sort"
	"strings"
	"time"
)

const GapReportLimitDays = 10
const daySeconds model.Day = 86400

type Range struct{ First, Last model.Day }
type Gap struct {
	Days     int
	From, To model.Day
}
type SymbolCoverage struct {
	Symbol                             string
	Currency                           model.Currency
	Accounts                           []string
	SeriesFound, UsableSource, Derived bool
	SeriesCurrency                     model.Currency
	PointsInWindow                     int
	WindowRange, SeriesRange           *Range
	LastClose                          *model.Day
	StaleDays                          *int
	LongestGap                         *Gap
}

func (r SymbolCoverage) Measurable() bool { return r.SeriesFound && r.UsableSource }
func (r SymbolCoverage) Status() string {
	if !r.SeriesFound {
		return "no-data"
	}
	if !r.UsableSource {
		return "wrong-currency"
	}
	if r.LastClose == nil {
		return "no-data"
	}
	if *r.StaleDays > 7 {
		return "stale"
	}
	if r.LongestGap != nil {
		return "gaps"
	}
	return "ok"
}

type FXChainCoverage struct {
	From, To                           model.Currency
	ChainLabel                         string
	UsableNow                          bool
	LastAsOf                           *model.Day
	StaleDays                          *int
	BoundariesTotal, BoundariesMissing int
	MissingExample                     *model.Day
}
type CoverageReport struct {
	AsOf, WindowStart model.Day
	SeriesGranularity string
	Symbols           []SymbolCoverage
	FX                []FXChainCoverage
}

func (r CoverageReport) Complete() bool {
	for _, s := range r.Symbols {
		if !s.Measurable() || s.StaleDays == nil || *s.StaleDays > 7 {
			return false
		}
	}
	for _, f := range r.FX {
		if !f.UsableNow || f.BoundariesMissing != 0 {
			return false
		}
	}
	return true
}
func (r CoverageReport) IsEmpty() bool { return len(r.Symbols) == 0 && len(r.FX) == 0 }
func DayDiff(from, to model.Day) int   { return int((to - from) / daySeconds) }

// A trailing hole is staleness, not an inside gap. Equal-sized runs keep
// the earliest example, and a fully dark window is always stated explicitly.
func LongestGap(days map[model.Day]bool, from, to model.Day) *Gap {
	total := DayDiff(from, to) + 1
	if total <= GapReportLimitDays {
		return nil
	}
	var best *Gap
	var start *model.Day
	any := false
	for d := from; d <= to; d += daySeconds {
		if !days[d] {
			if start == nil {
				v := d
				start = &v
			}
			continue
		}
		any = true
		if start != nil {
			n := DayDiff(*start, d)
			if best == nil || n > best.Days {
				best = &Gap{n, *start, d - daySeconds}
			}
			start = nil
		}
	}
	if !any {
		return &Gap{total, from, to}
	}
	if best == nil || best.Days < GapReportLimitDays {
		return nil
	}
	return best
}

// A watermark records what was requested, not what was observed. Keep the
// two dates separate so verified holidays never masquerade as stored closes.
func Watermark(series *model.PriceSeries) (observed, verified *model.Day) {
	if series == nil {
		return nil, nil
	}
	if len(series.Points) > 0 {
		d := series.Points[len(series.Points)-1].Day
		observed = &d
	}
	if series.CoveredThrough != nil {
		d := *series.CoveredThrough
		verified = &d
	}
	return
}
func AuditSymbol(symbol string, currency model.Currency, accounts []string, series *model.PriceSeries, from, to model.Day) SymbolCoverage {
	r := SymbolCoverage{Symbol: symbol, Currency: currency, Accounts: append([]string{}, accounts...)}
	sort.Strings(r.Accounts)
	if series == nil || len(series.Points) == 0 {
		return r
	}
	r.SeriesFound = true
	r.SeriesCurrency = series.Currency
	r.UsableSource = series.Currency == currency || series.Currency == model.Unknown || series.Currency == ""
	r.SeriesRange = &Range{series.Points[0].Day, series.Points[len(series.Points)-1].Day}
	days := map[model.Day]bool{}
	for _, p := range series.Points {
		days[p.Day] = true
		if p.Day <= to {
			d := p.Day
			r.LastClose = &d
			n := DayDiff(d, to)
			r.StaleDays = &n
		}
		if p.Day < from || p.Day > to {
			continue
		}
		r.PointsInWindow++
		r.Derived = r.Derived || p.Via != ""
		if r.WindowRange == nil {
			r.WindowRange = &Range{p.Day, p.Day}
		}
		r.WindowRange.Last = p.Day
	}
	if r.UsableSource {
		r.LongestGap = LongestGap(days, from, to)
	}
	return r
}
func Boundaries(from, to model.Day) (string, []model.Day) {
	n := DayDiff(from, to) + 1
	label := "daily"
	step := daySeconds
	if n > 56 {
		label = "monthly"
	} else if n > 10 {
		label = "weekly"
		step *= 7
	}
	out := []model.Day{}
	for d := from; d <= to; {
		end := d + step - daySeconds
		if label == "monthly" {
			t := d.DayTime()
			end = model.Day(time.Date(t.Year(), t.Month()+1, 1, 0, 0, 0, 0, time.UTC).Unix()) - daySeconds
		}
		if end > to {
			end = to
		}
		out = append(out, end)
		d = end + daySeconds
	}
	return label, out
}

type fxAnswer struct {
	rate  decimal.Decimal
	day   model.Day
	label string
}

func fxQuote(data model.MarketData, from, to model.Currency, day model.Day, limit int) *fxAnswer {
	if from == to || from == model.Unknown || to == model.Unknown {
		return nil
	}
	leg := func(a, b model.Currency) *model.DailyPrice {
		p, ok := data.CloseOnOrBefore(string(a)+"/"+string(b), day)
		if !ok || DayDiff(p.Day, day) > limit {
			return nil
		}
		return &p
	}
	if p := leg(from, to); p != nil {
		label := p.Via
		if label == "" {
			label = string(from) + "/" + string(to) + " direct"
		}
		return &fxAnswer{p.Price, p.Day, label}
	}
	if p := leg(to, from); p != nil && !p.Price.IsZero() {
		return &fxAnswer{decimal.FromInt(1).Div(p.Price, 38), p.Day, "inverted " + string(to) + "/" + string(from)}
	}
	hub := func(a, b model.Currency) *fxAnswer {
		if p := leg(a, b); p != nil {
			return &fxAnswer{rate: p.Price, day: p.Day}
		}
		if p := leg(b, a); p != nil && !p.Price.IsZero() {
			return &fxAnswer{rate: decimal.FromInt(1).Div(p.Price, 38), day: p.Day}
		}
		return nil
	}
	if from != model.USD && to != model.USD {
		a, b := hub(from, model.USD), hub(model.USD, to)
		if a != nil && b != nil && !a.rate.IsZero() {
			d := a.day
			if b.day > d {
				d = b.day
			}
			return &fxAnswer{a.rate.Mul(b.rate), d, "derived via USD (" + string(from) + "→USD→" + string(to) + ")"}
		}
	}
	return nil
}
func AuditFX(data model.MarketData, from, to model.Currency, day model.Day, boundaries []model.Day) FXChainCoverage {
	r := FXChainCoverage{From: from, To: to, BoundariesTotal: len(boundaries)}
	if q := fxQuote(data, from, to, day, 36500); q != nil {
		r.ChainLabel = q.label
		r.LastAsOf = &q.day
		n := DayDiff(q.day, day)
		r.StaleDays = &n
	}
	r.UsableNow = fxQuote(data, from, to, day, 7) != nil
	for _, d := range boundaries {
		if fxQuote(data, from, to, d, 7) == nil {
			r.BoundariesMissing++
			if r.MissingExample == nil {
				v := d
				r.MissingExample = &v
			}
		}
	}
	return r
}

type positionKey struct {
	symbol   string
	currency model.Currency
}

func accountName(a model.Account) string {
	if a.Name != nil && strings.TrimSpace(*a.Name) != "" {
		return strings.TrimSpace(*a.Name)
	}
	id := strings.ReplaceAll(a.ID, "-", "")
	if len(id) > 4 {
		id = id[:4]
	}
	return "Account " + id
}

// Replay only the state coverage needs; sales clamp to zero just as the
// balance engine does, so untracked shorts never create imaginary holdings.
func Report(portfolio model.Portfolio, accounts []model.Account, asOf model.Day, windowStart *model.Day, reporting model.Currency, data model.MarketData) CoverageReport {
	start := asOf
	for _, tx := range portfolio.Transactions {
		if tx.Date <= asOf && tx.Date < start {
			start = tx.Date
		}
	}
	if windowStart != nil {
		start = *windowStart
	}
	if start > asOf {
		start = asOf
	}
	gran, boundaries := Boundaries(start, asOf)
	r := CoverageReport{AsOf: asOf, WindowStart: start, SeriesGranularity: gran, Symbols: []SymbolCoverage{}, FX: []FXChainCoverage{}}
	holders := map[positionKey][]string{}
	currencies := map[model.Currency]bool{}
	scoped := map[string]bool{}
	for _, a := range accounts {
		scoped[strings.ToUpper(a.ID)] = true
		history := portfolio.TransactionsIn(a.ID)
		sort.SliceStable(history, func(i, j int) bool { return history[i].Date < history[j].Date })
		held := map[positionKey]decimal.Decimal{}
		cash := map[model.Currency]decimal.Decimal{}
		gics := map[string]model.Transaction{}
		for _, tx := range history {
			if tx.Date > asOf {
				continue
			}
			cash[tx.Currency] = cash[tx.Currency].Add(tx.CashImpact())
			if tx.Kind.FX != nil {
				f := tx.Kind.FX
				cash[f.FromCurrency] = cash[f.FromCurrency].Sub(f.FromAmount)
			}
			if tx.Kind.Stock != nil {
				k := positionKey{tx.Kind.Stock.Ticker, tx.Currency}
				switch tx.Kind.Type {
				case model.KindStockPurchase:
					held[k] = held[k].Add(tx.Kind.Stock.Shares)
				case model.KindStockSale:
					v := held[k].Sub(tx.Kind.Stock.Shares)
					if v.Sign() < 0 {
						v = decimal.Zero
					}
					held[k] = v
				}
			}
			if tx.Kind.GIC != nil {
				gics[tx.ID] = tx
			}
			if tx.Kind.Redemption != nil {
				delete(gics, tx.Kind.Redemption.PurchaseID)
			}
		}
		for k, v := range held {
			if !v.IsZero() {
				holders[k] = append(holders[k], accountName(a))
				currencies[k.currency] = true
			}
		}
		for c, v := range cash {
			if !v.IsZero() {
				currencies[c] = true
			}
		}
		totals := map[model.Currency]decimal.Decimal{}
		for _, tx := range gics {
			totals[tx.Currency] = totals[tx.Currency].Add(tx.Kind.GIC.Principal)
		}
		for c, v := range totals {
			if !v.IsZero() {
				currencies[c] = true
			}
		}
	}
	txs := []model.Transaction{}
	for _, tx := range portfolio.Transactions {
		if scoped[strings.ToUpper(tx.AccountID)] && tx.Date >= start && tx.Date <= asOf {
			txs = append(txs, tx)
		}
	}
	for k, owners := range holders {
		need := start
		found := false
		for _, tx := range txs {
			if tx.TickerSymbol() == k.symbol && (!found || tx.Date < need) {
				need = tx.Date
				found = true
			}
		}
		r.Symbols = append(r.Symbols, AuditSymbol(k.symbol, k.currency, owners, data.Series[k.symbol], need, asOf))
	}
	sort.Slice(r.Symbols, func(i, j int) bool {
		a, b := r.Symbols[i], r.Symbols[j]
		if a.Symbol != b.Symbol {
			return a.Symbol < b.Symbol
		}
		return a.Currency < b.Currency
	})
	for c := range currencies {
		if c == reporting || c == model.Unknown || reporting == model.Unknown {
			continue
		}
		need := asOf
		for _, tx := range txs {
			match := tx.Currency == c
			for k := range holders {
				if k.currency == c && k.symbol == tx.TickerSymbol() {
					match = true
				}
			}
			if match && tx.Date < need {
				need = tx.Date
			}
		}
		ends := []model.Day{}
		for _, d := range boundaries {
			if d >= need {
				ends = append(ends, d)
			}
		}
		r.FX = append(r.FX, AuditFX(data, c, reporting, asOf, ends))
	}
	sort.Slice(r.FX, func(i, j int) bool { return r.FX[i].From < r.FX[j].From })
	return r
}
