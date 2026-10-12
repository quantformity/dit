package model

import (
	"encoding/json"
	"sort"

	"dit/internal/decimal"
)

// DailyPrice is one end-of-day observation, keyed by UTC calendar day.
type DailyPrice struct {
	// Day is normalized to UTC midnight on decode.
	Day Day `json:"day"`
	// Price is the close in the series currency.
	Price decimal.Decimal `json:"price"`
	// Via is provenance. Empty means a real observation (fetched or
	// imported); a label marks a model-generated value, which is never
	// silently equal to an observed one.
	Via string `json:"via,omitempty"`
}

// PriceSeries is the stored daily history for one asset, ascending and
// day-unique so a merge is a set membership test.
type PriceSeries struct {
	// Symbol is an equity symbol or an FX pair.
	Symbol string `json:"symbol"`
	// Currency is what the prices are denominated in. For an FX pair this
	// is the quote currency: USD/CAD prices are CAD per 1 USD.
	Currency Currency     `json:"currency"`
	Points   []DailyPrice `json:"points"`
	// CoveredThrough is the date a successful fetch has already verified:
	// "everything up to here was asked for; what exists, exists". It is why
	// repeated updates are cheap — holidays sit behind the watermark instead
	// of being re-requested forever.
	CoveredThrough *Day `json:"coveredThrough,omitempty"`
}

// MarketQuote is a snapshot price for a listed security. Snapshots decay, so
// each carries when it was fetched.
type MarketQuote struct {
	Symbol   string          `json:"symbol"`
	Currency Currency        `json:"currency"`
	Price    decimal.Decimal `json:"price"`
	AsOf     *Stamp          `json:"asOf,omitempty"`
	Source   *string         `json:"source,omitempty"`
}

// ExchangeRate is a snapshot rate: 1 unit of Base buys Rate units of Quote.
type ExchangeRate struct {
	Base   Currency        `json:"base"`
	Quote  Currency        `json:"quote"`
	Rate   decimal.Decimal `json:"rate"`
	AsOf   *Stamp          `json:"asOf,omitempty"`
	Source *string         `json:"source,omitempty"`
}

// MarketData is the market document: the second store, beside the portfolio.
//
// Two independent sections: the "latest snapshot" lists (at most one entry per
// symbol, overwritten by a refresh) and the daily series.
type MarketData struct {
	storedUpdatedAt  json.RawMessage
	decodedUpdatedAt Stamp
	UpdatedAt        *Stamp                  `json:"updatedAt,omitempty"`
	LatestQuotes     []MarketQuote           `json:"latestQuotes"`
	LatestRates      []ExchangeRate          `json:"latestRates"`
	Series           map[string]*PriceSeries `json:"series"`
}

// marketWire is the raw shape, kept separate so decoding can decide what to do
// about a section that fails.
type marketWire struct {
	UpdatedAt    *Stamp                  `json:"updatedAt"`
	LatestQuotes []MarketQuote           `json:"latestQuotes"`
	LatestRates  []ExchangeRate          `json:"latestRates"`
	Series       map[string]*PriceSeries `json:"series"`
}

// UnmarshalJSON degrades rather than refusing to start.
//
// A market store is a refetchable cache, so a section that fails to decode is
// dropped and the rest still works — this mirrors the Swift store decoder,
// which treats a broken cache as a reason to refetch, not a reason to brick
// the CLI. Bundle import is the opposite on purpose (see internal/bundle):
// a file is not refetchable, so a damaged bundle is refused rather than
// partially read.
func (m *MarketData) UnmarshalJSON(data []byte) error {
	var wire marketWire
	if err := json.Unmarshal(data, &wire); err != nil {
		// Nothing is trustworthy in a document that will not parse; start
		// empty rather than half-load it.
		*m = MarketData{LatestQuotes: []MarketQuote{}, LatestRates: []ExchangeRate{}, Series: map[string]*PriceSeries{}}
		return nil
	}
	m.UpdatedAt = wire.UpdatedAt
	m.storedUpdatedAt, m.decodedUpdatedAt = nil, 0
	var original struct {
		UpdatedAt json.RawMessage `json:"updatedAt"`
	}
	_ = json.Unmarshal(data, &original)
	if wire.UpdatedAt != nil {
		encoded, _ := wire.UpdatedAt.MarshalJSON()
		var before, after json.Number
		if json.Unmarshal(original.UpdatedAt, &before) == nil && json.Unmarshal(encoded, &after) == nil {
			x, _ := before.Float64()
			y, _ := after.Float64()
			if x != y {
				m.storedUpdatedAt, m.decodedUpdatedAt = original.UpdatedAt, *wire.UpdatedAt
			}
		}
	}
	m.LatestQuotes = wire.LatestQuotes
	if m.LatestQuotes == nil {
		m.LatestQuotes = []MarketQuote{}
	}
	m.LatestRates = wire.LatestRates
	if m.LatestRates == nil {
		m.LatestRates = []ExchangeRate{}
	}
	m.Series = map[string]*PriceSeries{}
	for key, series := range wire.Series {
		if series == nil || series.Symbol == "" {
			continue
		}
		series.Points = normalizePoints(series.Points)
		m.Series[key] = series
	}
	return nil
}

// MarshalJSON retains the cache's original reference-epoch timestamp when unchanged.
// Adding the Unix epoch on decode can otherwise lose a bit of fractional precision.
func (m MarketData) MarshalJSON() ([]byte, error) {
	type plain MarketData
	raw, err := json.Marshal(plain(m))
	if err != nil || m.storedUpdatedAt == nil || m.UpdatedAt == nil || *m.UpdatedAt != m.decodedUpdatedAt {
		return raw, err
	}
	var fields map[string]json.RawMessage
	if err = json.Unmarshal(raw, &fields); err != nil {
		return nil, err
	}
	fields["updatedAt"] = m.storedUpdatedAt
	return json.Marshal(fields)
}

// normalizePoints sorts ascending and drops duplicate days, keeping the first
// observation of each day: real observations are what was stored first.
func normalizePoints(points []DailyPrice) []DailyPrice {
	if len(points) == 0 {
		return []DailyPrice{}
	}
	sorted := append([]DailyPrice(nil), points...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].Day < sorted[j].Day })
	out := make([]DailyPrice, 0, len(sorted))
	seen := make(map[Day]bool, len(sorted))
	for _, point := range sorted {
		day := Day(DayStartUTC(int64(point.Day)))
		if seen[day] {
			continue
		}
		seen[day] = true
		point.Day = day
		out = append(out, point)
	}
	return out
}

// TotalPoints counts every stored daily close across every series. Reporting
// only: a bundle export prints it and a replace compares "was" against it.
func (m MarketData) TotalPoints() int {
	total := 0
	for _, series := range m.Series {
		total += len(series.Points)
	}
	return total
}

// IsEmpty reports a document with no facts in it.
func (m MarketData) IsEmpty() bool {
	return len(m.LatestQuotes) == 0 && len(m.LatestRates) == 0 && m.TotalPoints() == 0
}

// LatestQuoteFor returns the stored snapshot for a symbol, if any.
func (m MarketData) LatestQuoteFor(symbol string) *MarketQuote {
	normalized := NormalizeSymbol(symbol)
	for i := range m.LatestQuotes {
		if m.LatestQuotes[i].Symbol == normalized {
			return &m.LatestQuotes[i]
		}
	}
	return nil
}

// SeriesFor returns the daily series stored under a key.
func (m MarketData) SeriesFor(key string) *PriceSeries {
	return m.Series[key]
}

// CloseOnOrBefore finds the newest stored observation on or before a day, with
// its provenance, so a caller can tell an observed close from a derived one.
func (m MarketData) CloseOnOrBefore(key string, day Day) (DailyPrice, bool) {
	series := m.Series[key]
	if series == nil {
		return DailyPrice{}, false
	}
	for i := len(series.Points) - 1; i >= 0; i-- {
		if point := series.Points[i]; int64(point.Day) <= int64(day) {
			return point, true
		}
	}
	return DailyPrice{}, false
}

// CloseStrictlyBefore finds the latest stored observation strictly before the
// UTC day containing beforeUnix — the previous-close baseline for a live
// snapshot. A close from the quote's own day is not its "previous" close.
func (m MarketData) CloseStrictlyBefore(symbol string, beforeUnix int64) (DailyPrice, bool) {
	series := m.SeriesFor(symbol)
	if series == nil {
		return DailyPrice{}, false
	}
	cutoff := DayFromUnix(beforeUnix)
	for index := len(series.Points) - 1; index >= 0; index-- {
		if int64(series.Points[index].Day) < int64(cutoff) {
			return series.Points[index], true
		}
	}
	return DailyPrice{}, false
}
