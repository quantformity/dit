package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"dit/internal/config"
	"dit/internal/decimal"
	"dit/internal/model"
	"dit/internal/store"
)

func writeImportContext(t *testing.T) (Context, string) {
	t.Helper()
	dir := t.TempDir()
	var out strings.Builder
	ctx := Context{
		Layout: config.Layout{
			Backend: config.File, PortfolioDir: dir, MarketDir: dir,
			PortfolioLocation: filepath.Join(dir, "portfolio.dat"), MarketLocation: filepath.Join(dir, "market.dat"),
		},
		Out: &out, Err: &out,
	}
	return ctx, dir
}

// oneAccountExport builds a single-account export file in the exact format
// `dit store export` writes, so `storeImport` treats it as a real export.
func oneAccountExport(t *testing.T, accountID string) (string, []byte) {
	t.Helper()
	one := model.Portfolio{
		Accounts: []model.Account{{ID: accountID, ReportingCurrency: model.USD}},
		Transactions: []model.Transaction{{
			ID: "cccccccc-0000-4000-8000-000000000000", AccountID: accountID, Currency: model.USD,
			Kind: model.Kind{Type: model.KindDeposit, Amount: decimal.FromInt(5)},
		}},
	}
	blob, err := json.MarshalIndent(one, "", "  ")
	if err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(t.TempDir(), "one.dat")
	if err := os.WriteFile(file, blob, 0o600); err != nil {
		t.Fatal(err)
	}
	return file, blob
}

// A dry run must describe what it WOULD do and write nothing, leaving the
// stores byte-identical.
func TestStoreImportDryRunWritesNothing(t *testing.T) {
	ctx, dir := writeImportContext(t)
	current := model.Portfolio{
		Accounts: []model.Account{{ID: "aaaaaaaa-0000-4000-8000-000000000000", ReportingCurrency: model.CAD}},
	}
	if err := transferSave(ctx, &current, nil); err != nil {
		t.Fatal(err)
	}
	before, _ := os.ReadFile(filepath.Join(dir, store.PortfolioKey+".dat"))
	file, _ := oneAccountExport(t, "bbbbbbbb-0000-4000-8000-000000000000")

	var out strings.Builder
	ctx.Out = &out
	// --dry-run with --yes: even with confirmation pre-answered, nothing writes.
	if err := storeImport(ctx, []string{"--dry-run", "--yes", file}); err != nil {
		t.Fatalf("dry-run import: %v", err)
	}
	if !strings.Contains(out.String(), "dry run") {
		t.Fatalf("expected a dry-run report:\n%s", out.String())
	}
	after, _ := os.ReadFile(filepath.Join(dir, store.PortfolioKey+".dat"))
	if string(before) != string(after) {
		t.Fatal("dry-run import modified the portfolio")
	}
}

// With no change underneath, the guard is a no-op and the replace proceeds —
// this is the common case and must not regress into false refusals.
func TestStoreImportReplaceSucceedsWhenUnchanged(t *testing.T) {
	ctx, dir := writeImportContext(t)
	file, _ := oneAccountExport(t, "bbbbbbbb-0000-4000-8000-000000000000")
	var out strings.Builder
	ctx.Out = &out
	if err := storeImport(ctx, []string{"--yes", file}); err != nil {
		t.Fatalf("replace import on an empty store should succeed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, store.PortfolioKey+".dat")); err != nil {
		t.Fatalf("import should have written the portfolio: %v", err)
	}
}
