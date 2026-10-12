package market_test

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"dit/internal/cli"
	"dit/internal/config"
	"dit/internal/decimal"
	"dit/internal/market"
	"dit/internal/model"
)

func day(s string) model.Day {
	d, err := model.ParseDay(s)
	if err != nil {
		panic(err)
	}
	return d
}
func TestLongestGap(t *testing.T) {
	from := day("2026-07-01")
	to := day("2026-08-31")
	for _, tc := range []struct {
		name   string
		points []string
		want   int
		start  string
	}{
		{"fully dark", nil, 62, "2026-07-01"},
		{"trailing staleness", []string{"2026-07-01"}, 0, ""},
		{"ten day hole", []string{"2026-07-01", "2026-07-12"}, 10, "2026-07-02"},
		{"holiday dust", []string{"2026-07-01", "2026-07-11"}, 0, ""},
		{"earliest tie", []string{"2026-07-01", "2026-07-12", "2026-07-23"}, 10, "2026-07-02"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			days := map[model.Day]bool{}
			for _, s := range tc.points {
				days[day(s)] = true
			}
			g := market.LongestGap(days, from, to)
			if tc.want == 0 {
				if g != nil {
					t.Fatalf("unexpected gap %+v", g)
				}
				return
			}
			if g == nil || g.Days != tc.want || g.From.String() != tc.start {
				t.Fatalf("gap %+v", g)
			}
		})
	}
	if market.LongestGap(nil, from, from+9*86400) != nil {
		t.Fatal("ten-day window is below inclusive reporting gate")
	}
}
func TestWatermarkIsNotObservation(t *testing.T) {
	watermark := day("2026-10-01")
	close := day("2026-06-30")
	s := &model.PriceSeries{Symbol: "STOP", Currency: model.USD, Points: []model.DailyPrice{{Day: close, Price: decimal.FromInt(10)}}, CoveredThrough: &watermark}
	observed, verified := market.Watermark(s)
	if *observed != close || *verified != watermark {
		t.Fatal("watermark collapsed onto observed date")
	}
	r := market.AuditSymbol("STOP", model.USD, nil, s, close, watermark)
	if r.Status() != "stale" || *r.StaleDays != 93 {
		t.Fatalf("watermark fabricated freshness: %+v", r)
	}
	wrong := market.AuditSymbol("STOP", model.CAD, nil, s, close, watermark)
	if wrong.Status() != "wrong-currency" || wrong.LongestGap != nil {
		t.Fatal("wrong-currency source was usable")
	}
}
func TestFXAllLegsMustBeFresh(t *testing.T) {
	data := model.MarketData{Series: map[string]*model.PriceSeries{
		"HKD/USD": {Points: []model.DailyPrice{{Day: day("2026-09-01"), Price: decimal.MustParse("0.128")}}},
		"USD/CAD": {Points: []model.DailyPrice{{Day: day("2026-10-01"), Price: decimal.MustParse("1.4")}}},
	}}
	r := market.AuditFX(data, model.HKD, model.CAD, day("2026-10-01"), []model.Day{day("2026-10-01")})
	if r.UsableNow || r.ChainLabel != "derived via USD (HKD→USD→CAD)" || r.BoundariesMissing != 1 || r.LastAsOf.String() != "2026-10-01" {
		t.Fatalf("stale leg falsely covered: %+v", r)
	}
}
func fixture(t *testing.T, name string) []byte {
	t.Helper()
	b, e := os.ReadFile(filepath.Join("..", "..", "testdata", "market", name))
	if e != nil {
		t.Fatal(e)
	}
	return b
}
func oracleContext(t *testing.T) (cli.Context, string) {
	t.Helper()
	root := t.TempDir()
	ledger, prices := filepath.Join(root, "store"), filepath.Join(root, "market")
	for _, entry := range []struct{ dir, file string }{{ledger, "portfolio.dat"}, {prices, "market.dat"}} {
		if e := os.MkdirAll(entry.dir, 0755); e != nil {
			t.Fatal(e)
		}
		if e := os.WriteFile(filepath.Join(entry.dir, entry.file), fixture(t, entry.file), 0644); e != nil {
			t.Fatal(e)
		}
	}
	return cli.Context{Layout: config.Layout{Backend: config.File, PortfolioDir: ledger, MarketDir: prices}, Display: model.CAD, Offline: true, Err: &bytes.Buffer{}}, prices
}
func TestSwiftOracleCommands(t *testing.T) {
	oldZone := time.Local
	time.Local = time.UTC
	t.Cleanup(func() { time.Local = oldZone })
	for _, tc := range []struct {
		name, file string
		run        cli.Command
		args       []string
		json       bool
	}{
		{"coverage text", "coverage.txt", cli.MarketCoverage, []string{"--to", "2026-10-01"}, false},
		{"coverage JSON", "coverage.json", cli.MarketCoverage, []string{"--to", "2026-10-01"}, true},
		{"show tail", "show.txt", cli.MarketShow, []string{"--symbol", "GAPPY", "--days", "3"}, false},
		{"show missing", "show-missing.txt", cli.MarketShow, []string{"--symbol", "GHOST"}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c, path := oracleContext(t)
			var out bytes.Buffer
			c.Out = &out
			c.JSON = tc.json
			if e := tc.run(c, tc.args); e != nil {
				t.Fatal(e)
			}
			got := strings.ReplaceAll(out.String(), path, "<MARKET>")
			want := string(fixture(t, tc.file))
			if got != want {
				t.Fatalf("stdout differs\ngot:\n%s\nwant:\n%s", got, want)
			}
			if tc.json {
				var doc any
				if e := json.Unmarshal(out.Bytes(), &doc); e != nil {
					t.Fatal(e)
				}
			}
			if b, e := os.ReadFile(filepath.Join(path, "market.dat")); e != nil || !bytes.Equal(b, fixture(t, "market.dat")) {
				t.Fatal("read command modified cache")
			}
		})
	}
}
func TestMoreSwiftOracleCommands(t *testing.T) {
	oldZone := time.Local
	time.Local = time.UTC
	t.Cleanup(func() { time.Local = oldZone })
	cases := []struct {
		name string
		args []string
	}{
		{"from", []string{"--from", "2026-08-01", "--to", "2026-10-01"}},
		{"empty", []string{"--to", "2026-03-01"}},
		{"filter", []string{"--tickers", "GAPPY", "--to", "2026-10-01"}},
		{"unmatched", []string{"--tickers", "ZZZ", "--to", "2026-10-01"}},
		{"usd", []string{"--reporting-ccy", "USD", "--to", "2026-10-01"}},
	}
	for _, tc := range cases {
		for _, machine := range []bool{false, true} {
			t.Run(tc.name+strconvBool(machine), func(t *testing.T) {
				c, path := oracleContext(t)
				var out bytes.Buffer
				c.Out = &out
				c.JSON = machine
				if e := cli.MarketCoverage(c, tc.args); e != nil {
					t.Fatal(e)
				}
				ext := "txt"
				if machine {
					ext = "json"
				}
				want := string(fixture(t, "coverage-"+tc.name+"."+ext))
				got := strings.ReplaceAll(out.String(), path, "<MARKET>")
				if got != want {
					t.Fatalf("got:\n%s\nwant:\n%s", got, want)
				}
			})
		}
	}
	c, path := oracleContext(t)
	if e := os.WriteFile(filepath.Join(path, "market.dat"), fixture(t, "derived-market.dat"), 0644); e != nil {
		t.Fatal(e)
	}
	var out bytes.Buffer
	c.Out = &out
	if e := cli.MarketShow(c, []string{"--symbol", "TSLA.NE", "--days", "9"}); e != nil {
		t.Fatal(e)
	}
	if got, want := strings.ReplaceAll(out.String(), path, "<MARKET>"), string(fixture(t, "show-derived.txt")); got != want {
		t.Fatalf("derived show got:\n%s\nwant:\n%s", got, want)
	}
}
func strconvBool(b bool) string {
	if b {
		return " JSON"
	}
	return " text"
}
func TestSQLiteReadOnly(t *testing.T) {
	c, _ := oracleContext(t)
	root := t.TempDir()
	c.Layout.Backend = config.SQLite
	c.Layout.PortfolioDir = filepath.Join(root, "portfolio.sqlite")
	c.Layout.MarketDir = filepath.Join(root, "market.sqlite")
	for _, entry := range []struct{ path, key, file string }{{c.Layout.PortfolioDir, "portfolio", "portfolio.dat"}, {c.Layout.MarketDir, "market", "market.dat"}} {
		db, e := sql.Open("sqlite", entry.path)
		if e != nil {
			t.Fatal(e)
		}
		_, e = db.Exec("CREATE TABLE store (key TEXT PRIMARY KEY, payload BLOB)")
		if e != nil {
			t.Fatal(e)
		}
		_, e = db.Exec("INSERT INTO store VALUES (?,?)", entry.key, fixture(t, entry.file))
		if e != nil {
			t.Fatal(e)
		}
		db.Close()
	}
	before, e := os.ReadFile(c.Layout.MarketDir)
	if e != nil {
		t.Fatal(e)
	}
	var out bytes.Buffer
	c.Out = &out
	c.JSON = true
	if e := cli.MarketCoverage(c, []string{"--to", "2026-10-01"}); e != nil {
		t.Fatal(e)
	}
	if out.String() != string(fixture(t, "coverage.json")) {
		t.Fatal("SQLite audit differs")
	}
	after, e := os.ReadFile(c.Layout.MarketDir)
	if e != nil || !bytes.Equal(before, after) {
		t.Fatal("read command changed SQLite store")
	}
	c.Layout.MarketDir = filepath.Join(root, "absent.sqlite")
	c.JSON = false
	if e := cli.MarketShow(c, nil); e != nil {
		t.Fatal(e)
	}
	if _, e := os.Stat(c.Layout.MarketDir); !os.IsNotExist(e) {
		t.Fatal("read command created SQLite store")
	}
}
func TestUsageAndStrictJSON(t *testing.T) {
	for _, tc := range []struct {
		run  cli.Command
		args []string
		text string
	}{
		{cli.MarketShow, []string{"XYZ"}, "filter both tables with --symbol"},
		{cli.MarketShow, []string{"--days", "0"}, "--days needs a positive number"},
		{cli.MarketCoverage, []string{"--wat"}, "unknown option"},
		{cli.MarketCoverage, []string{"--from", "2026-09-01", "--to", "2026-08-01"}, "before"},
		{cli.MarketCoverage, []string{"--to", "2026-10-01junk"}, "invalid date"},
		{cli.MarketCoverage, []string{"--tickers", ","}, "--tickers needs at least one symbol"},
	} {
		c, _ := oracleContext(t)
		c.Out = &bytes.Buffer{}
		e := tc.run(c, tc.args)
		if _, ok := e.(cli.UsageError); !ok || !strings.Contains(e.Error(), tc.text) {
			t.Fatalf("args %v: %v", tc.args, e)
		}
	}
	c, _ := oracleContext(t)
	c.JSON = true
	var out bytes.Buffer
	c.Out = &out
	e := cli.MarketCoverage(c, []string{"--strict", "--to", "2026-10-01"})
	if e == nil {
		t.Fatal("strict succeeded despite gaps")
	}
	if out.String() != string(fixture(t, "coverage.json")) || strings.Count(out.String(), "\n") != 1 {
		t.Fatal("strict changed the JSON stream")
	}
}
func TestCacheLeniencyDoesNotSpreadToLedger(t *testing.T) {
	c, path := oracleContext(t)
	var out bytes.Buffer
	c.Out = &out
	if e := os.WriteFile(filepath.Join(path, "market.dat"), []byte(`{"series":{},"latestQuotes":"broken"}`), 0644); e != nil {
		t.Fatal(e)
	}
	if e := cli.MarketShow(c, nil); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(filepath.Join(c.Layout.PortfolioDir, "portfolio.dat"), []byte(`{"accounts":{},"transactions":[]}`), 0644); e != nil {
		t.Fatal(e)
	}
	if e := cli.MarketCoverage(c, nil); e == nil {
		t.Fatal("malformed ledger was partially read")
	}
}
func TestEmptyAndOffline(t *testing.T) {
	var out bytes.Buffer
	root := t.TempDir()
	c := cli.Context{Layout: config.Layout{Backend: config.File, PortfolioDir: filepath.Join(root, "absent-store"), MarketDir: filepath.Join(root, "absent-market")}, Display: model.CAD, Offline: true, Out: &out, Err: &bytes.Buffer{}}
	if e := cli.MarketShow(c, nil); e != nil {
		t.Fatal(e)
	}
	if !strings.Contains(out.String(), "empty — run 'dit market latest'") {
		t.Fatal(out.String())
	}
	out.Reset()
	if e := cli.MarketCoverage(c, nil); e != nil {
		t.Fatal(e)
	}
	if !strings.Contains(out.String(), "Nothing to check") {
		t.Fatal(out.String())
	}
	if _, e := os.Stat(c.Layout.MarketDir); !os.IsNotExist(e) {
		t.Fatal("inspection created cache directory")
	}
	e := cli.MarketHistory(c, nil)
	if _, ok := e.(cli.UsageError); !ok || e.Error() != "'dit market history' fetches daily closes — --offline refuses the network" {
		t.Fatalf("offline refusal: %v", e)
	}
}
