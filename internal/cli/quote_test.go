package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"dit/internal/config"
	"dit/internal/decimal"
	"dit/internal/model"
	"dit/internal/provider"
)

func quoteTestContext(t *testing.T) (Context, *bytes.Buffer) {
	t.Helper()
	root := t.TempDir()
	out := new(bytes.Buffer)
	return Context{Layout: config.Layout{Backend: config.File, PortfolioDir: filepath.Join(root, "store"), MarketDir: filepath.Join(root, "market")}, Out: out, Err: new(bytes.Buffer)}, out
}
func quoteTestPin(t *testing.T, body string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "pin.json")
	if err := os.WriteFile(path, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DIT_PROVIDER_STUB", path)
}
func quoteTestMarket(t *testing.T, c Context) {
	t.Helper()
	if err := os.MkdirAll(c.Layout.MarketDir, 0700); err != nil {
		t.Fatal(err)
	}
	m := model.MarketData{Series: map[string]*model.PriceSeries{
		"SHOP.TO": {Symbol: "SHOP.TO", Currency: model.CAD, Points: []model.DailyPrice{{Day: model.Day(1718582400), Price: decimal.MustParse("96.4")}, {Day: model.Day(1718668800), Price: decimal.MustParse("94.2"), Via: "derived via SHOP"}}},
		"USD/CAD": {Symbol: "USD/CAD", Currency: model.CAD, Points: []model.DailyPrice{{Day: model.Day(1718582400), Price: decimal.MustParse("1.3578")}}},
		"USD/HKD": {Symbol: "USD/HKD", Currency: model.HKD, Points: []model.DailyPrice{{Day: model.Day(1718582400), Price: decimal.MustParse("7.8")}}},
	}}
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(filepath.Join(c.Layout.MarketDir, "market.dat"), b, 0600); err != nil {
		t.Fatal(err)
	}
}
func quoteSnapshot(t *testing.T, root string) map[string]string {
	t.Helper()
	files := map[string]string{}
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, path)
		if info.IsDir() {
			files[rel] = "directory"
		} else {
			b, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			files[rel] = string(b)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return files
}
func TestQuoteLivePinnedJSON(t *testing.T) {
	quoteTestPin(t, `{"quotes":[{"symbol":"SHOP.TO","currency":"CAD","price":"1234.125","asOf":"2024-06-17T20:00:00Z"}],"rates":[{"base":"USD","quote":"CAD","rate":"1.35781234"}]}`)
	c, out := quoteTestContext(t)
	c.JSON = true
	if err := QuoteLookup(c, []string{"shop.to", "tob", "usd/cad", "shop.to"}); err != nil {
		t.Fatal(err)
	}
	want := `{"data":{"mode":"live","quotes":[{"asOf":"2024-06-17T20:00:00Z","basis":"live","ccy":"CAD","price":"1234.12","source":"pin","symbol":"SHOP.TO"},{"asOf":null,"basis":"none","ccy":null,"price":null,"source":null,"symbol":"TOB"},{"asOf":null,"basis":"live","ccy":"CAD","price":"1.357812","source":"pin","symbol":"USD/CAD"},{"asOf":"2024-06-17T20:00:00Z","basis":"live","ccy":"CAD","price":"1234.12","source":"pin","symbol":"SHOP.TO"}]},"ok":true,"schema":"quote/1"}` + "\n"
	if out.String() != want {
		t.Fatalf("got %s want %s", out.String(), want)
	}
}
func TestQuoteLiveTable(t *testing.T) {
	c, out := quoteTestContext(t)
	p := provider.Provider{Quotes: func(s []string) ([]provider.Quote, error) {
		return []provider.Quote{{Symbol: "SHOP.TO", Currency: model.CAD, Price: decimal.MustParse("96.4")}}, nil
	}}
	if err := quoteLive(c, []string{"SHOP.TO", "TOB"}, p); err != nil {
		t.Fatal(err)
	}
	want := "Live quotes:\n  ┌─────────┬────────┬─────┬─────────┬────────┐\n  │ Symbol  │  Price │ Ccy │    AsOf │ Source │\n  ├─────────┼────────┼─────┼─────────┼────────┤\n  │ SHOP.TO │   96.4 │ CAD │ unknown │      ? │\n  ├─────────┼────────┼─────┼─────────┼────────┤\n  │ TOB     │ (none) │     │         │        │\n  └─────────┴────────┴─────┴─────────┴────────┘\nno quote found: TOB\n"
	if out.String() != want {
		t.Fatalf("got:\n%s\nwant:\n%s", out.String(), want)
	}
}
func TestQuoteFailuresDoNotMutate(t *testing.T) {
	quoteTestPin(t, `{"quotes":[]}`)
	for _, args := range [][]string{nil, {"SHOP.TO"}, {"TOB", "--as-of", "2024-06-17"}, {"TOB", "--from", "2024-06-17"}, {"EUR/GBP/JPY", "--offline"}, {"SHOP.TO", "--as-of", "bad"}, {"USD/CAD/HKD", "SHOP.TO"}, {"USD/CAD/HKD", "--from", "2024-01-01"}, {"USD/CAD/CAD"}, {"SHOP.TO", "--as-of", "2024-01-01", "--to", "2024-01-02"}, {"SHOP.TO", "--from", "2024-01-02", "--to", "2024-01-01"}} {
		t.Run(strings.Join(args, " "), func(t *testing.T) {
			c, _ := quoteTestContext(t)
			quoteTestMarket(t, c)
			root := filepath.Dir(c.Layout.MarketDir)
			before := quoteSnapshot(t, root)
			if len(args) > 1 && args[1] == "--offline" {
				c.Offline = true
				args = args[:1]
			}
			err := QuoteLookup(c, args)
			if err == nil {
				t.Fatal("expected failure")
			}
			if after := quoteSnapshot(t, root); !reflect.DeepEqual(before, after) {
				t.Fatal("error mutated store")
			}
		})
	}
	c, _ := quoteTestContext(t)
	quoteTestPin(t, `{"transportError":"pinned outage"}`)
	if err := QuoteLookup(c, []string{"SHOP.TO"}); err == nil || err.Error() != "live quote fetch failed: network: pinned outage" {
		t.Fatal(err)
	}
	if _, err := os.Stat(c.Layout.MarketDir); !os.IsNotExist(err) {
		t.Fatal("error created market directory")
	}
}
func TestQuoteStoredProvenance(t *testing.T) {
	c, out := quoteTestContext(t)
	quoteTestMarket(t, c)
	c.Offline = true
	if err := QuoteLookup(c, []string{"shop.to", "tob", "--as-of", "2024-06-19"}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "2024-06-18 (1d earlier)") || !strings.Contains(out.String(), "backfilled — derived via SHOP") || !strings.Contains(out.String(), "no stored quote for: TOB") {
		t.Fatal(out.String())
	}
	c.JSON = true
	out.Reset()
	if err := QuoteLookup(c, []string{"SHOP.TO", "TOB", "--as-of", "2024-06-17"}); err != nil {
		t.Fatal(err)
	}
	var doc struct {
		Data struct{ Quotes []map[string]any }
	}
	if err := json.Unmarshal(out.Bytes(), &doc); err != nil {
		t.Fatal(err)
	}
	if doc.Data.Quotes[0]["basis"] != "observed" || doc.Data.Quotes[0]["price"] != "96.40" || doc.Data.Quotes[1]["basis"] != "none" {
		t.Fatal(out.String())
	}
	out.Reset()
	if err := QuoteLookup(c, []string{"SHOP.TO", "TOB", "--from", "2024-06-17", "--to", "2024-06-18"}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), `"count":2`) || !strings.Contains(out.String(), `"basis":"derived"`) {
		t.Fatal(out.String())
	}
}
func TestQuoteMatrix(t *testing.T) {
	c, out := quoteTestContext(t)
	quoteTestMarket(t, c)
	c.Offline = true
	c.JSON = true
	if err := QuoteLookup(c, []string{"USD/CAD/HKD/EUR", "--as-of", "2024-06-17"}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), `"count":6`) || !strings.Contains(out.String(), `"pairCount":12`) || !strings.Contains(out.String(), `"via":"triangulated via USD"`) || !strings.Contains(out.String(), `"rate":"5.744587"`) {
		t.Fatal(out.String())
	}
	if _, _, ok := quotePair("USD/USD"); ok {
		t.Fatal("identity pair must go through equity endpoint")
	}
}
func TestQuoteClock(t *testing.T) {
	old := time.Local
	time.Local = time.UTC
	defer func() { time.Local = old }()
	if got := quoteClock(time.Date(2024, 6, 17, 20, 0, 0, 0, time.UTC)); got != "Jun 17, 2024 at 8:00\u202fPM" {
		t.Fatal(got)
	}
}
