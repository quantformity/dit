// Package valuation derives balances without changing either source document.
package valuation

import (
	"sort"
	"strings"
	"time"

	"dit/internal/decimal"
	"dit/internal/model"
	"dit/internal/provider"
)

type Amounts map[model.Currency]decimal.Decimal

type Position struct {
	Symbol                                                                          string
	Currency                                                                        model.Currency
	Shares, Cost, AverageCost, Value                                                decimal.Decimal
	Name                                                                            *string
	Price, Previous                                                                 *model.DailyPrice
	Basis                                                                           string
	Unrealized, UnrealizedDisplay, ValueDisplay, DayChange, DayDisplay, DayFraction *decimal.Decimal
	DayModel                                                                        bool
	AccountNames                                                                    []string
}
type Short struct {
	AccountName, Symbol string
	Currency            model.Currency
	Shares              decimal.Decimal
}
type Figures struct {
	CashByCurrency, PositionByCurrency, GICByCurrency, RealizedByCurrency, DividendsByCurrency, UnrealizedByCurrency, DayByCurrency Amounts
	Cash, PositionValue, GICValue, Realized, Dividends, Unrealized, DayChange, Total                                                *decimal.Decimal
}

// Income retains the replay's booked facts by instrument for historical windows.
type Income struct {
	Symbol   string
	Currency model.Currency
	Amount   decimal.Decimal
}

type Account struct {
	Income    []Income
	Account   model.Account
	Positions []Position
	Shorts    []Short
	Figures
}
type Summary struct {
	DisplayCurrency model.Currency
	Accounts        []Account
	Holdings        []Position
	Shorts          []Short
	Figures
}

func ptr(d decimal.Decimal) *decimal.Decimal             { return &d }
func add(m Amounts, c model.Currency, d decimal.Decimal) { m[c] = m[c].Add(d) }
func emptyFigures() Figures {
	return Figures{CashByCurrency: Amounts{}, PositionByCurrency: Amounts{}, GICByCurrency: Amounts{}, RealizedByCurrency: Amounts{}, DividendsByCurrency: Amounts{}, UnrealizedByCurrency: Amounts{}, DayByCurrency: Amounts{}}
}
func Name(a model.Account) string {
	if a.Name != nil && strings.TrimSpace(*a.Name) != "" {
		return strings.TrimSpace(*a.Name)
	}
	id := a.ID
	if len(id) > 4 {
		id = id[:4]
	}
	return "Account " + id
}

// FXRate prefers a measured pair to a reciprocal, and only then composes two
// USD legs. A missing leg must invalidate the entire conversion, not its cash.
func FXRate(m model.MarketData, from, to model.Currency, day model.Day) *decimal.Decimal {
	if from == to {
		return ptr(decimal.FromInt(1))
	}
	leg := func(a, b model.Currency) *decimal.Decimal {
		if p, ok := m.CloseOnOrBefore(string(a)+"/"+string(b), day); ok && p.Price.Sign() > 0 {
			return ptr(p.Price)
		}
		for _, r := range m.LatestRates {
			if r.Base == a && r.Quote == b && r.Rate.Sign() > 0 && (r.AsOf == nil || r.AsOf.AsDay() <= day) {
				return ptr(r.Rate)
			}
		}
		return nil
	}
	direct := func(a, b model.Currency) *decimal.Decimal {
		if r := leg(a, b); r != nil {
			return r
		}
		if r := leg(b, a); r != nil {
			return ptr(decimal.FromInt(1).Div(*r, 38))
		}
		return nil
	}
	if r := direct(from, to); r != nil {
		return r
	}
	if from != model.USD && to != model.USD {
		a, b := direct(from, model.USD), direct(model.USD, to)
		if a != nil && b != nil {
			return ptr(a.Mul(*b))
		}
	}
	return nil
}

// RateFunc converts one unit of `from` into `to`, reporting nil when no
// conversion exists.
type RateFunc func(from, to model.Currency) *decimal.Decimal

func convert(d decimal.Decimal, c, to model.Currency, rate RateFunc) *decimal.Decimal {
	if c == to || d.IsZero() {
		return ptr(d)
	}
	if r := rate(c, to); r != nil {
		return ptr(d.Mul(*r))
	}
	return nil
}
func combined(a Amounts, to model.Currency, rate RateFunc) *decimal.Decimal {
	total := decimal.Zero
	for _, c := range currencies(a) {
		d := convert(a[c], c, to, rate)
		if d == nil {
			return nil
		}
		total = total.Add(*d)
	}
	return ptr(total)
}
func currencies(a Amounts) []model.Currency {
	out := make([]model.Currency, 0, len(a))
	for c := range a {
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}
func (f Figures) ValueByCurrency() Amounts {
	out := Amounts{}
	for _, m := range []Amounts{f.CashByCurrency, f.PositionByCurrency, f.GICByCurrency} {
		for c, d := range m {
			add(out, c, d)
		}
	}
	return out
}
func finish(f *Figures, to model.Currency, rate RateFunc) {
	f.Cash = combined(f.CashByCurrency, to, rate)
	f.PositionValue = combined(f.PositionByCurrency, to, rate)
	f.GICValue = combined(f.GICByCurrency, to, rate)
	f.Realized = combined(f.RealizedByCurrency, to, rate)
	f.Dividends = combined(f.DividendsByCurrency, to, rate)
	if len(f.UnrealizedByCurrency) > 0 {
		f.Unrealized = combined(f.UnrealizedByCurrency, to, rate)
	}
	if len(f.DayByCurrency) > 0 {
		f.DayChange = combined(f.DayByCurrency, to, rate)
	}
	if f.Cash != nil && f.PositionValue != nil && f.GICValue != nil {
		f.Total = ptr(f.Cash.Add(*f.PositionValue).Add(*f.GICValue))
	}
}

type key struct {
	c model.Currency
	s string
}
type lot struct{ shares, cost decimal.Decimal }
type gic struct {
	c         model.Currency
	principal decimal.Decimal
	product   string
}

// Observed is one price the mark prices a position at.
type Observed struct {
	Price decimal.Decimal
	// Day is the stored day of the observation; 0 for a live quote, which
	// has a timestamp but no stored day.
	Day model.Day
	// Via labels a derived proxy (e.g. an ETF standing in for the index);
	// empty for a direct observation.
	Via string
}

// Mark is the observation surface a valuation prices positions against.
// Stored closes are one such mark (storedMark); fresh provider quotes with
// the stored history behind them are another (Live). Cost basis is what is
// left when a mark declines to price a position — an explicit fallback,
// never a missing value.
type Mark struct {
	// Price is nil when the mark cannot price the position in its own
	// denomination (no fresh quote, or the quote in another currency).
	Price func(c model.Currency, symbol string) *Observed
	// Baseline is the observation the day change compares against; nil when
	// the mark carries no history.
	Baseline func(c model.Currency, symbol string) *model.DailyPrice
	// Rate is the FX surface the converted figures use.
	Rate RateFunc
}

// storedMark prices from the stored closes — the pre-provider path, kept in
// service of --offline (cost only) and of the tests that pin the ledger math
// against stored fixtures.
func storedMark(m model.MarketData, day model.Day) Mark {
	return Mark{
		Price: func(c model.Currency, symbol string) *Observed {
			series := m.SeriesFor(symbol)
			if series == nil || series.Currency != c {
				return nil
			}
			price, ok := m.CloseOnOrBefore(symbol, day)
			if !ok || price.Price.Sign() <= 0 {
				return nil
			}
			return &Observed{Price: price.Price, Day: price.Day, Via: price.Via}
		},
		Baseline: func(c model.Currency, symbol string) *model.DailyPrice {
			series := m.SeriesFor(symbol)
			if series == nil || series.Currency != c {
				return nil
			}
			price, ok := m.CloseOnOrBefore(symbol, day)
			if !ok || price.Price.Sign() <= 0 {
				return nil
			}
			prev, ok := m.CloseOnOrBefore(symbol, price.Day-1)
			if !ok || prev.Price.Sign() <= 0 {
				return nil
			}
			return &prev
		},
		Rate: func(from, to model.Currency) *decimal.Decimal {
			return FXRate(m, from, to, day)
		},
	}
}

// AccountBalance uses storage order to break same-day ties: a sale must see
// that day's preceding purchase, not an arbitrary sort permutation.
func AccountBalance(a model.Account, txs []model.Transaction, mark Mark, day model.Day) Account {
	out := Account{Account: a, Figures: emptyFigures(), Positions: []Position{}, Shorts: []Short{}}
	history := append([]model.Transaction(nil), txs...)
	sort.SliceStable(history, func(i, j int) bool { return history[i].Date < history[j].Date })
	held := map[key]lot{}
	active := map[string]gic{}
	shorts := map[key]decimal.Decimal{}
	income := map[key]decimal.Decimal{}
	for _, tx := range history {
		if tx.Date > day {
			continue
		}
		fee := decimal.Zero
		if tx.Fee != nil {
			fee = *tx.Fee
		}
		if tx.Kind.Type == model.KindFXConversion && tx.Kind.FX != nil {
			x := tx.Kind.FX
			add(out.CashByCurrency, x.FromCurrency, x.FromAmount.Neg())
			add(out.CashByCurrency, tx.Currency, x.ToAmount.Sub(fee))
		} else {
			add(out.CashByCurrency, tx.Currency, tx.CashImpact())
		}
		k := key{tx.Currency, tx.TickerSymbol()}
		l := held[k]
		switch tx.Kind.Type {
		case model.KindStockPurchase:
			x := tx.Kind.Stock
			if x == nil {
				continue
			}
			held[k] = lot{l.shares.Add(x.Shares), l.cost.Add(x.Amount()).Add(fee)}
		case model.KindStockSale:
			x := tx.Kind.Stock
			if x == nil {
				continue
			}
			cost := decimal.Zero
			if l.shares.Sign() > 0 {
				if x.Shares.Cmp(l.shares) >= 0 {
					cost = l.cost
				} else {
					cost = l.cost.Mul(x.Shares).Div(l.shares, 38)
				}
			}
			booked := x.Amount().Sub(fee).Sub(cost)
			add(out.RealizedByCurrency, tx.Currency, booked)
			income[k] = income[k].Add(booked)
			if x.Shares.Cmp(l.shares) > 0 {
				shorts[k] = shorts[k].Add(x.Shares.Sub(l.shares))
			}
			shares := l.shares.Sub(x.Shares)
			if shares.Sign() < 0 {
				shares = decimal.Zero
			}
			remaining := l.cost.Sub(cost)
			if remaining.Sign() < 0 {
				remaining = decimal.Zero
			}
			held[k] = lot{shares, remaining}
		case model.KindGICPurchase:
			if x := tx.Kind.GIC; x != nil {
				active[strings.ToUpper(tx.ID)] = gic{tx.Currency, x.Principal, x.Product}
			}
		case model.KindGICRedemption:
			if x := tx.Kind.Redemption; x != nil {
				id := strings.ToUpper(x.PurchaseID)
				if g, ok := active[id]; ok {
					booked := x.Proceeds.Sub(fee).Sub(g.principal)
					add(out.RealizedByCurrency, tx.Currency, booked)
					gk := key{g.c, "GIC: " + g.product}
					income[gk] = income[gk].Add(booked)
					delete(active, id)
				}
			}
		case model.KindDividend:
			if x := tx.Kind.Dividend; x != nil {
				net := x.Amount.Sub(fee)
				add(out.RealizedByCurrency, tx.Currency, net)
				income[k] = income[k].Add(net)
				add(out.DividendsByCurrency, tx.Currency, net)
			}
		}
	}
	for k, amount := range income {
		out.Income = append(out.Income, Income{k.s, k.c, amount})
	}
	sort.Slice(out.Income, func(i, j int) bool {
		if out.Income[i].Currency != out.Income[j].Currency {
			return out.Income[i].Currency < out.Income[j].Currency
		}
		return out.Income[i].Symbol < out.Income[j].Symbol
	})
	for _, g := range active {
		add(out.GICByCurrency, g.c, g.principal)
	}
	for k, l := range held {
		if l.shares.Sign() <= 0 {
			continue
		}
		p := Position{Symbol: k.s, Currency: k.c, Shares: l.shares, Cost: l.cost, AverageCost: l.cost.Div(l.shares, 38), Value: l.cost, Basis: "cost", AccountNames: []string{Name(a)}}
		// A mark declines to price a position rather than guessing: a quote in
		// the wrong currency, or no fresh quote at all, leaves the holding at
		// cost basis.
		if obs := mark.Price(k.c, k.s); obs != nil {
			if obs.Day != 0 {
				p.Price = &model.DailyPrice{Day: obs.Day, Price: obs.Price, Via: obs.Via}
			}
			p.Basis = "observed"
			if obs.Via != "" {
				p.Basis = "derived"
			}
			p.Value = l.shares.Mul(obs.Price)
			p.Unrealized = ptr(obs.Price.Sub(p.AverageCost).Mul(l.shares))
			if prev := mark.Baseline(k.c, k.s); prev != nil {
				p.Previous = prev
				p.DayModel = prev.Via != ""
				p.DayChange = ptr(obs.Price.Sub(prev.Price).Mul(l.shares))
				p.DayFraction = ptr(obs.Price.Sub(prev.Price).Div(prev.Price, 38))
			}
		}
		add(out.PositionByCurrency, k.c, p.Value)
		if p.Unrealized != nil {
			add(out.UnrealizedByCurrency, k.c, *p.Unrealized)
		}
		if p.DayChange != nil {
			add(out.DayByCurrency, k.c, *p.DayChange)
		}
		out.Positions = append(out.Positions, p)
	}
	sort.Slice(out.Positions, func(i, j int) bool {
		a, b := out.Positions[i], out.Positions[j]
		if a.Currency != b.Currency {
			return a.Currency < b.Currency
		}
		return a.Symbol < b.Symbol
	})
	for k, d := range shorts {
		out.Shorts = append(out.Shorts, Short{Name(a), k.s, k.c, d})
	}
	sort.Slice(out.Shorts, func(i, j int) bool {
		a, b := out.Shorts[i], out.Shorts[j]
		if a.Currency != b.Currency {
			return a.Currency < b.Currency
		}
		return a.Symbol < b.Symbol
	})
	finish(&out.Figures, a.ReportingCurrency, mark.Rate)
	return out
}

// Compute values the ledger as of day using only stored observations. Cost is
// retained as an explicitly labelled fallback, never presented as a last price.
func Compute(p *model.Portfolio, m model.MarketData, display model.Currency, day model.Day) Summary {
	return computeWith(p, storedMark(m, day), display, day)
}

func computeWith(p *model.Portfolio, mark Mark, display model.Currency, day model.Day) Summary {
	if display == "" {
		display = model.CAD
	}
	out := Summary{DisplayCurrency: display, Figures: emptyFigures(), Accounts: []Account{}, Holdings: []Position{}, Shorts: []Short{}}
	if p == nil {
		finish(&out.Figures, display, mark.Rate)
		return out
	}
	holdings := map[key]Position{}
	for _, a := range p.Accounts {
		b := AccountBalance(a, p.TransactionsIn(a.ID), mark, day)
		out.Accounts = append(out.Accounts, b)
		out.Shorts = append(out.Shorts, b.Shorts...)
		src := []Amounts{b.CashByCurrency, b.PositionByCurrency, b.GICByCurrency, b.RealizedByCurrency, b.DividendsByCurrency, b.UnrealizedByCurrency, b.DayByCurrency}
		dst := []Amounts{out.CashByCurrency, out.PositionByCurrency, out.GICByCurrency, out.RealizedByCurrency, out.DividendsByCurrency, out.UnrealizedByCurrency, out.DayByCurrency}
		for i, values := range src {
			for c, d := range values {
				add(dst[i], c, d)
			}
		}
		for _, pos := range b.Positions {
			k := key{pos.Currency, pos.Symbol}
			h, ok := holdings[k]
			if !ok {
				h = pos
			} else {
				h.Shares = h.Shares.Add(pos.Shares)
				h.Cost = h.Cost.Add(pos.Cost)
				h.Value = h.Value.Add(pos.Value)
				h.AccountNames = append(h.AccountNames, pos.AccountNames...)
				if pos.Unrealized != nil {
					h.Unrealized = ptr(h.Unrealized.Add(*pos.Unrealized))
				}
				if pos.DayChange != nil {
					h.DayChange = ptr(h.DayChange.Add(*pos.DayChange))
				}
			}
			holdings[k] = h
		}
	}
	for _, h := range holdings {
		h.AverageCost = h.Cost.Div(h.Shares, 38)
		h.ValueDisplay = convert(h.Value, h.Currency, display, mark.Rate)
		if h.Unrealized != nil {
			h.UnrealizedDisplay = convert(*h.Unrealized, h.Currency, display, mark.Rate)
		}
		if h.DayChange != nil {
			h.DayDisplay = convert(*h.DayChange, h.Currency, display, mark.Rate)
		}
		if t := p.TickerBySymbol(h.Symbol); t != nil {
			h.Name = t.Name
		}
		sort.Strings(h.AccountNames)
		names := []string{}
		for _, n := range h.AccountNames {
			if len(names) == 0 || names[len(names)-1] != n {
				names = append(names, n)
			}
		}
		h.AccountNames = names
		out.Holdings = append(out.Holdings, h)
	}
	sort.Slice(out.Holdings, func(i, j int) bool {
		a, b := out.Holdings[i], out.Holdings[j]
		if a.Symbol != b.Symbol {
			return a.Symbol < b.Symbol
		}
		return a.Currency < b.Currency
	})
	sort.SliceStable(out.Accounts, func(i, j int) bool {
		a, b := out.Accounts[i], out.Accounts[j]
		var x, y *decimal.Decimal
		if a.Total != nil {
			if a.Account.ReportingCurrency == display {
				x = ptr(*a.Total)
			} else if rate := mark.Rate(a.Account.ReportingCurrency, display); rate != nil {
				x = ptr(a.Total.Mul(*rate))
			}
		}
		if b.Total != nil {
			if b.Account.ReportingCurrency == display {
				y = ptr(*b.Total)
			} else if rate := mark.Rate(b.Account.ReportingCurrency, display); rate != nil {
				y = ptr(b.Total.Mul(*rate))
			}
		}
		if x == nil {
			return false
		}
		if y == nil {
			return true
		}
		return x.Cmp(*y) > 0
	})
	sort.Slice(out.Shorts, func(i, j int) bool {
		a, b := out.Shorts[i], out.Shorts[j]
		if a.AccountName != b.AccountName {
			return a.AccountName < b.AccountName
		}
		if a.Currency != b.Currency {
			return a.Currency < b.Currency
		}
		return a.Symbol < b.Symbol
	})
	finish(&out.Figures, display, mark.Rate)
	return out
}

// CostSummary implements the explicit --offline contract: no pricing and no
// FX. Keeping it separate prevents that mode from leaking into store reads.
func CostSummary(p *model.Portfolio, display model.Currency, day model.Day) Summary {
	return Compute(p, model.MarketData{}, display, day)
}

// StaleMark names a position priced from a stored close instead of a live
// quote, with how old that close is. Presentation data: the numbers are only
// honest while the report says where they came from.
type StaleMark struct {
	Symbol   string
	Currency model.Currency
	Price    decimal.Decimal
	Day      model.Day
	AgeDays  int
	// CurrencyUnverified marks a series whose currency was never recorded.
	// Such a price is used, but only in a report that says it is unverified.
	CurrencyUnverified bool
}

// StaleMarks reports the positions Live priced from a stored close. Kept next
// to Live on purpose: it must answer the same question the same way, or the
// label and the arithmetic drift apart and the report lies about its sources.
func StaleMarks(s Summary, cache *provider.Cache, m model.MarketData, maxAge time.Duration, now time.Time) []StaleMark {
	day := model.Day(model.DayStartUTC(now.Unix()))
	stale := []StaleMark{}
	for _, holding := range s.Holdings {
		if cache.FreshQuote(holding.Symbol, maxAge, now) != nil {
			continue
		}
		close, ok := m.CloseOnOrBefore(holding.Symbol, day)
		if !ok || close.Price.Sign() <= 0 {
			continue
		}
		series := m.SeriesFor(holding.Symbol)
		unverified := series != nil && series.Currency == ""
		stale = append(stale, StaleMark{
			Symbol:             holding.Symbol,
			Currency:           holding.Currency,
			Price:              close.Price,
			Day:                close.Day,
			AgeDays:            int((day - close.Day) / 86400),
			CurrencyUnverified: unverified,
		})
	}
	return stale
}

// Live prices positions from fresh provider observations (a quote provider's
// cache), the stored market data still supplying the previous-close baseline.
//
// When a quote cannot be had — fetch failed, too old, or quoted in another
// currency — the position is priced from its newest stored close. The Swift
// tool drops to cost basis there (CommandsCore.swift: "positions at cost
// basis"), so this is a deliberate divergence, chosen because a recent close
// is closer to today's truth than a purchase price from two years ago. Two
// rules keep the divergence honest:
//
//   - the day-change column stays empty. A delta between a stale close and
//     the one before it is not today's move, and printing it would claim one;
//   - a series whose currency was never recorded is used only after the
//     caller has been told it is unverified (see the CLI note), because a
//     price in an unknown currency is not a price at all.
//
// With no stored close either, there is no market figure to show and the
// position falls back to cost basis, matching Swift.
func Live(p *model.Portfolio, cache *provider.Cache, m model.MarketData, display model.Currency, maxAge time.Duration, now time.Time) Summary {
	day := model.Day(model.DayStartUTC(now.Unix()))
	// storedClose stands in for a missing live quote. An empty series currency
	// is allowed through (the tool has seen real series recorded that way) but
	// a *different* currency never is: that would add a foreign number to a
	// total instead of converting it.
	storedClose := func(c model.Currency, symbol string) *Observed {
		series := m.SeriesFor(symbol)
		if series == nil || (series.Currency != "" && series.Currency != c) {
			return nil
		}
		price, ok := m.CloseOnOrBefore(symbol, day)
		if !ok || price.Price.Sign() <= 0 {
			return nil
		}
		return &Observed{Price: price.Price, Day: price.Day}
	}
	mark := Mark{
		Price: func(c model.Currency, symbol string) *Observed {
			quote := cache.FreshQuote(symbol, maxAge, now)
			if quote != nil {
				if quote.Currency != c {
					return nil
				}
				return &Observed{Price: quote.Price}
			}
			return storedClose(c, symbol)
		},
		Baseline: func(c model.Currency, symbol string) *model.DailyPrice {
			quote := cache.FreshQuote(symbol, maxAge, now)
			if quote == nil || quote.Currency != c {
				return nil
			}
			bound := now
			if quote.AsOf != nil {
				bound = *quote.AsOf
			}
			prev, ok := m.CloseStrictlyBefore(symbol, bound.Unix())
			if !ok || prev.Price.Sign() <= 0 {
				return nil
			}
			return &prev
		},
		Rate: func(from, to model.Currency) *decimal.Decimal {
			if rate := cache.RoutedRate(from, to, model.USD); rate != nil {
				return rate
			}
			// No live route (the FX fetch failed, or there is nothing to route
			// through). A stored close may still bridge the pair; where none
			// does, the combined total is withheld rather than guessed.
			return FXRate(m, from, to, day)
		},
	}
	return computeWith(p, mark, display, day)
}
