package cli

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"dit/internal/config"
	"dit/internal/model"
	"dit/internal/store"
)

// importFixtureContext builds a file-backend context over an isolated temp
// store seeded with two accounts, so an import has somewhere to land. Nothing
// here ever touches the real portfolio.
func importFixtureContext(t *testing.T) (Context, string) {
	t.Helper()
	dir := t.TempDir()
	cash := "Cash"
	brokerage := "Brokerage"
	p := &model.Portfolio{
		Accounts: []model.Account{
			{ID: "11111111-1111-4111-8111-111111111111", Name: &cash, ReportingCurrency: model.CAD},
			{ID: "22222222-2222-4222-8222-222222222222", Name: &brokerage, ReportingCurrency: model.USD},
		},
	}
	var out strings.Builder
	ctx := Context{
		Layout: config.Layout{
			Backend: config.File, PortfolioDir: dir, MarketDir: dir,
			PortfolioLocation: filepath.Join(dir, "portfolio.dat"), MarketLocation: filepath.Join(dir, "market.dat"),
		},
		Out: &out, Err: &out,
	}
	if err := transferSave(ctx, p, nil); err != nil {
		t.Fatal(err)
	}
	return ctx, dir
}

func writeCSV(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "import.csv")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func countTx(t *testing.T, ctx Context) int {
	t.Helper()
	p, err := ctx.Ledger()
	if err != nil {
		t.Fatal(err)
	}
	if p == nil {
		return 0
	}
	return len(p.Transactions)
}

func TestTxImportAddsRows(t *testing.T) {
	ctx, _ := importFixtureContext(t)
	csv := "date,account,type,ticker,currency,quantity,price,amount,fee,notes\n" +
		"2026-01-05,Cash,deposit,,,,,1000,,\n" +
		"2026-01-06,Brokerage,buy,AAPL,USD,10,150,,,\n" +
		"2026-02-01,Brokerage,dividend,AAPL,USD,,,5,,\n"
	file := writeCSV(t, csv)
	var out strings.Builder
	ctx.Out = &out
	if err := txImport(ctx, []string{file}); err != nil {
		t.Fatalf("import: %v\n%s", err, out.String())
	}
	if got := countTx(t, ctx); got != 3 {
		t.Fatalf("want 3 transactions, got %d\n%s", got, out.String())
	}
	if !strings.Contains(out.String(), "3 transaction(s) added") {
		t.Fatalf("unexpected report:\n%s", out.String())
	}
}

func TestTxImportDryRunWritesNothing(t *testing.T) {
	ctx, dir := importFixtureContext(t)
	path := filepath.Join(dir, store.PortfolioKey+".dat")
	before, _ := os.ReadFile(path)
	csv := "2026-01-05,Cash,deposit,,,,,1000,,\n2026-01-06,Brokerage,buy,AAPL,USD,10,150,,,\n"
	file := writeCSV(t, csv)
	var out strings.Builder
	ctx.Out = &out
	if err := txImport(ctx, []string{"--dry-run", file}); err != nil {
		t.Fatalf("dry-run: %v", err)
	}
	after, _ := os.ReadFile(path)
	if string(before) != string(after) {
		t.Fatal("dry-run modified the store")
	}
	if !strings.Contains(out.String(), "dry run — nothing written") {
		t.Fatalf("missing dry-run marker:\n%s", out.String())
	}
}

func TestTxImportIsIdempotent(t *testing.T) {
	ctx, _ := importFixtureContext(t)
	csv := "2026-01-05,Cash,deposit,,,,,1000,,\n2026-01-06,Brokerage,buy,AAPL,USD,10,150,,,\n"
	file := writeCSV(t, csv)
	var first strings.Builder
	ctx.Out = &first
	if err := txImport(ctx, []string{file}); err != nil {
		t.Fatal(err)
	}
	var second strings.Builder
	ctx.Out = &second
	if err := txImport(ctx, []string{file}); err != nil {
		t.Fatalf("second import: %v", err)
	}
	if got := countTx(t, ctx); got != 2 {
		t.Fatalf("re-import duplicated rows: %d transactions", got)
	}
	if !strings.Contains(second.String(), "nothing to add") {
		t.Fatalf("second run should report nothing to add:\n%s", second.String())
	}
}

// A single malformed row must abort the WHOLE import with nothing written.
func TestTxImportMalformedAbortsEverything(t *testing.T) {
	ctx, dir := importFixtureContext(t)
	path := filepath.Join(dir, store.PortfolioKey+".dat")
	before, _ := os.ReadFile(path)
	// First row fine, second row has a bad date.
	csv := "2026-01-05,Cash,deposit,,,,,1000,,\n2026-13-45,Cash,deposit,,,,,500,,\n"
	file := writeCSV(t, csv)
	var out strings.Builder
	ctx.Out = &out
	if err := txImport(ctx, []string{file}); err == nil {
		t.Fatal("expected an error for the malformed row")
	}
	after, _ := os.ReadFile(path)
	if string(before) != string(after) {
		t.Fatal("a failed import must not modify the store")
	}
}

// A row naming an account that does not exist aborts the import too.
func TestTxImportUnknownAccountAborts(t *testing.T) {
	ctx, _ := importFixtureContext(t)
	csv := "2026-01-05,Nonexistent,deposit,,,,,1000,,\n"
	file := writeCSV(t, csv)
	var out strings.Builder
	ctx.Out = &out
	if err := txImport(ctx, []string{file}); err == nil {
		t.Fatal("expected an error for an unknown account")
	}
}
