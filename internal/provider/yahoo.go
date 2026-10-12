package provider

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"sync"
	"time"

	"dit/internal/decimal"
	"dit/internal/model"
)

// DefaultBaseURL is Yahoo's public chart endpoint — the one that still works
// without cookies or crumb, unlike /v7/finance/quote.
const DefaultBaseURL = "https://query1.finance.yahoo.com"

// DefaultUserAgent is the browser string Yahoo expects. Yahoo throttles
// non-browser agents with 429, so every request carries it.
const DefaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

// DefaultTimeout is the per-request budget. The summary is interactive work:
// a hung connection is a failure, not a pause.
const DefaultTimeout = 5 * time.Second

// YahooConfig tunes the Yahoo provider. Zero-value fields take the defaults.
type YahooConfig struct {
	BaseURL string
	// UserAgent overrides the browser default when a deployment needs its
	// own fingerprint.
	UserAgent string
	// Timeout per request.
	Timeout time.Duration
	// Do performs one HTTP request. nil uses a Client with Timeout. Tests
	// inject a scripted transport so `go test` never opens a socket — the
	// parse paths, the error classification, and the batch semantics all
	// run against canned responses.
	Do func(req *http.Request) (*http.Response, error)
}

// Yahoo is the live provider: one chart call per symbol, all symbols of a
// batch in flight concurrently.
func Yahoo(cfg YahooConfig) Provider {
	if cfg.BaseURL == "" {
		cfg.BaseURL = DefaultBaseURL
	}
	if cfg.UserAgent == "" {
		cfg.UserAgent = DefaultUserAgent
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = DefaultTimeout
	}
	do := cfg.Do
	if do == nil {
		client := &http.Client{Timeout: cfg.Timeout}
		do = client.Do
	}
	return Provider{
		DailySeries: func(symbol string, from, to model.Day) (DailySeries, error) {
			return yahooDaily(cfg, do, symbol, from, to)
		},
		Quotes: func(symbols []string) ([]Quote, error) {
			seen := map[string]bool{}
			unique := []string{}
			for _, symbol := range symbols {
				normalized := normalizeSymbol(symbol)
				if normalized == "" || seen[normalized] {
					continue
				}
				seen[normalized] = true
				unique = append(unique, normalized)
			}
			sort.Strings(unique)
			if len(unique) == 0 {
				return []Quote{}, nil
			}

			type outcome struct {
				quote     Quote
				err       *Error
				transport bool
			}
			results := make([]outcome, len(unique))
			var group sync.WaitGroup
			for index, symbol := range unique {
				group.Add(1)
				go func(index int, symbol string) {
					defer group.Done()
					quote, failure := yahooFetch(cfg, do, symbol)
					results[index] = outcome{quote: quote, err: failure.err, transport: failure.transport}
				}(index, symbol)
			}
			group.Wait()

			got := []Quote{}
			transportFailures, apiFailures := 0, 0
			for _, result := range results {
				if result.err == nil {
					got = append(got, result.quote)
				} else if result.transport {
					transportFailures++
				} else {
					apiFailures++
				}
			}
			// An empty result that reflects the connection, not the symbols,
			// is not trustworthy: report it as a hard failure so the caller
			// knows the quotes are *missing* rather than *nonexistent*.
			if len(got) == 0 && transportFailures > 0 {
				return nil, &Error{Kind: "allSymbolsFailed",
					Message: fmt.Sprintf("transport failures: %d, api failures: %d", transportFailures, apiFailures)}
			}
			return got, nil
		},
		Rate: func(from, to model.Currency) (Rate, error) {
			if !from.IsKnown() || !to.IsKnown() {
				return Rate{}, &Error{Kind: "invalidSymbol", Symbol: from.Code() + to.Code(),
					Message: "a currency Yahoo cannot be asked about"}
			}
			if from == to {
				return Rate{Base: from, Quote: to, Rate: decimal.FromInt(1), Source: "yahoo"}, nil
			}
			// e.g. USD→CAD is the chart "USDCAD=X", which prices CAD per 1 USD.
			quote, failure := yahooFetch(cfg, do, from.Code()+to.Code()+"=X")
			if failure.err != nil {
				return Rate{}, failure.err
			}
			return Rate{Base: from, Quote: to, Rate: quote.Price, AsOf: quote.AsOf, Source: "yahoo"}, nil
		},
	}
}

type yahooFailure struct {
	err       *Error
	transport bool
}

// chartWire models the chart API's lenient shape: almost everything is
// optional, because Yahoo has shipped every permutation of this body.
type chartWire struct {
	Chart *struct {
		Result *[]struct {
			Meta *struct {
				Currency string       `json:"currency"`
				Price    *json.Number `json:"regularMarketPrice"`
				AsOf     *float64     `json:"regularMarketTime"`
			} `json:"meta"`
		} `json:"result"`
		Error *struct {
			Code        string `json:"code"`
			Description string `json:"description"`
		} `json:"error"`
	} `json:"chart"`
}

// yahooFetch prices one symbol against the chart endpoint and classifies the
// failure: transport (connection, timeout, a body that cannot travel) is
// "the empty result is not trustworthy"; everything the API itself said is a
// data answer for that symbol.
func yahooFetch(cfg YahooConfig, do func(*http.Request) (*http.Response, error), symbol string) (Quote, yahooFailure) {
	if symbol == "" {
		return Quote{}, yahooFailure{err: &Error{Kind: "invalidSymbol", Symbol: symbol}}
	}
	endpoint := cfg.BaseURL + "/v8/finance/chart/" + url.PathEscape(symbol) + "?range=1d&interval=1d"
	request, err := http.NewRequest(http.MethodGet, endpoint, nil)
	if err != nil {
		return Quote{}, yahooFailure{err: &Error{Kind: "invalidSymbol", Symbol: symbol, Message: err.Error()}}
	}
	request.Header.Set("User-Agent", cfg.UserAgent)
	request.Header.Set("Accept", "application/json")

	response, err := do(request)
	if err != nil {
		return Quote{}, yahooFailure{err: &Error{Kind: "network", Symbol: symbol, Message: err.Error()}, transport: true}
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		return Quote{}, yahooFailure{err: &Error{Kind: "network", Symbol: symbol, Message: err.Error()}, transport: true}
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return Quote{}, yahooFailure{err: &Error{Kind: "http", Symbol: symbol, Message: strconv.Itoa(response.StatusCode)}}
	}

	var document chartWire
	if err := json.Unmarshal(body, &document); err != nil {
		return Quote{}, yahooFailure{err: &Error{Kind: "decoding", Symbol: symbol, Message: err.Error()}}
	}
	if document.Chart == nil {
		return Quote{}, yahooFailure{err: &Error{Kind: "decoding", Symbol: symbol, Message: "response has no 'chart' section"}}
	}
	if chartError := document.Chart.Error; chartError != nil {
		message := chartError.Description
		if message == "" {
			message = chartError.Code
		}
		if message == "" {
			message = "unknown error"
		}
		return Quote{}, yahooFailure{err: &Error{Kind: "noData", Symbol: symbol, Message: message}}
	}
	if document.Chart.Result == nil || len(*document.Chart.Result) == 0 || (*document.Chart.Result)[0].Meta == nil {
		return Quote{}, yahooFailure{err: &Error{Kind: "noData", Symbol: symbol, Message: "no chart result in response"}}
	}
	meta := (*document.Chart.Result)[0].Meta
	if meta.Price == nil {
		return Quote{}, yahooFailure{err: &Error{Kind: "decoding", Symbol: symbol, Message: "chart meta has no regularMarketPrice"}}
	}
	// Preserve Yahoo's decimal lexeme: neither prices nor FX rates pass
	// through binary floating point before entering the decimal boundary.
	price, err := decimal.Parse(meta.Price.String())
	if err != nil {
		return Quote{}, yahooFailure{err: &Error{Kind: "decoding", Symbol: symbol, Message: "uninterpretable price: " + meta.Price.String()}}
	}
	currency := parseCurrency(meta.Currency)
	var asOf *time.Time
	if meta.AsOf != nil {
		stamp := time.Unix(int64(*meta.AsOf), 0).UTC()
		asOf = &stamp
	}
	return Quote{Symbol: symbol, Currency: currency, Price: price, AsOf: asOf, Source: "yahoo"}, yahooFailure{}
}
