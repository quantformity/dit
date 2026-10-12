package cli

import (
	"bytes"
	"io/fs"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"dit/internal/config"
	"dit/internal/decimal"
	"dit/internal/model"
)

func managementFixture(t *testing.T) (Context, string) {
	t.Helper()
	root := t.TempDir()
	c := Context{Layout: config.Layout{Backend: config.File, PortfolioDir: filepath.Join(root, "store"), MarketDir: filepath.Join(root, "market")}, Out: &bytes.Buffer{}, Err: &bytes.Buffer{}}
	name, other := "Main", "Other"
	opened, _ := model.ParseDay("2024-01-01")
	p := &model.Portfolio{Accounts: []model.Account{{ID: "11111111-1111-4111-8111-111111111111", Name: &name, ReportingCurrency: model.CAD, Taxable: true, OpenedDate: &opened}, {ID: "22222222-2222-4222-8222-222222222222", Name: &other, ReportingCurrency: model.USD, Taxable: true}}, Tickers: []model.EquityTicker{{Symbol: "ABC", Currency: model.CAD, Tags: []string{"core"}}}}
	p.Transactions = []model.Transaction{{ID: "33333333-3333-4333-8333-333333333333", AccountID: p.Accounts[0].ID, Date: opened, Currency: model.CAD, Kind: model.Kind{Type: model.KindStockPurchase, Stock: &model.StockDetails{Ticker: "ABC", Shares: decimal.FromInt(1500), Price: decimal.FromInt(2)}}}}
	if err := transferSave(c, p, nil); err != nil {
		t.Fatal(err)
	}
	return c, root
}
func managementSnapshot(t *testing.T, root string) map[string]string {
	t.Helper()
	result := map[string]string{}
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, path)
		result[rel] = string(data)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return result
}
func managementRun(c Context, name string, args []string) int {
	spec := acctmgktSpecs[name]
	_, err := spec.ParseFor(args)
	if err == nil {
		err = spec.Run(c, args)
	}
	if err != nil {
		return c.Report(err, spec.HelpText)
	}
	return 0
}
func TestManagementFailuresLeaveEveryStoreByteUnchanged(t *testing.T) {
	cases := []struct {
		name, args string
		code       int
	}{
		{"account add", "--currency XXX", 2}, {"account add", "--currency CAD --name Main", 1}, {"account add", "--currency CAD --taxable --non-taxable", 2},
		{"account edit", "Main --name Other", 1}, {"account edit", "Main", 1}, {"account edit", "Main --opened 2025-01-01 --closed 2024-01-01", 1}, {"account edit", "Main --opened 2024-02-30", 2},
		{"account close", "Main --force", 2}, {"account close", "Main --date 2023-01-01", 1}, {"account delete", "Main --yes", 2}, {"account show", "Missing", 1},
		{"ticker add", "ABC", 1}, {"ticker edit", "ABC --tags core", 1}, {"ticker edit", "ABC", 2}, {"ticker edit", "MISSING --name Missing", 1}, {"ticker delete", "MISSING --yes", 1}, {"ticker show", "MISSING", 1},
	}
	for _, tc := range cases {
		t.Run(tc.name+" "+tc.args, func(t *testing.T) {
			c, root := managementFixture(t)
			before := managementSnapshot(t, root)
			if got := managementRun(c, tc.name, strings.Fields(tc.args)); got != tc.code {
				t.Fatalf("exit %d, want %d; stderr %s", got, tc.code, c.Err)
			}
			if after := managementSnapshot(t, root); !reflect.DeepEqual(before, after) {
				t.Fatal("error path changed store bytes")
			}
		})
	}
}
func TestManagementReferenceAllowsClosingAndCurrencyEditWithPositions(t *testing.T) {
	c, _ := managementFixture(t)
	if got := managementRun(c, "account edit", []string{"Main", "--currency", "USD"}); got != 0 {
		t.Fatalf("currency edit exit %d", got)
	}
	if got := managementRun(c, "account close", []string{"Main", "--date", "2025-01-01"}); got != 0 {
		t.Fatalf("close exit %d", got)
	}
	p, err := transferLedger(c)
	if err != nil {
		t.Fatal(err)
	}
	if p.Accounts[0].ClosedDate == nil || p.Accounts[0].ReportingCurrency != model.USD || len(p.Transactions) != 1 {
		t.Fatal("metadata edit rewrote history or failed")
	}
}
func TestManagementTickerDeleteLeavesLedgerReferences(t *testing.T) {
	c, _ := managementFixture(t)
	if got := managementRun(c, "ticker delete", []string{"ABC", "--yes"}); got != 0 {
		t.Fatalf("exit %d", got)
	}
	p, err := transferLedger(c)
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Tickers) != 0 || len(p.Transactions) != 1 || p.Transactions[0].TickerSymbol() != "ABC" {
		t.Fatal("registry deletion changed transaction")
	}
}
func TestManagementAccountJSONQuantityIsUngrouped(t *testing.T) {
	c, _ := managementFixture(t)
	c.JSON = true
	if got := managementRun(c, "account show", []string{"Main"}); got != 0 {
		t.Fatalf("exit %d", got)
	}
	out := c.Out.(*bytes.Buffer).String()
	if !strings.Contains(out, `"shares":"1500"`) || strings.Contains(out, `"shares":"1,500"`) {
		t.Fatalf("wrong JSON quantity: %s", out)
	}
}
