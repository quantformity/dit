// Package provider observes market data — last prices and FX rates — for the
// valuation layer.
//
// Three decisions explain the shape of this package:
//
//   - The observation boundary is a struct of function values, not an
//     interface hierarchy. Last prices, FX rates, and daily closes are three
//     function values. Fakes are one-liners and the production wiring
//     is explicit instead of injected.
//
//   - Freshness is a property of the *consumer*, not the fetch. The cache
//     stores whatever came back (newer wins), and every valuation lookup
//     asks for a *fresh* observation: a stale quote degrades the position to
//     cost basis, it never silently marks it at yesterday's price.
//
//   - A provider that "succeeds but returns nothing" is a *data* answer
//     (nothing exists for that symbol — Yahoo's NOT_FOUND for a delisted
//     ticker), while an error is a *connection* answer (the empty result is
//     not trustworthy). The summary command renders the first as quiet cost
//     basis and the second as a "fetch failed" note that flips the
//     degraded flag.
package provider

import (
	"strings"
	"sync"
	"time"

	"dit/internal/decimal"
	"dit/internal/model"
)

// Quote is one last-price observation in a known currency.
type Quote struct {
	Symbol   string
	Currency model.Currency
	Price    decimal.Decimal
	AsOf     *time.Time
	Source   string
}

// Rate is one FX observation: 1 unit of Base buys Rate units of Quote.
// Rate(USD, CAD) == 1.42 means "1 USD buys 1.42 CAD".
type Rate struct {
	Base   model.Currency
	Quote  model.Currency
	Rate   decimal.Decimal
	AsOf   *time.Time
	Source string
}

// Error renders as one phrase. The exact wording is a Go-side contract
// (Swift prints its localized error enums); the *kind* taxonomy is what the
// note machinery branches on.
type Error struct {
	// Kind is one of: network, http, noData, decoding, allSymbolsFailed,
	// invalidSymbol.
	Kind string
	// Symbol names the observation that failed, when it is about one.
	Symbol string
	// Message is the human detail (status code, HTTP status, server text).
	Message string
}

func (e *Error) Error() string {
	switch e.Kind {
	case "network":
		return "network: " + e.Message
	case "http":
		return "http: status " + e.Message
	case "noData":
		where := "no data"
		if e.Symbol != "" {
			where = "no data for " + e.Symbol
		}
		if e.Message != "" {
			where += " (" + e.Message + ")"
		}
		return where
	case "decoding":
		return "unparseable response: " + e.Message
	case "allSymbolsFailed":
		return "every quote failed (" + e.Message + ")"
	default:
		out := "invalid symbol"
		if e.Symbol != "" {
			out += " " + e.Symbol
		}
		return out
	}
}

// DailySeries is a daily-close provider answer (empty is not a failure).
type DailySeries struct {
	Symbol   string
	Currency model.Currency
	Points   []model.DailyPrice
}

// Provider is the function-value market-data boundary.
type Provider struct {
	DailySeries func(symbol string, from, to model.Day) (DailySeries, error)
	// Quotes returns a last price for each of the requested symbols that
	// Yahoo knows. An empty slice is a *data* answer (none exists); an
	// error is a *connection* answer (the empty result is not trustworthy).
	Quotes func(symbols []string) ([]Quote, error)
	// Rate returns 1 unit of `from` quoted in `to`. It reports an error
	// when the pair cannot be observed at all.
	Rate func(from, to model.Currency) (Rate, error)
}

// normalizeSymbol is the shared symbol spelling: trimmed, uppercased, same
// as the Swift side's `normalizedSymbol`.
func normalizeSymbol(symbol string) string {
	return strings.ToUpper(strings.TrimSpace(symbol))
}

// parseCurrency accepts the curated codes (case-insensitively) and maps
// anything else to Unknown, mirroring the lenient Swift decoder.
func parseCurrency(code string) model.Currency {
	normalized := model.Currency(strings.ToUpper(strings.TrimSpace(code)))
	if normalized.IsKnown() {
		return normalized
	}
	return model.Unknown
}

type rateKey struct {
	from model.Currency
	to   model.Currency
}

// Cache is a thread-safe in-memory observation store: the provider fills it,
// the valuation drains it (freshly), and the JSON layer replays it for the
// per-holding provenance block. It performs no I/O itself.
type Cache struct {
	mu     sync.Mutex
	quotes map[string]Quote
	rates  map[rateKey]Rate
}

// NewCache returns an empty cache. One per command run, so an --offline
// run can never leak observations into an online one.
func NewCache() *Cache {
	return &Cache{quotes: map[string]Quote{}, rates: map[rateKey]Rate{}}
}

// newer reports whether observation `a` (by its asOf stamp) is strictly
// newer than `b`. A stampless observation never wins, which keeps a
// re-fetched quote from regressing against one that carries a time.
func newer(a, b *time.Time) bool {
	if a == nil {
		return false
	}
	if b == nil {
		return true
	}
	return a.After(*b)
}

// Upsert stores a quote. A newer observation wins (out-of-order provider
// responses cannot regress the cache).
// ensure makes a zero-value Cache usable: the maps initialize on first
// write, so an unaddressed Cache never panics at the call site.
func (c *Cache) ensure() {
	if c.quotes == nil {
		c.quotes = map[string]Quote{}
	}
	if c.rates == nil {
		c.rates = map[rateKey]Rate{}
	}
}

func (c *Cache) Upsert(quote Quote) {
	key := normalizeSymbol(quote.Symbol)
	if key == "" {
		return
	}
	stored := Quote{Symbol: key, Currency: quote.Currency, Price: quote.Price, AsOf: quote.AsOf, Source: quote.Source}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.ensure()
	if existing, ok := c.quotes[key]; ok && !newer(stored.AsOf, existing.AsOf) {
		return
	}
	c.quotes[key] = stored
}

// Upsert stores a rate, same newer-wins rule.
func (c *Cache) UpsertRate(rate Rate) {
	key := rateKey{from: rate.Base, to: rate.Quote}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.ensure()
	if existing, ok := c.rates[key]; ok && !newer(rate.AsOf, existing.AsOf) {
		return
	}
	c.rates[key] = rate
}

// Quote returns the cached quote for a symbol, regardless of age — for
// reporting. Valuation must use FreshQuote.
func (c *Cache) Quote(symbol string) *Quote {
	key := normalizeSymbol(symbol)
	c.mu.Lock()
	defer c.mu.Unlock()
	quote, ok := c.quotes[key]
	if !ok {
		return nil
	}
	return &quote
}

// FreshQuote returns the cached quote only when it was observed at all and
// is younger than maxAge. A future asOf (a provider clock ahead of ours) is
// tolerated, matching the Swift cache's `now - asOf <= maxAge` test.
func (c *Cache) FreshQuote(symbol string, maxAge time.Duration, now time.Time) *Quote {
	quote := c.Quote(symbol)
	if quote == nil || quote.AsOf == nil {
		return nil
	}
	if now.Sub(*quote.AsOf) > maxAge {
		return nil
	}
	return quote
}

// RatePair returns the stored observation for a currency pair, found in
// *either* direction — a stored USD→CAD pair answers CAD→USD lookups.
func (c *Cache) RatePair(from, to model.Currency) *Rate {
	c.mu.Lock()
	defer c.mu.Unlock()
	if rate, ok := c.rates[rateKey{from, to}]; ok {
		return &rate
	}
	if rate, ok := c.rates[rateKey{to, from}]; ok {
		return &rate
	}
	return nil
}

// RateValue returns the effective rate from→to, reciprocated when the stored
// pair runs the other way. Nil when no stored observation covers the pair.
func (c *Cache) RateValue(from, to model.Currency) *decimal.Decimal {
	rate := c.RatePair(from, to)
	if rate == nil {
		return nil
	}
	if rate.Base == from {
		return &rate.Rate
	}
	if rate.Rate.Sign() == 0 {
		return nil
	}
	reciprocal := decimal.FromInt(1).Div(rate.Rate, 38)
	return &reciprocal
}

// RoutedRate converts between two currencies using stored observations,
// routing through the hub when no direct pair exists:
//
//  1. a measured from→to pair (either direction) wins — it was actually
//     observed, not derived;
//  2. otherwise the product of the two hub legs, from→hub × hub→to, each
//     reciprocated as needed.
//
// This is what makes the hub fetch strategy (one rate per currency, see the
// plan the summary command builds) serve arbitrary currency pairs. Nil when
// either leg is missing — the caller then reports the conversion as
// unconverted instead of inventing a rate.
func (c *Cache) RoutedRate(from, to, hub model.Currency) *decimal.Decimal {
	if from == to {
		one := decimal.FromInt(1)
		return &one
	}
	if !from.IsKnown() || !to.IsKnown() {
		return nil
	}
	if from == hub || to == hub {
		return c.RateValue(from, to)
	}
	if direct := c.RateValue(from, to); direct != nil {
		return direct
	}
	first := c.RateValue(from, hub)
	second := c.RateValue(hub, to)
	if first == nil || second == nil || first.Sign() == 0 {
		return nil
	}
	product := first.Mul(*second)
	return &product
}
