package cli

import (
	"bytes"
	"dit/internal/config"
	"dit/internal/model"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func pnlFixture(t *testing.T) Context {
	t.Helper()
	w := t.TempDir()
	for _, part := range []string{"store", "market"} {
		if e := os.Mkdir(filepath.Join(w, part), 0700); e != nil {
			t.Fatal(e)
		}
		name := "portfolio.dat"
		if part == "market" {
			name = "market.dat"
		}
		b, e := os.ReadFile(filepath.Join("..", "..", "testdata", "fixtures", "richstore", part, name))
		if e != nil {
			t.Fatal(e)
		}
		if e = os.WriteFile(filepath.Join(w, part, name), b, 0600); e != nil {
			t.Fatal(e)
		}
	}
	return Context{Layout: config.Layout{Backend: config.File, PortfolioDir: filepath.Join(w, "store"), MarketDir: filepath.Join(w, "market")}, Display: model.CAD, Out: &bytes.Buffer{}, Err: &bytes.Buffer{}}
}
func pnlSnapshot(t *testing.T, c Context) map[string]string {
	t.Helper()
	files := map[string]string{}
	for _, root := range []string{c.Layout.PortfolioDir, c.Layout.MarketDir} {
		e := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return err
			}
			if !info.IsDir() {
				b, e := os.ReadFile(path)
				if e != nil {
					return e
				}
				files[path] = string(b)
			}
			return nil
		})
		if e != nil {
			t.Fatal(e)
		}
	}
	return files
}
func TestPnLJSONGolden(t *testing.T) {
	c := pnlFixture(t)
	c.JSON = true
	c.Offline = true
	if e := pnlRun(c, []string{"--from", "2024-06-15", "--to", "2024-06-18"}, time.Now()); e != nil {
		t.Fatal(e)
	}
	want := `{"data":{"activityCount":1,"combined":{"at":"2024-06-18","currency":"CAD","rates":null,"value":"35.21"},"currencyTotals":[{"currency":"CAD","incompletePositions":0,"positionChange":"-18.60","realized":"53.81","total":"35.21"}],"notes":[],"positions":[{"accounts":["TFSA"],"basis":"observed","currency":"CAD","kind":"position","positionChange":"-18.60","realized":"53.81","symbol":"SHOP.TO","total":"35.21"}],"scope":{"accounts":"all","currencies":"all","perAccount":false,"reportingCurrency":"CAD","tickers":"all"},"window":{"end":"2024-06-18","fromLedgerStart":false,"label":"custom","start":"2024-06-15"}},"ok":true,"schema":"pnl/1"}` + "\n"
	if c.Out.(*bytes.Buffer).String() != want {
		t.Fatalf("%s", c.Out)
	}
}
func TestPnLFailureLeavesStoreBytesUnchanged(t *testing.T) {
	for _, tc := range []struct {
		args []string
		code int
	}{{[]string{"--daily"}, 2}, {[]string{"--horizon", "0d"}, 2}, {[]string{"--from", "2024-06-30", "--to", "2024-06-01"}, 2}, {[]string{"--from", "2024-06-01T00:00:00Z"}, 2}, {[]string{"--account", "MISSING"}, 1}, {[]string{"--account", ","}, 2}, {[]string{"--tickers", ","}, 2}, {[]string{"--ccy", ","}, 2}, {[]string{"--reporting-ccy", "BAD"}, 2}} {
		t.Run(strings.Join(tc.args, " "), func(t *testing.T) {
			c := pnlFixture(t)
			c.JSON = true
			before := pnlSnapshot(t, c)
			e := pnlRun(c, tc.args, time.Now())
			if e == nil {
				t.Fatal("success")
			}
			if got := c.Report(e, pnlHelp); got != tc.code {
				t.Fatalf("exit %d: %s", got, c.Out)
			}
			after := pnlSnapshot(t, c)
			if len(before) != len(after) {
				t.Fatal("file set changed")
			}
			for path, b := range before {
				if after[path] != b {
					t.Fatalf("mutated %s", path)
				}
			}
		})
	}
}
func TestPnLCorruptLedgerIsReadOnlyRuntimeFailure(t *testing.T) {
	c := pnlFixture(t)
	c.JSON = true
	path := filepath.Join(c.Layout.PortfolioDir, "portfolio.dat")
	if err := os.WriteFile(path, []byte("not JSON\n"), 0600); err != nil {
		t.Fatal(err)
	}
	before := pnlSnapshot(t, c)
	err := pnlRun(c, nil, time.Now())
	if err == nil || c.Report(err, pnlHelp) != 1 {
		t.Fatal("expected runtime failure", err)
	}
	after := pnlSnapshot(t, c)
	if len(before) != len(after) {
		t.Fatal("file set changed")
	}
	for path, content := range before {
		if after[path] != content {
			t.Fatal("mutated", path)
		}
	}
}

func TestPnLMissingStoreDoesNotCreateDirectories(t *testing.T) {
	w := t.TempDir()
	c := Context{Layout: config.Layout{Backend: config.File, PortfolioDir: filepath.Join(w, "store"), MarketDir: filepath.Join(w, "market")}, JSON: true, Out: &bytes.Buffer{}, Err: &bytes.Buffer{}}
	if e := pnlRun(c, nil, time.Now()); e != nil {
		t.Fatal(e)
	}
	if !strings.Contains(c.Out.(*bytes.Buffer).String(), `"empty":true`) {
		t.Fatal(c.Out)
	}
	for _, p := range []string{c.Layout.PortfolioDir, c.Layout.MarketDir} {
		if _, e := os.Stat(p); !os.IsNotExist(e) {
			t.Fatalf("created %s", p)
		}
	}
}
func TestPnLSeriesFlagFalseAndReadOnlySuccess(t *testing.T) {
	c := pnlFixture(t)
	before := pnlSnapshot(t, c)
	if e := pnlRun(c, []string{"--to", "2024-08-01", "--time-series=false", "--daily=false"}, time.Now()); e != nil {
		t.Fatal(e)
	}
	if strings.Contains(c.Out.(*bytes.Buffer).String(), "over time") {
		t.Fatal(c.Out)
	}
	after := pnlSnapshot(t, c)
	for p, b := range before {
		if after[p] != b {
			t.Fatal("mutated", p)
		}
	}
}
