package valuation_test

import (
	"dit/internal/decimal"
	"dit/internal/model"
	"dit/internal/valuation"
	"encoding/json"
	"strings"
	"testing"
)

func TestPnLBoundariesReuseReplay(t *testing.T) {
	p, m := fixture(t)
	m.Series["SHOP.TO"].Points = []model.DailyPrice{
		{Day: day("2024-06-14"), Price: decimal.MustParse("95.10")},
		{Day: day("2024-06-17"), Price: decimal.MustParse("96.40")},
		{Day: day("2024-06-18"), Price: decimal.MustParse("94.20")},
	}
	before, _ := json.Marshal(p)
	mbefore, _ := json.Marshal(m)
	w := valuation.Window{Start: day("2024-06-15"), End: day("2024-06-18"), Label: "custom"}
	r := valuation.ComputePnL(p, m, w, p.Accounts, false, nil, nil, model.CAD)
	if len(r.Rows) != 1 {
		t.Fatal(r)
	}
	expect(t, &r.Rows[0].Realized, "53.81")
	expect(t, r.Rows[0].Change, "-32.00")
	expect(t, r.Combined, "21.81")
	s := valuation.ComputePnLSeries(p, m, w, "daily", p.Accounts, false, nil, nil, model.CAD, r)
	if !s.Reconciles || s.CollapsedEmpty != 1 || len(s.Points) != 3 {
		t.Fatal(s)
	}
	after, _ := json.Marshal(p)
	mafter, _ := json.Marshal(m)
	if string(before) != string(after) || string(mbefore) != string(mafter) {
		t.Fatal("source mutated")
	}
	// No baseline: realized stays known, the entire total is withheld.
	r = valuation.ComputePnL(p, m, valuation.Window{Start: day("2024-06-01"), End: w.End}, p.Accounts, false, nil, nil, model.CAD)
	if r.Combined != nil || r.Rows[0].Change != nil || r.Totals[0].Incomplete != 1 {
		t.Fatal(r)
	}
	// Wrong denomination is not a usable price; unlabelled imports ARE usable.
	m.Series["SHOP.TO"].Currency = model.USD
	r = valuation.ComputePnL(p, m, w, p.Accounts, false, nil, nil, model.CAD)
	if r.Rows[0].Total != nil {
		t.Fatal(r)
	}
	m.Series["SHOP.TO"].Currency = model.Unknown
	m.Series["SHOP.TO"].Points[0].Via = "proxy"
	r = valuation.ComputePnL(p, m, w, p.Accounts, false, nil, nil, model.CAD)
	if !r.Rows[0].Derived {
		t.Fatal(r)
	}
	expect(t, r.Combined, "21.81")
}
func TestHistoricalFXHonesty(t *testing.T) {
	d := day("2024-06-18")
	m := model.MarketData{Series: map[string]*model.PriceSeries{}, LatestRates: []model.ExchangeRate{{Base: model.USD, Quote: model.JPY, Rate: decimal.FromInt(150)}}}
	put := func(s string, n string, at model.Day) {
		m.Series[s] = &model.PriceSeries{Symbol: s, Points: []model.DailyPrice{{Day: at, Price: decimal.MustParse(n)}}}
	}
	put("USD/CAD", "1.5", d)
	put("USD/HKD", "7.9", d-86400)
	q := valuation.HistoricalRate(m, model.HKD, model.CAD, d)
	if q == nil || q.Via != "derived via USD (HKD→USD→CAD)" || q.Stale != 1 || q.AsOf != d {
		t.Fatal(q)
	}
	if valuation.HistoricalRate(m, model.JPY, model.CAD, d) != nil {
		t.Fatal("invented missing USD leg from snapshot")
	}
	if valuation.HistoricalRate(m, model.USD, model.CAD, d+7*86400) == nil {
		t.Fatal("seventh day should remain usable")
	}
	if valuation.HistoricalRate(m, model.USD, model.CAD, d+8*86400) != nil {
		t.Fatal("too-old FX was used")
	}
	name := "a"
	a := model.Account{ID: "a", Name: &name, ReportingCurrency: model.CAD}
	p := &model.Portfolio{Accounts: []model.Account{a}}
	for _, cc := range []model.Currency{model.CAD, model.JPY, model.USD} {
		p.Transactions = append(p.Transactions, model.Transaction{AccountID: "a", Currency: cc, Date: d, Kind: model.Kind{Type: model.KindDividend, Dividend: &model.DividendDetails{Ticker: string(cc), Amount: decimal.FromInt(10)}}})
	}
	r := valuation.ComputePnL(p, m, valuation.Window{Start: d, End: d}, p.Accounts, false, nil, nil, model.CAD)
	if r.Combined != nil {
		t.Fatal("missing JPY conversion restored by later USD row", r.Combined)
	}
	if len(r.Rows) != 3 || !strings.Contains(strings.Join(r.Notes, " "), "JPY→CAD") {
		t.Fatal(r)
	}
}
func TestPnLWindowSelection(t *testing.T) {
	end := day("2024-03-31")
	h := "1m"
	w, e := valuation.ResolvePnLWindow(&h, nil, nil, end, nil)
	if e != nil || w.Start != day("2024-03-01") {
		t.Fatal(w, e)
	}
	h = "1y"
	end = day("2024-02-29")
	w, e = valuation.ResolvePnLWindow(&h, nil, nil, end, nil)
	if e != nil || w.Start != day("2023-03-01") {
		t.Fatal(w, e)
	}
	for _, bad := range []string{"0d", "1000d", "1mo", " 1d", "-1d"} {
		h = bad
		if _, e = valuation.ResolvePnLWindow(&h, nil, nil, end, nil); e == nil {
			t.Fatal(bad)
		}
	}
	for _, tc := range []struct {
		n int
		g string
	}{{10, "daily"}, {11, "weekly"}, {56, "weekly"}, {57, "monthly"}} {
		w = valuation.Window{Start: end - model.Day(tc.n-1)*86400, End: end}
		if valuation.PnLGranularity(w) != tc.g {
			t.Fatal(tc)
		}
		b := valuation.PnLBuckets(w, tc.g)
		if b[0].Start != w.Start || b[len(b)-1].End != w.End {
			t.Fatal(b)
		}
		for i := 1; i < len(b); i++ {
			if b[i].Start != b[i-1].End+86400 {
				t.Fatal("gap", b)
			}
		}
	}
}
func TestPnLGICAndRoundTripNeedNoMarket(t *testing.T) {
	a := model.Account{ID: "a", ReportingCurrency: model.USD}
	start, end := day("2024-06-01"), day("2024-06-18")
	fee := decimal.FromInt(2)
	tx := func(id string, at model.Day, k model.Kind) model.Transaction {
		return model.Transaction{ID: id, AccountID: "a", Currency: model.USD, Date: at, Fee: &fee, Kind: k}
	}
	p := &model.Portfolio{Accounts: []model.Account{a}, Transactions: []model.Transaction{
		tx("g", start, model.Kind{Type: model.KindGICPurchase, GIC: &model.GICDetails{Product: "Term", Principal: decimal.FromInt(100)}}),
		tx("r", end, model.Kind{Type: model.KindGICRedemption, Redemption: &model.GICRedemptionDetails{PurchaseID: "g", Proceeds: decimal.FromInt(112)}}),
		tx("skip", end, model.Kind{Type: model.KindGICRedemption, Redemption: &model.GICRedemptionDetails{PurchaseID: "missing", Proceeds: decimal.FromInt(500)}}),
		tx("buy", end, model.Kind{Type: model.KindStockPurchase, Stock: &model.StockDetails{Ticker: "ROUND", Shares: decimal.FromInt(10), Price: decimal.FromInt(10)}}),
		tx("sell", end, model.Kind{Type: model.KindStockSale, Stock: &model.StockDetails{Ticker: "ROUND", Shares: decimal.FromInt(10), Price: decimal.FromInt(12)}}),
	}}
	r := valuation.ComputePnL(p, model.MarketData{}, valuation.Window{Start: end, End: end}, p.Accounts, false, map[string]bool{"ROUND": true}, nil, model.USD)
	if len(r.Rows) != 2 || !r.Rows[0].Cash || r.Rows[0].Symbol != "GIC: Term" {
		t.Fatal(r)
	}
	expect(t, r.Rows[0].Total, "10.00")
	expect(t, r.Rows[1].Total, "16.00")
	expect(t, r.Combined, "26.00")
}
