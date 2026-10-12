package provider

import (
	"encoding/json"
	"fmt"
	"os"
	"time"

	"dit/internal/decimal"
	"dit/internal/model"
)

// A pin file (read with LoadStub) looks like:
//
//	{
//	  "quotes": [
//	    {"symbol": "SHOP.TO", "currency": "CAD", "price": "243.83",
//	     "asOf": "2026-10-09T20:00:00Z", "source": "pin"}
//	  ],
//	  "rates": [
//	    {"base": "USD", "quote": "CAD", "rate": "1.4254",
//	     "asOf": "2026-10-09T20:00:00Z", "source": "pin"}
//	  ]
//	}
//
// Semantics mirror the live provider, so both sides of a twin comparison
// degrade identically:
//   - a symbol with no pinned quote is *not returned* — a data answer,
//     exactly like Yahoo's NOT_FOUND for a delisted ticker;
//   - a missing rate, or a non-empty "transportError" field, is an *error* —
//     a connection answer that drives the degraded path (rate fetch failed /
//     quote fetch failed notes, positions at cost).
type Stub struct {
	quotes []Quote
	rates  []Rate
	// fail, when set, makes every call error — the offline simulation.
	fail string
}

type stubQuoteWire struct {
	Symbol   string  `json:"symbol"`
	Currency string  `json:"currency"`
	Price    string  `json:"price"`
	AsOf     *string `json:"asOf"`
	Source   string  `json:"source"`
}

type stubRateWire struct {
	Base   string  `json:"base"`
	Quote  string  `json:"quote"`
	Rate   string  `json:"rate"`
	AsOf   *string `json:"asOf"`
	Source string  `json:"source"`
}

type stubWire struct {
	// TransportError, when non-empty, makes every observation error with
	// this message — the deterministic equivalent of "the network is down".
	TransportError string          `json:"transportError"`
	DailyError     string          `json:"dailyError"`
	Quotes         []stubQuoteWire `json:"quotes"`
	Rates          []stubRateWire  `json:"rates"`
	Series         map[string]struct {
		Currency string `json:"currency"`
		Points   []struct {
			Day   string `json:"day"`
			Price string `json:"price"`
		} `json:"points"`
	} `json:"series"`
}

func parseStubAsOf(value *string) (*time.Time, error) {
	if value == nil || *value == "" {
		return nil, nil
	}
	stamp, err := time.Parse(time.RFC3339, *value)
	if err != nil {
		return nil, fmt.Errorf("pin file asOf %q: %w", *value, err)
	}
	utc := stamp.UTC()
	return &utc, nil
}

// LoadStub reads a pin file and returns a Provider with live-like semantics.
func LoadStub(path string) (Provider, error) {
	body, err := os.ReadFile(path)
	if err != nil {
		return Provider{}, err
	}
	var wire stubWire
	if err := json.Unmarshal(body, &wire); err != nil {
		return Provider{}, fmt.Errorf("pin file %s: %w", path, err)
	}
	stub := &Stub{fail: wire.TransportError}
	for index, raw := range wire.Quotes {
		normalized := normalizeSymbol(raw.Symbol)
		if normalized == "" {
			return Provider{}, fmt.Errorf("pin file quotes[%d]: missing symbol", index)
		}
		price, err := decimal.Parse(raw.Price)
		if err != nil {
			return Provider{}, fmt.Errorf("pin file quotes[%d] (%s): %w", index, normalized, err)
		}
		asOf, err := parseStubAsOf(raw.AsOf)
		if err != nil {
			return Provider{}, err
		}
		source := raw.Source
		if source == "" {
			source = "pin"
		}
		stub.quotes = append(stub.quotes, Quote{Symbol: normalized, Currency: parseCurrency(raw.Currency), Price: price, AsOf: asOf, Source: source})
	}
	for index, raw := range wire.Rates {
		from := parseCurrency(raw.Base)
		to := parseCurrency(raw.Quote)
		if !from.IsKnown() || !to.IsKnown() {
			return Provider{}, fmt.Errorf("pin file rates[%d]: unknown currency %q / %q", index, raw.Base, raw.Quote)
		}
		rate, err := decimal.Parse(raw.Rate)
		if err != nil {
			return Provider{}, fmt.Errorf("pin file rates[%d] (%s/%s): %w", index, from, to, err)
		}
		asOf, err := parseStubAsOf(raw.AsOf)
		if err != nil {
			return Provider{}, err
		}
		source := raw.Source
		if source == "" {
			source = "pin"
		}
		stub.rates = append(stub.rates, Rate{Base: from, Quote: to, Rate: rate, AsOf: asOf, Source: source})
	}
	daily := map[string]DailySeries{}
	for symbol, raw := range wire.Series {
		s := DailySeries{Symbol: symbol, Currency: parseCurrency(raw.Currency), Points: []model.DailyPrice{}}
		for _, p := range raw.Points {
			d, e := model.ParseDay(p.Day)
			if e != nil {
				return Provider{}, e
			}
			v, e := decimal.Parse(p.Price)
			if e != nil {
				return Provider{}, e
			}
			if v.Sign() > 0 {
				s.Points = append(s.Points, model.DailyPrice{Day: d, Price: v})
			}
		}
		daily[symbol] = s
	}
	return Provider{
		DailySeries: func(symbol string, from, to model.Day) (DailySeries, error) {
			if wire.DailyError != "" {
				return DailySeries{}, &Error{Kind: "network", Message: wire.DailyError}
			}
			if stub.fail != "" {
				return DailySeries{}, &Error{Kind: "network", Message: stub.fail}
			}
			s, ok := daily[symbol]
			if !ok {
				s = DailySeries{Symbol: symbol, Currency: model.Unknown}
			}
			points := []model.DailyPrice{}
			for _, p := range s.Points {
				if p.Day >= from && p.Day <= to {
					points = append(points, p)
				}
			}
			s.Points = points
			return s, nil
		},
		Quotes: func(symbols []string) ([]Quote, error) {
			if stub.fail != "" {
				return nil, &Error{Kind: "network", Message: stub.fail}
			}
			seen := map[string]bool{}
			got := []Quote{}
			for _, symbol := range symbols {
				key := normalizeSymbol(symbol)
				if key == "" || seen[key] {
					continue
				}
				seen[key] = true
				for i := range stub.quotes {
					if stub.quotes[i].Symbol == key {
						got = append(got, stub.quotes[i])
						break
					}
				}
			}
			return got, nil
		},
		Rate: func(from, to model.Currency) (Rate, error) {
			if stub.fail != "" {
				return Rate{}, &Error{Kind: "network", Message: stub.fail}
			}
			if !from.IsKnown() || !to.IsKnown() {
				return Rate{}, &Error{Kind: "invalidSymbol", Symbol: from.Code() + to.Code()}
			}
			if from == to {
				return Rate{Base: from, Quote: to, Rate: decimal.FromInt(1), Source: "pin"}, nil
			}
			for i := range stub.rates {
				if stub.rates[i].Base == from && stub.rates[i].Quote == to {
					return stub.rates[i], nil
				}
			}
			// Either direction is fine — a stored USD→CAD pair answers a
			// CAD→USD request, reciprocated, exactly like the live cache.
			for i := range stub.rates {
				if stub.rates[i].Base == to && stub.rates[i].Quote == from && stub.rates[i].Rate.Sign() > 0 {
					return Rate{Base: from, Quote: to, Rate: decimal.FromInt(1).Div(stub.rates[i].Rate, 38), AsOf: stub.rates[i].AsOf, Source: "pin"}, nil
				}
			}
			return Rate{}, &Error{Kind: "noData", Symbol: from.Code() + "/" + to.Code(), Message: "no such rate in pin file"}
		},
	}, nil
}
