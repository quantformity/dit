package cli

import (
	"bytes"
	"dit/internal/config"
	"dit/internal/decimal"
	"dit/internal/model"
	"dit/internal/provider"
	"dit/internal/store"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeContext(t *testing.T) Context {
	t.Helper()
	root := t.TempDir()
	c := Context{Layout: config.Layout{Backend: config.File, PortfolioDir: filepath.Join(root, "store"), MarketDir: filepath.Join(root, "market")}, Display: model.CAD, Out: &bytes.Buffer{}, Err: &bytes.Buffer{}}
	for _, section := range []string{"store", "market"} {
		if e := os.MkdirAll(filepath.Join(root, section), 0755); e != nil {
			t.Fatal(e)
		}
		raw, e := os.ReadFile(filepath.Join("..", "..", "testdata", "fixtures", "richstore", section, sectionKey(section)+".dat"))
		if e != nil {
			t.Fatal(e)
		}
		if e = os.WriteFile(filepath.Join(root, section, sectionKey(section)+".dat"), raw, 0644); e != nil {
			t.Fatal(e)
		}
	}
	return c
}
func sectionKey(s string) string {
	if s == "store" {
		return "portfolio"
	}
	return "market"
}
func snapshotFiles(t *testing.T, c Context) map[string][]byte {
	t.Helper()
	result := map[string][]byte{}
	for _, dir := range []string{c.Layout.PortfolioDir, c.Layout.MarketDir} {
		e := filepath.WalkDir(dir, func(p string, d os.DirEntry, e error) error {
			if e != nil {
				return e
			}
			if !d.IsDir() {
				b, e := os.ReadFile(p)
				if e != nil {
					return e
				}
				result[p] = b
			}
			return nil
		})
		if e != nil {
			t.Fatal(e)
		}
	}
	return result
}
func assertUnchanged(t *testing.T, c Context, before map[string][]byte) {
	t.Helper()
	after := snapshotFiles(t, c)
	if len(after) != len(before) {
		t.Fatal("store file count changed")
	}
	for p, b := range before {
		if !bytes.Equal(b, after[p]) {
			t.Fatalf("error mutated %s", p)
		}
	}
}
func TestMarketWriteErrorsLeaveBothStoresByteIdentical(t *testing.T) {
	cases := []struct {
		name string
		run  Command
		args []string
	}{
		{"latest transport", MarketLatest, nil}, {"history transport", MarketHistory, nil}, {"rebuild transport", MarketHistory, []string{"--rebuild"}}, {"update transport", Update, nil}, {"invalid import", MarketImport, []string{"INVALID"}}, {"self backfill", MarketBackfill, []string{"SHOP.TO", "--from", "SHOP.TO"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c := writeContext(t)
			pin := writePin(t, `{"transportError":"pinned outage"}`)
			t.Setenv("DIT_PROVIDER_STUB", pin)
			args := tc.args
			if tc.name == "invalid import" {
				path := filepath.Join(t.TempDir(), "bad.csv")
				os.WriteFile(path, []byte("X,2024-01-01,0\n"), 0644)
				args = []string{path}
			}
			before := snapshotFiles(t, c)
			if e := tc.run(c, args); e == nil {
				t.Fatal("expected error")
			}
			assertUnchanged(t, c, before)
		})
	}
}
func TestUpdateHistoryFailureDoesNotPersistLatest(t *testing.T) {
	c := writeContext(t)
	before := snapshotFiles(t, c)
	t.Setenv("DIT_PROVIDER_STUB", writePin(t, `{"quotes":[{"symbol":"SHOP.TO","currency":"CAD","price":"200"}],"rates":[{"base":"USD","quote":"CAD","rate":"1.4"}],"dailyError":"pinned daily outage"}`))
	if e := Update(c, []string{"--rebuild"}); e == nil {
		t.Fatal("expected failure after latest succeeded")
	}
	assertUnchanged(t, c, before)
}
func TestHistoryModesAndWatermark(t *testing.T) {
	for _, mode := range []string{"incremental", "all", "rebuild"} {
		t.Run(mode, func(t *testing.T) {
			c := writeContext(t)
			p, d, e := loadWriteMarket(c)
			if e != nil {
				t.Fatal(e)
			}
			today := model.DayFromUnix(fixtureNow.Unix())
			old := d.Series["SHOP.TO"]
			if old == nil {
				t.Fatal("fixture missing")
			}
			covered := today - 86400
			old.CoveredThrough = &covered
			calls := 0
			prov := provider.Provider{DailySeries: func(s string, from, to model.Day) (provider.DailySeries, error) {
				calls++
				if mode == "incremental" && s == "SHOP.TO" && from != today {
					t.Fatalf("tail start %s", from)
				}
				if mode != "incremental" && s == "SHOP.TO" && from >= today {
					t.Fatal("did not refill full holding window")
				}
				return provider.DailySeries{Currency: model.CAD, Points: []model.DailyPrice{{Day: today, Price: decimal.FromInt(100)}}}, nil
			}}
			count := len(old.Points)
			if e = historyStage(c, p, &d, prov, fixtureNow, mode == "all", mode == "rebuild"); e != nil {
				t.Fatal(e)
			}
			if calls == 0 {
				t.Fatal("no daily fetch")
			}
			if *d.Series["SHOP.TO"].CoveredThrough != today {
				t.Fatal("watermark not advanced")
			}
			if mode == "rebuild" && len(d.Series["SHOP.TO"].Points) != 1 {
				t.Fatal("rebuild did not erase")
			}
			if mode == "all" && len(d.Series["SHOP.TO"].Points) < count {
				t.Fatal("refill removed real points")
			}
			calls = 0
			if e = historyStage(c, p, &d, prov, fixtureNow, false, false); e != nil {
				t.Fatal(e)
			}
			if calls != 0 {
				t.Fatal("watermark failed to pace second run")
			}
		})
	}
}
func TestMarketLatestPersistsSnapshotSections(t *testing.T) {
	c := writeContext(t)
	t.Setenv("DIT_PROVIDER_STUB", writePin(t, `{"quotes":[{"symbol":"SHOP.TO","currency":"CAD","price":"123.45","asOf":"2026-10-09T20:00:00Z"}],"rates":[{"base":"USD","quote":"CAD","rate":"1.4"}]}`))
	before := snapshotFiles(t, c)
	if e := MarketLatest(c, nil); e != nil {
		t.Fatal(e)
	}
	p, d, e := loadWriteMarket(c)
	if e != nil || p == nil {
		t.Fatal(e)
	}
	if q := d.LatestQuoteFor("SHOP.TO"); q == nil || q.Price.String() != "123.45" {
		t.Fatal("quote not saved")
	}
	if len(d.LatestRates) == 0 {
		t.Fatal("rates not saved")
	}
	ledger := filepath.Join(c.Layout.PortfolioDir, "portfolio.dat")
	raw, _ := os.ReadFile(ledger)
	if !bytes.Equal(raw, before[ledger]) {
		t.Fatal("latest changed ledger")
	}
}
func TestMarketImportDerivedReplacementAndDryRun(t *testing.T) {
	c := writeContext(t)
	_, d, e := loadWriteMarket(c)
	if e != nil {
		t.Fatal(e)
	}
	day, _ := model.ParseDay("2024-06-17")
	d.Series["PROXY"] = &model.PriceSeries{Symbol: "PROXY", Currency: model.CAD, Points: []model.DailyPrice{{Day: day, Price: decimal.FromInt(1), Via: "derived via X"}}}
	if e = saveWriteMarket(c, d); e != nil {
		t.Fatal(e)
	}
	path := filepath.Join(t.TempDir(), "input.csv")
	os.WriteFile(path, []byte("PROXY,2024-06-17,2\nPROXY,2024-06-17,3\nX,2024-01-01,4,observed\n"), 0644)
	before := snapshotFiles(t, c)
	if e = MarketImport(c, []string{path, "--dry-run"}); e != nil {
		t.Fatal(e)
	}
	assertUnchanged(t, c, before)
	if e = MarketImport(c, []string{path}); e != nil {
		t.Fatal(e)
	}
	_, d, e = loadWriteMarket(c)
	if e != nil {
		t.Fatal(e)
	}
	v := d.Series["PROXY"].Points[0]
	if v.Via != "" || v.Price.String() != "3" {
		t.Fatal("observations did not replace model")
	}
	if !strings.Contains(c.Out.(*bytes.Buffer).String(), "2 point(s) stored from 2 line(s)") {
		t.Fatal("Swift duplicate count lost")
	}
}
func TestBackfillCrossCurrencyLabelsAndPreservesReal(t *testing.T) {
	c := writeContext(t)
	c.Offline = true
	p, d, e := loadWriteMarket(c)
	if e != nil {
		t.Fatal(e)
	}
	start, _ := model.ParseDay("2024-06-17")
	end := start + 86400
	p.Tickers = append(p.Tickers, model.EquityTicker{Symbol: "PROXY", Currency: model.CAD}, model.EquityTicker{Symbol: "SOURCE", Currency: model.USD})
	p.Transactions = append(p.Transactions, model.Transaction{ID: "proxy-buy", AccountID: p.Accounts[0].ID, Date: start, Currency: model.CAD, Kind: model.Kind{Type: model.KindStockPurchase, Stock: &model.StockDetails{Ticker: "PROXY", Shares: decimal.FromInt(1), Price: decimal.FromInt(14)}}}, model.Transaction{ID: "proxy-sale", AccountID: p.Accounts[0].ID, Date: end, Currency: model.CAD, Kind: model.Kind{Type: model.KindStockSale, Stock: &model.StockDetails{Ticker: "PROXY", Shares: decimal.FromInt(1), Price: decimal.FromInt(28)}}})
	l, _, e := c.Stores()
	if e != nil {
		t.Fatal(e)
	}
	if e = store.SavePortfolio(l, p); e != nil {
		t.Fatal(e)
	}
	d.Series["SOURCE"] = &model.PriceSeries{Symbol: "SOURCE", Currency: model.USD, Points: []model.DailyPrice{{Day: start, Price: decimal.FromInt(100)}, {Day: end, Price: decimal.FromInt(200)}}}
	d.Series["USD/CAD"] = &model.PriceSeries{Symbol: "USD/CAD", Currency: model.CAD, Points: []model.DailyPrice{{Day: start, Price: decimal.MustParse("1.4")}}}
	d.Series["PROXY"] = &model.PriceSeries{Symbol: "PROXY", Currency: model.CAD, Points: []model.DailyPrice{{Day: start, Price: decimal.FromInt(14)}}}
	if e = saveWriteMarket(c, d); e != nil {
		t.Fatal(e)
	}
	before := snapshotFiles(t, c)
	args := []string{"PROXY", "--from", "SOURCE"}
	if e = MarketBackfill(c, append(args, "--dry-run")); e != nil {
		t.Fatal(e)
	}
	assertUnchanged(t, c, before)
	if e = MarketBackfill(c, args); e != nil {
		t.Fatal(e)
	}
	_, d, e = loadWriteMarket(c)
	if e != nil {
		t.Fatal(e)
	}
	points := d.Series["PROXY"].Points
	if len(points) != 2 || points[0].Via != "" || points[0].Price.String() != "14" || points[1].Via != "derived via SOURCE ÷ 10" || points[1].Price.String() != "28" {
		t.Fatalf("backfill %v", points)
	}
}

func TestPinnedUpdatePersistsLatestAndDailyOffline(t *testing.T) {
	c := writeContext(t)
	t.Setenv("DIT_PROVIDER_STUB", writePin(t, `{"quotes":[{"symbol":"SHOP.TO","currency":"CAD","price":"200"}],"rates":[{"base":"USD","quote":"CAD","rate":"1.4"}],"series":{"SHOP.TO":{"currency":"CAD","points":[{"day":"2024-06-17","price":"99"}]},"CAD=X":{"currency":"CAD","points":[{"day":"2024-06-17","price":"1.4"}]}}}`))
	if e := Update(c, []string{"--rebuild"}); e != nil {
		t.Fatal(e)
	}
	_, d, e := loadWriteMarket(c)
	if e != nil {
		t.Fatal(e)
	}
	if d.LatestQuoteFor("SHOP.TO") == nil || len(d.Series["SHOP.TO"].Points) != 1 || d.Series["SHOP.TO"].Points[0].Price.String() != "99" {
		t.Fatal("update phases did not persist")
	}
	out := c.Out.(*bytes.Buffer).String()
	if !strings.Contains(out, "Latest market data") || !strings.Contains(out, "Daily history") || !strings.Contains(out, "Market coverage") {
		t.Fatal("missing update phase output")
	}
}

func TestMissingPortfolioDoesNotFetchOrCreateStores(t *testing.T) {
	c := writeContext(t)
	os.Remove(filepath.Join(c.Layout.PortfolioDir, store.PortfolioKey+".dat"))
	before := snapshotFiles(t, c)
	t.Setenv("DIT_PROVIDER_STUB", writePin(t, `{"transportError":"must not fetch"}`))
	for _, run := range []Command{MarketLatest, MarketHistory, Update} {
		if e := run(c, nil); e != nil {
			t.Fatal(e)
		}
	}
	assertUnchanged(t, c, before)
}
