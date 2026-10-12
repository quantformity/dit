package provider

import (
	"dit/internal/model"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestYahooDailyUsesConfiguredTransportAndDecimalTokens(t *testing.T) {
	from, _ := model.ParseDay("2024-06-17")
	to := from + 86400
	calls := 0
	p := Yahoo(YahooConfig{Do: func(r *http.Request) (*http.Response, error) {
		calls++
		q := r.URL.Query()
		if q.Get("period1") != "1718582400" || q.Get("period2") != "1718755200" || q.Get("interval") != "1d" {
			t.Fatalf("daily request %s", r.URL)
		}
		if r.Header.Get("User-Agent") == "" {
			t.Fatal("missing UA")
		}
		body := `{"chart":{"result":[{"meta":{"currency":"CAD"},"timestamp":[1718582400,1718586000,1718668800,1718668801],"indicators":{"quote":[{"close":[1.1234567890123456789,2.1234567890123456789,null,-1]}]}}]}}`
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
	}})
	s, e := p.DailySeries("SHOP.TO", from, to)
	if e != nil {
		t.Fatal(e)
	}
	if calls != 1 || len(s.Points) != 1 || s.Currency != model.CAD {
		t.Fatalf("series %+v", s)
	}
	if s.Points[0].Price.String() != "2.1234567890123456789" {
		t.Fatal("price passed through a binary float")
	}
}
func writeDailyPin(t *testing.T) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "daily.json")
	if e := os.WriteFile(p, []byte(`{"series":{"SHOP.TO":{"currency":"CAD","points":[{"day":"2024-06-17","price":"2"},{"day":"2024-06-18","price":"3"}]}}}`), 0644); e != nil {
		t.Fatal(e)
	}
	return p
}
func TestStubDailyInclusiveRangeAndEmptyAnswer(t *testing.T) {
	p, e := LoadStub(writeDailyPin(t))
	if e != nil {
		t.Fatal(e)
	}
	d, _ := model.ParseDay("2024-06-17")
	s, e := p.DailySeries("SHOP.TO", d, d)
	if e != nil || len(s.Points) != 1 {
		t.Fatalf("series %+v error %v", s, e)
	}
	s, e = p.DailySeries("UNKNOWN", d, d)
	if e != nil || len(s.Points) != 0 {
		t.Fatal("unknown daily series must be empty, not transport failure")
	}
}
