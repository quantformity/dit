package cli

import (
	"bytes"
	"dit/internal/config"
	"dit/internal/decimal"
	"dit/internal/model"
	"dit/internal/store"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Opt-in executable for the lane while the parent owns registry wiring:
// go test -c -o .build/txwrite-test ./internal/cli
// DIT_TXWRITE_BINARY=1 .build/txwrite-test tx deposit ...
// Normal tests never invoke the oracle or any live provider.
func TestMain(m *testing.M) {
	if os.Getenv("DIT_TXWRITE_BINARY") != "1" {
		os.Exit(m.Run())
	}
	args := os.Args[1:]
	var rest []string
	offline, jsonMode := false, false
	for _, a := range args {
		if a == "--offline" {
			offline = true
		} else if a == "--json" {
			jsonMode = true
		} else {
			rest = append(rest, a)
		}
	}
	layout, err := config.Resolve(nil, "", "", "")
	if err != nil {
		panic(err)
	}
	c := Context{Layout: layout, Out: os.Stdout, Err: os.Stderr, Display: model.CAD, Offline: offline, JSON: jsonMode}
	group, sub, tail := SplitCommandWords(rest)
	_, spec := txWriteSpecs.Lookup(group, sub)
	if spec == nil {
		os.Exit(Dispatch(c, rest))
	}
	if err := spec.Run(c, tail); err != nil {
		os.Exit(c.Report(err, spec.HelpText))
	}
	os.Exit(0)
}
func txTestContext(t *testing.T) (Context, *bytes.Buffer) {
	t.Helper()
	root := t.TempDir()
	layout, err := config.Resolve(map[string]string{}, "file", filepath.Join(root, "store"), filepath.Join(root, "market"))
	if err != nil {
		t.Fatal(err)
	}
	out := &bytes.Buffer{}
	c := Context{Layout: layout, Out: out, Err: out, Display: model.CAD, Offline: true}
	name := "TFSA"
	p := model.Portfolio{Accounts: []model.Account{{ID: "11111111-2222-4333-8444-555555555555", Name: &name, ReportingCurrency: model.CAD, Taxable: true}}}
	s, _, err := c.Stores()
	if err != nil {
		t.Fatal(err)
	}
	if err := store.SavePortfolio(s, &p); err != nil {
		t.Fatal(err)
	}
	return c, out
}
func snapshotTxFiles(t *testing.T, root string) map[string]string {
	t.Helper()
	files := map[string]string{}
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
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
	if err != nil {
		t.Fatal(err)
	}
	return files
}
func TestTxWriteFailuresDoNotChangeStoreBytes(t *testing.T) {
	c, _ := txTestContext(t)
	probes := []struct{ verb, args string }{
		{"deposit", "--account TFSA --amount 0"}, {"deposit", "--account TFSA --amount -1"}, {"deposit", "--account TFSA --amount x"}, {"deposit", "--account TFSA --amount 1 --fee -2"},
		{"deposit", "--account Missing --amount 1"}, {"deposit", "--account TFSA --amount 1 --date 2024-02-30"}, {"deposit", "--account TFSA --amount 1 --unknown x"},
		{"buy", "--account TFSA --ticker X --shares 0 --price 2"}, {"buy", "--account TFSA --ticker X --shares 1 --price -2"}, {"buy", "--account TFSA --ticker X --shares 1"},
		{"dividend", "--account TFSA --ticker X --amount -1"}, {"gic", "--account TFSA --product X --principal 100 --rate 1001 --maturity 2028-01-01"},
		{"gic-redeem", "--account TFSA --gic X --proceeds 1"}, {"fx", "--account TFSA --from CAD --to CAD --from-amount 1 --to-amount 1"},
		{"fx", "--account TFSA --from CAD --to USD --from-amount 0 --to-amount 1"}, {"edit", "DEADBEEF --amount 1"}, {"delete", "DEADBEEF --yes"},
	}
	for _, probe := range probes {
		t.Run(probe.verb+probe.args, func(t *testing.T) {
			before := snapshotTxFiles(t, c.Layout.PortfolioDir)
			if err := txWrite(c, probe.verb, strings.Fields(probe.args)); err == nil {
				t.Fatal("expected rejection")
			}
			after := snapshotTxFiles(t, c.Layout.PortfolioDir)
			if len(before) != len(after) {
				t.Fatal("file count changed")
			}
			for p, b := range before {
				if after[p] != b {
					t.Fatalf("error changed %s", p)
				}
			}
		})
	}
}
func TestTxSQLiteFailureLeavesDatabaseBytesUnchanged(t *testing.T) {
	root := t.TempDir()
	layout, err := config.Resolve(map[string]string{}, "sqlite", filepath.Join(root, "ledger.sqlite"), filepath.Join(root, "market.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	out := &bytes.Buffer{}
	c := Context{Layout: layout, Out: out, Err: out, Display: model.CAD, Offline: true}
	name := "TFSA"
	p := model.Portfolio{Accounts: []model.Account{{ID: "A", Name: &name, ReportingCurrency: model.CAD, Taxable: true}}}
	s, _, err := c.Stores()
	if err != nil {
		t.Fatal(err)
	}
	if err := store.SavePortfolio(s, &p); err != nil {
		t.Fatal(err)
	}
	if err := txWrite(c, "deposit", []string{"--account", "TFSA", "--amount", "10", "--date", "2024-01-01"}); err != nil {
		t.Fatal(err)
	}
	p2, err := c.Ledger()
	if err != nil {
		t.Fatal(err)
	}
	id := p2.Transactions[0].ID[:8]
	before := snapshotTxFiles(t, root)
	for _, probe := range []struct {
		verb string
		args []string
	}{
		{"deposit", []string{"--account", "TFSA", "--amount", "0"}},
		{"edit", []string{id, "--amount", "-1"}},
		{"edit", []string{id, "--amount", "10"}},
	} {
		if err := txWrite(c, probe.verb, probe.args); err == nil {
			t.Fatal("accepted failure")
		}
	}
	after := snapshotTxFiles(t, root)
	if len(before) != len(after) {
		t.Fatal("created files on failure")
	}
	for path, b := range before {
		if after[path] != b {
			t.Fatalf("database changed after failure: %s", path)
		}
	}
}

func TestTxLivePriceUsesPinnedProvider(t *testing.T) {
	c, out := txTestContext(t)
	c.Offline = false
	pin := filepath.Join(t.TempDir(), "pin.json")
	t.Setenv("DIT_PROVIDER_STUB", pin)
	for _, body := range []string{`{"quotes":[]}`, `{"transportError":"down"}`, `{"quotes":[{"symbol":"ABC","currency":"USD","price":"0"}]}`} {
		if err := os.WriteFile(pin, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
		before := snapshotTxFiles(t, c.Layout.PortfolioDir)
		if err := txWrite(c, "buy", []string{"--account", "TFSA", "--ticker", "ABC", "--shares", "1"}); err == nil {
			t.Fatal("untrustworthy price accepted")
		}
		after := snapshotTxFiles(t, c.Layout.PortfolioDir)
		for path, b := range before {
			if b != after[path] {
				t.Fatal("price failure wrote store")
			}
		}
	}
	body := `{"quotes":[{"symbol":"ABC","currency":"USD","price":"12.34","asOf":"2024-01-02T03:04:05Z","source":"pin"}]}`
	if err := os.WriteFile(pin, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	if err := txWrite(c, "buy", []string{"--account", "TFSA", "--ticker", "ABC", "--shares", "2", "--date", "2024-01-01"}); err != nil {
		t.Fatal(err)
	}
	stamp, _ := time.Parse(time.RFC3339, "2024-01-02T03:04:05Z")
	if !strings.Contains(out.String(), "price: 12.34 USD via pin as of "+summaryClock(stamp)) {
		t.Fatal(out.String())
	}
	p, _ := c.Ledger()
	if p.Transactions[0].Currency != model.USD {
		t.Fatal("quote currency not used")
	}
}

func TestTxWritesEditsAndDelete(t *testing.T) {
	c, out := txTestContext(t)
	for _, probe := range []struct{ verb, args string }{
		{"deposit", "--account TFSA --amount 1000 --date 2024-01-01"}, {"buy", "--account TFSA --ticker abc --shares 3 --price 10 --date 2024-02-01"},
		{"dividend", "--account TFSA --ticker ABC --amount 2 --date 2024-02-02"}, {"sell", "--account TFSA --ticker ABC --shares 4 --price 11 --date 2024-02-03"},
		{"fx", "--account TFSA --from CAD --to USD --from-amount 100 --to-amount 70 --date 2024-02-04"},
		{"gic", "--account TFSA --product Bond --principal 100 --rate 4.1 --maturity 2028-01-01"},
		{"gic-redeem", "--account TFSA --gic Bond --proceeds 110 --date 2029-01-01"},
	} {
		if err := txWrite(c, probe.verb, strings.Fields(probe.args)); err != nil {
			t.Fatal(err)
		}
	}
	if !strings.Contains(out.String(), "ends up SHORT 1 ABC") {
		t.Fatal(out.String())
	}
	p, err := c.Ledger()
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Transactions) != 7 || len(p.Tickers) != 1 {
		t.Fatal(p)
	}
	for _, tx := range p.Transactions {
		if len(tx.ID) != 36 || strings.Count(tx.ID, "-") != 4 {
			t.Fatal(tx.ID)
		}
	}
	ref := p.Transactions[0].ID[:8]
	if err := txWrite(c, "edit", []string{ref, "--amount", "1200"}); err != nil {
		t.Fatal(err)
	}
	p, _ = c.Ledger()
	if p.Transactions[0].Kind.Amount.Cmp(decimal.FromInt(1200)) != 0 {
		t.Fatal("not edited")
	}
	before := snapshotTxFiles(t, c.Layout.PortfolioDir)
	for _, args := range [][]string{{ref, "--shares", "1"}, {ref, "--amount", "0"}, {ref, "--amount", "1200"}, {ref, "--fee", "-1"}} {
		if err := txWrite(c, "edit", args); err == nil {
			t.Fatal("expected rejection")
		}
	}
	after := snapshotTxFiles(t, c.Layout.PortfolioDir)
	for path, b := range before {
		if b != after[path] {
			t.Fatal("failed edit wrote store")
		}
	}
	if err := txWrite(c, "delete", []string{ref, "--yes"}); err != nil {
		t.Fatal(err)
	}
	p, _ = c.Ledger()
	if len(p.Transactions) != 6 {
		t.Fatal("not deleted")
	}
}
