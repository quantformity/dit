package provider

import (
	"net/http"
	"testing"
	"time"
)

func TestYahooQuoteDecimalLexemeAndEpoch(t *testing.T) {
	p := Yahoo(YahooConfig{Do: func(*http.Request) (*http.Response, error) {
		return fakeResponse(200, `{"chart":{"result":[{"meta":{"currency":"CAD","regularMarketPrice":1234567890.123456789,"regularMarketTime":0}}]}}`), nil
	}})
	quotes, err := p.Quotes([]string{"SHOP.TO"})
	if err != nil || len(quotes) != 1 {
		t.Fatalf("%v %v", quotes, err)
	}
	if got := quotes[0].Price.String(); got != "1234567890.123456789" {
		t.Fatal(got)
	}
	if quotes[0].AsOf == nil || !quotes[0].AsOf.Equal(time.Unix(0, 0)) {
		t.Fatal("explicit zero must remain the Unix epoch")
	}
}
