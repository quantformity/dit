package valuation_test

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"dit/internal/cli"
	"dit/internal/decimal"
	"dit/internal/model"
	"dit/internal/valuation"
)

func fixture(t *testing.T) (*model.Portfolio, model.MarketData) {
	t.Helper()
	base := filepath.Join("..", "..", "testdata", "fixtures", "richstore")
	b, err := os.ReadFile(filepath.Join(base, "store", "portfolio.dat"))
	if err != nil {
		t.Fatal(err)
	}
	var p model.Portfolio
	if err = json.Unmarshal(b, &p); err != nil {
		t.Fatal(err)
	}
	b, err = os.ReadFile(filepath.Join(base, "market", "market.dat"))
	if err != nil {
		t.Fatal(err)
	}
	var m model.MarketData
	if err = json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	return &p, m
}
func day(s string) model.Day {
	d, err := model.ParseDay(s)
	if err != nil {
		panic(err)
	}
	return d
}
func expect(t *testing.T, d *decimal.Decimal, want string) {
	t.Helper()
	if d == nil {
		t.Fatalf("nil; want %s", want)
	}
	if got := d.Fixed(2); got != want {
		t.Fatalf("got %s; want %s", got, want)
	}
}

// These are the installed Swift binary's --offline figures, captured on the
// unmodified Swift-written fixture. No live price is a reproducible fixture.
func TestRichStoreSwiftOfflineFigures(t *testing.T) {
	p, m := fixture(t)
	before, _ := json.Marshal(p)
	marketBefore, _ := json.Marshal(m)
	s := valuation.CostSummary(p, model.CAD, day("2026-10-09"))
	if s.Total != nil || s.Cash != nil || s.GICValue != nil || s.Unrealized != nil || s.DayChange != nil {
		t.Fatal("unknown conversion/quote was invented")
	}
	expect(t, s.PositionValue, "530.69")
	expect(t, s.Realized, "66.15")
	expect(t, s.Dividends, "12.34")
	expect(t, decimalPtr(s.CashByCurrency[model.CAD]), "24692.76")
	expect(t, decimalPtr(s.CashByCurrency[model.USD]), "-789.25")
	expect(t, decimalPtr(s.ValueByCurrency()[model.CAD]), "25223.45")
	expect(t, decimalPtr(s.ValueByCurrency()[model.USD]), "4210.75")
	if len(s.Accounts) != 2 || valuation.Name(s.Accounts[0].Account) != "TFSA" {
		t.Fatal(s.Accounts)
	}
	expect(t, s.Accounts[0].Cash, "23334.96")
	expect(t, s.Accounts[0].Total, "23865.65")
	expect(t, s.Accounts[1].GICValue, "5000.00")
	h := s.Holdings[0]
	if h.Symbol != "SHOP.TO" || h.Shares.String() != "6" || h.Price != nil {
		t.Fatal(h)
	}
	expect(t, decimalPtr(h.AverageCost), "88.45")
	after, _ := json.Marshal(p)
	marketAfter, _ := json.Marshal(m)
	if string(before) != string(after) || string(marketBefore) != string(marketAfter) {
		t.Fatal("valuation changed source documents")
	}
}
func decimalPtr(d decimal.Decimal) *decimal.Decimal { return &d }

// Run the oracle in a private directory and compare the complete offline
// schema and report, not just a few hand-selected amounts. The timestamp is
// taken from the oracle itself, so clock ticks do not make this test flaky.
func TestRichStoreOracleOffline(t *testing.T) {
	const swift = "/opt/homebrew/bin/dit"
	if _, err := os.Stat(swift); err != nil {
		t.Skip("Swift oracle unavailable")
	}
	p, _ := fixture(t)
	w := t.TempDir()
	base := filepath.Join("..", "..", "testdata", "fixtures", "richstore")
	for _, part := range []string{"store", "market"} {
		if err := os.Mkdir(filepath.Join(w, part), 0700); err != nil {
			t.Fatal(err)
		}
		name := "portfolio.dat"
		if part == "market" {
			name = "market.dat"
		}
		b, err := os.ReadFile(filepath.Join(base, part, name))
		if err != nil {
			t.Fatal(err)
		}
		if err = os.WriteFile(filepath.Join(w, part, name), b, 0600); err != nil {
			t.Fatal(err)
		}
	}
	run := func(args ...string) []byte {
		cmd := exec.Command(swift, args...)
		cmd.Dir = w
		cmd.Env = append(os.Environ(), "DIT_BACKEND=file", "DIT_STORE_URL="+filepath.Join(w, "store"), "DIT_MARKET_URL="+filepath.Join(w, "market"))
		b, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("oracle: %s %v", b, err)
		}
		return b
	}
	b := run("summary", "--offline", "--json")
	var doc struct {
		Data struct {
			GeneratedAt string `json:"generatedAt"`
		} `json:"data"`
	}
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatal(err)
	}
	now, err := time.Parse(time.RFC3339, doc.Data.GeneratedAt)
	if err != nil {
		t.Fatal(err)
	}
	s := valuation.CostSummary(p, model.CAD, model.Day(model.DayStartUTC(now.Unix())))
	notes := []string{"offline mode: positions at cost basis, no FX conversion"}
	got := cli.SummaryJSON(s, now, filepath.Join(w, "store"), notes, true, true)
	// encoding/json's default HTML escaping is disabled by Context.WriteJSON.
	var output strings.Builder
	c := cli.Context{Out: &output}
	if err := c.WriteJSON(got); err != nil {
		t.Fatal(err)
	}
	if output.String() != string(b) {
		t.Fatalf("JSON mismatch\nSwift: %s\nGo: %s", b, output.String())
	}
	report := string(run("summary", "--offline"))
	// bold=false: this check captures output into a buffer, and the
	// reference only bolds headers on a terminal — a piped run is plain.
	rendered := cli.RenderSummary(s, now, notes, false) + "\n\nStore: " + filepath.Join(w, "store") + "\n"
	// Human report has a minute-resolution local clock; both invocations should
	// normally be in the same minute, but remove that volatile first line.
	if strings.SplitN(report, "\n", 2)[1] != strings.SplitN(rendered, "\n", 2)[1] {
		t.Fatalf("report mismatch\nSwift:\n%s\nGo:\n%s", report, rendered)
	}
}

func TestStoredPriceProvenanceAndPreviousClose(t *testing.T) {
	p, m := fixture(t)
	// The fixture's real series has unknown currency: the store cannot prove it
	// prices CAD shares. A price lookup is not itself a currency conversion.
	original := valuation.Compute(p, m, model.CAD, day("2024-05-02"))
	if original.Holdings[0].Price != nil {
		t.Fatal("unknown currency accepted as CAD")
	}
	series := *m.Series["SHOP.TO"]
	series.Currency = model.CAD
	series.Points = append([]model.DailyPrice(nil), series.Points...)
	series.Points[0].Via = "derived via proxy"
	m.Series["SHOP.TO"] = &series
	s := valuation.Compute(p, m, model.CAD, day("2024-05-05"))
	h := s.Holdings[0]
	if h.Price == nil || h.Price.Day != day("2024-05-02") || h.Basis != "observed" || !h.DayModel || h.Previous == nil {
		t.Fatal("price age or baseline provenance lost", h)
	}
	if h.DayChange == nil || h.Unrealized == nil || h.DayFraction == nil {
		t.Fatal("observed pair did not produce P&L")
	}
	// Removing the earlier observation must remove day change, not fabricate 0.
	series.Points = series.Points[1:]
	s = valuation.Compute(p, m, model.CAD, day("2024-05-05"))
	if s.Holdings[0].DayChange != nil || s.DayChange != nil {
		t.Fatal("missing baseline reported as zero")
	}
	series.Points[0].Via = "derived via proxy"
	s = valuation.Compute(p, m, model.CAD, day("2024-05-05"))
	if s.Holdings[0].Basis != "derived" || s.Holdings[0].Price.Via == "" {
		t.Fatal("derived price passed as observed")
	}
}

func TestFXHubRoutingAndMissingLeg(t *testing.T) {
	d := day("2024-05-02")
	m := model.MarketData{Series: map[string]*model.PriceSeries{
		"USD/CAD": {Points: []model.DailyPrice{{Day: d, Price: decimal.MustParse("1.4")}}},
		"USD/EUR": {Points: []model.DailyPrice{{Day: d, Price: decimal.MustParse("0.9")}}},
	}}
	rate := valuation.FXRate(m, model.CAD, model.EUR, d)
	if rate == nil || rate.Fixed(6) != "0.642857" {
		t.Fatal(rate)
	}
	m.Series["CAD/EUR"] = &model.PriceSeries{Points: []model.DailyPrice{{Day: d, Price: decimal.MustParse("0.7")}}}
	if r := valuation.FXRate(m, model.CAD, model.EUR, d); r == nil || r.String() != "0.7" {
		t.Fatal("direct pair did not win")
	}
	delete(m.Series, "CAD/EUR")
	delete(m.Series, "USD/EUR")
	if valuation.FXRate(m, model.CAD, model.EUR, d) != nil {
		t.Fatal("missing hub leg invented")
	}
	if valuation.FXRate(m, model.CAD, model.USD, d-86400) != nil {
		t.Fatal("future FX used")
	}
}
