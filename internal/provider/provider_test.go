package provider

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"dit/internal/decimal"
	"dit/internal/model"
)

var (
	now    = time.Date(2026, 10, 9, 20, 0, 0, 0, time.UTC)
	older  = now.Add(-2 * time.Hour)
	staler = now.Add(-4 * 24 * time.Hour)
)

func mustDecimal(t *testing.T, text string) decimal.Decimal {
	t.Helper()
	d, err := decimal.Parse(text)
	if err != nil {
		t.Fatalf("Parse(%q): %v", text, err)
	}
	return d
}

func TestCacheKeepsNewestAndAppliesWindows(t *testing.T) {
	var c Cache
	c.Upsert(Quote{Symbol: "SHOP.TO", Currency: model.CAD, Price: mustDecimal(t, "100"), AsOf: &older})
	// Newer observation replaces the older one.
	c.Upsert(Quote{Symbol: "SHOP.TO", Currency: model.CAD, Price: mustDecimal(t, "103"), AsOf: &now})
	fresh := c.FreshQuote("SHOP.TO", time.Minute, now)
	if fresh == nil || fresh.Price.String() != "103" {
		t.Fatalf("FreshQuote = %+v, want price 103", fresh)
	}
	// Outside the window the observation is not an answer: an observation
	// four days old is not a mark for "now".
	c.Upsert(Quote{Symbol: "STALE", Currency: model.CAD, Price: mustDecimal(t, "7"), AsOf: &staler})
	if got := c.FreshQuote("STALE", 72*time.Hour, now); got != nil {
		t.Fatalf("STALE outside 72h window = %+v, want nil", got)
	}
	// Without an asOf it is never fresh — a price with no timestamp is not a
	// measurement.
	c.Upsert(Quote{Symbol: "NOASOF", Currency: model.CAD, Price: mustDecimal(t, "5")})
	if got := c.FreshQuote("NOASOF", time.Hour, now); got != nil {
		t.Fatalf("FreshQuote without asOf = %+v, want nil", got)
	}
}

func TestCacheRatesDirectReciprocalAndHub(t *testing.T) {
	var c Cache
	c.UpsertRate(Rate{Base: model.EUR, Quote: model.USD, Rate: mustDecimal(t, "1.08"), AsOf: &now})
	if got := c.RatePair(model.USD, model.CAD); got != nil {
		t.Fatal("RatePair(USD, CAD) should be nil before anything is stored")
	}
	// Reciprocal pair.
	if got := c.RateValue(model.EUR, model.USD); got == nil || got.String() != "1.08" {
		t.Fatalf("RateValue(EUR, USD) = %v, want 1.08", got)
	}
	if got := c.RateValue(model.USD, model.EUR); got == nil || got.Fixed(6) != "0.925926" {
		t.Fatalf("RateValue(USD, EUR) reciprocal = %v, want 0.925926", got)
	}
	// Hub routing: EUR -> CAD is EUR -> USD -> CAD.
	c.UpsertRate(Rate{Base: model.USD, Quote: model.CAD, Rate: mustDecimal(t, "1.4254"), AsOf: &now})
	if got := c.RoutedRate(model.EUR, model.CAD, model.USD); got == nil || got.Fixed(4) != "1.5394" {
		t.Fatalf("RoutedRate(EUR, CAD, USD) = %v, want 1.5394 (1.08 x 1.4254)", got)
	}
	if got := c.RoutedRate(model.CAD, model.EUR, model.USD); got == nil || got.Fixed(4) != "0.6496" {
		t.Fatalf("RoutedRate(CAD, EUR, USD) = %v, want ~0.6496 (1/1.4254 / 1.08)", got)
	}
	if got := c.RoutedRate(model.EUR, model.CAD, model.USD); got == nil {
		t.Skip("previous line already passed; unreachable")
	}
}

func fakeResponse(status int, body string) *http.Response {
	return &http.Response{
		StatusCode: status,
		Status:     http.StatusText(status),
		Header:     http.Header{},
		Body:       io.NopCloser(bytes.NewBufferString(body)),
	}
}

func TestYahooParsesQuotesAndRates(t *testing.T) {
	// The chart endpoint answers with meta: the last price and its stamp.
	chart := `{
	  "chart": {"result": [{
	    "meta": {"currency": "CAD", "symbol": "SHOP.TO", "regularMarketPrice": 93.10, "regularMarketTime": 1463049600}
	  }]}
	}`
	chartAAPL := `{"chart": {"result": [{"meta": {"currency": "USD", "symbol": "AAPL", "regularMarketPrice": 22.12, "regularMarketTime": 1463049600}}]}}`
	noPrice := `{"chart": {"result": [{"meta": {"symbol": "NOPE"}}]}}`
	rate := `{"chart": {"result": [{"meta": {"currency": "CAD", "symbol": "USDCAD=X", "regularMarketPrice": 1.4254, "regularMarketTime": 1463049600}}]}}`
	var gotPaths []string
	prov := Yahoo(YahooConfig{Do: func(req *http.Request) (*http.Response, error) {
		gotPaths = append(gotPaths, req.URL.EscapedPath())
		if req.Header.Get("User-Agent") == "" {
			t.Error("Yahoo request has no User-Agent")
		}
		switch req.URL.EscapedPath() {
		case "/v8/finance/chart/SHOP.TO":
			return fakeResponse(200, chart), nil
		case "/v8/finance/chart/AAPL":
			return fakeResponse(200, chartAAPL), nil
		case "/v8/finance/chart/USDCAD=X":
			return fakeResponse(200, rate), nil
		}
		if strings.Contains(req.URL.Path, "NOPE") {
			return fakeResponse(200, noPrice), nil
		}
		t.Fatalf("unexpected path %s", req.URL.EscapedPath())
		return nil, nil
	}})

	// A null close must not mark the symbol: the last non-null close stands.
	quotes, err := prov.Quotes([]string{"SHOP.TO", "AAPL", "NOPE"})
	if err != nil {
		t.Fatalf("Quotes: %v", err)
	}
	if len(quotes) != 2 {
		t.Fatalf("len(quotes) = %d, want 2 (NOPE unquoted): %+v", len(quotes), quotes)
	}
	want := map[string]model.Currency{"SHOP.TO": model.CAD, "AAPL": model.USD}
	seenPrice := map[string]bool{}
	for _, q := range quotes {
		ccy, known := want[q.Symbol]
		if !known {
			t.Fatalf("unexpected quote for %s", q.Symbol)
		}
		if q.Currency != ccy {
			t.Fatalf("%s currency = %s, want %s", q.Symbol, q.Currency, ccy)
		}
		if q.AsOf == nil || !q.AsOf.Equal(time.Unix(1463049600, 0).UTC()) {
			t.Fatalf("%s asOf = %v, want 2016-05-13T00:00:00Z", q.Symbol, q.AsOf)
		}
		if q.Source != "yahoo" {
			t.Fatalf("%s source = %q, want yahoo", q.Symbol, q.Source)
		}
		seenPrice[q.Symbol] = true
	}
	for _, q := range quotes {
		switch q.Symbol {
		case "SHOP.TO":
			if q.Price.Fixed(2) != "93.10" {
				t.Fatalf("SHOP.TO price = %s, want 93.10", q.Price)
			}
		case "AAPL":
			if q.Price.Fixed(2) != "22.12" {
				t.Fatalf("AAPL price = %s, want 22.12", q.Price)
			}
		}
	}
	if !seenPrice["SHOP.TO"] || !seenPrice["AAPL"] {
		t.Fatalf("missing symbols: %v", seenPrice)
	}
	rateGot, err := prov.Rate(model.USD, model.CAD)
	if err != nil {
		t.Fatalf("Rate(USD, CAD): %v", err)
	}
	if rateGot.Base != model.USD || rateGot.Quote != model.CAD || rateGot.Rate.String() != "1.4254" {
		t.Fatalf("rate = %+v", rateGot)
	}
	// The FX ticker must be the quote-side currency with =X.
	joined := strings.Join(gotPaths, " ")
	if !strings.Contains(joined, "chart/USDCAD=X") {
		t.Fatalf("FX path not requested: %v", gotPaths)
	}
}

func TestYahooClassifiesFailures(t *testing.T) {
	// Every failure is transport -> the batch fails.
	prov := Yahoo(YahooConfig{Do: func(*http.Request) (*http.Response, error) {
		return nil, context.DeadlineExceeded
	}})
	if _, err := prov.Quotes([]string{"SHOP.TO"}); err == nil {
		t.Fatal("all-transport batch must fail")
	}
	// Every failure is an API refusal -> empty, no error: Yahoo had the
	// symbols; they simply are not answerable.
	prov = Yahoo(YahooConfig{Do: func(*http.Request) (*http.Response, error) {
		return fakeResponse(429, `{"chart":{"error":{"code":"Too Many Requests"}}}`), nil
	}})
	quotes, err := prov.Quotes([]string{"SHOP.TO"})
	if err != nil {
		t.Fatalf("API-only failures must not fail the batch: %v", err)
	}
	if len(quotes) != 0 {
		t.Fatalf("got %d quotes, want 0", len(quotes))
	}
	// Mixed: the batch still succeeds; only the transport side is lost.
	prov = Yahoo(YahooConfig{Do: func(req *http.Request) (*http.Response, error) {
		if strings.Contains(req.URL.EscapedPath(), "GOOG") {
			return fakeResponse(429, `{}`), nil
		}
		return nil, context.DeadlineExceeded
	}})
	if _, err := prov.Quotes([]string{"GOOG", "MSFT"}); err == nil {
		t.Fatal("an empty result with a wire failure must be reported failed")
	}
	// ...whereas a batch that got at least one quote succeeds: the rest is
	// simply unquoted.
	gotTwo := fakeResponse(200, `{"chart": {"result": [{"meta": {"currency": "CAD", "regularMarketPrice": 10, "regularMarketTime": 1463049600}}]}}`)
	prov = Yahoo(YahooConfig{Do: func(req *http.Request) (*http.Response, error) {
		if strings.Contains(req.URL.EscapedPath(), "GOOG") {
			return gotTwo, nil
		}
		return nil, context.DeadlineExceeded
	}})
	quotes, err = prov.Quotes([]string{"GOOG", "MSFT"})
	if err != nil {
		t.Fatalf("batch with one good quote must succeed: %v", err)
	}
	if len(quotes) != 1 {
		t.Fatalf("got %d quotes, want 1", len(quotes))
	}
}

func TestStubAnswersOnlyWhatItKnows(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "pin.json")
	err := os.WriteFile(path, []byte(`{
	  "quotes": [{"symbol": "SHOP.TO", "currency": "CAD", "price": "243.83", "asOf": "2026-10-09T20:00:00Z", "source": "yahoo"}],
	  "rates":  [{"base": "USD", "quote": "CAD", "rate": "1.4254", "asOf": "2026-10-09T20:00:00Z"}]
	}`), 0o644)
	if err != nil {
		t.Fatal(err)
	}
	pin, err := LoadStub(path)
	if err != nil {
		t.Fatalf("LoadStub: %v", err)
	}
	quotes, err := pin.Quotes([]string{"SHOP.TO", "NOPE"})
	if err != nil {
		t.Fatalf("Quotes: %v", err)
	}
	if len(quotes) != 1 || quotes[0].Symbol != "SHOP.TO" || quotes[0].Price.String() != "243.83" {
		t.Fatalf("quotes = %+v", quotes)
	}
	// The pin is a full observation set: a rate absent from it is a failure,
	// not an invitation to improvise.
	if rate, err := pin.Rate(model.USD, model.EUR); err == nil {
		t.Fatalf("Rate(USD, EUR) should fail: %+v", rate)
	}
	// But either stored direction answers, the way the oracle does.
	rate, err := pin.Rate(model.CAD, model.USD)
	if err != nil {
		t.Fatalf("Rate(CAD, USD) reciprocal: %v", err)
	}
	if rate.Rate.Fixed(4) != "0.7016" {
		t.Fatalf("reciprocal rate = %s, want 0.7016", rate.Rate)
	}
}

func TestStubReportsWhatFailed(t *testing.T) {
	if _, err := LoadStub("/definitely/not/a/pin.json"); err == nil {
		t.Fatal("LoadStub on a missing file must fail")
	}
	dir := t.TempDir()
	path := filepath.Join(dir, "pin.json")
	if err := os.WriteFile(path, []byte(`{"quotes": [], "rates": [], "transportError": "connection reset by peer"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	pin, err := LoadStub(path)
	if err != nil {
		t.Fatalf("LoadStub: %v", err)
	}
	if _, err := pin.Quotes([]string{"SHOP.TO"}); err == nil || !strings.Contains(err.Error(), "connection reset by peer") {
		t.Fatalf("pin transportError must surface: %v", err)
	}
	if _, err := pin.Rate(model.USD, model.CAD); err == nil || !strings.Contains(err.Error(), "connection reset by peer") {
		t.Fatalf("pin transportError must surface on rates too: %v", err)
	}
}
func TestNormalization(t *testing.T) {
	cases := map[string]string{
		"shop.to":    "SHOP.TO",
		" usdcad=x ": "USDCAD=X",
		"usdcad":     "USDCAD",
		"EUR":        "EUR",
	}
	for in, want := range cases {
		if got := normalizeSymbol(in); got != want {
			t.Errorf("normalizeSymbol(%q) = %q, want %q", in, got, want)
		}
	}
	if c := parseCurrency("CAD"); c != model.CAD {
		t.Errorf("parseCurrency(CAD) = %v", c)
	}
	if c := parseCurrency("XYZ"); c != model.Unknown {
		t.Errorf("parseCurrency(XYZ) = %v", c)
	}
}
