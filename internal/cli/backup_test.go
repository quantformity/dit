package cli

import (
	"bytes"
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

func TestBackupMetadataAndRollbackRoundTrip(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	root := filepath.Join(t.TempDir(), "store")
	name := "Backup test"
	accountID := "11111111-1111-4111-8111-111111111111"
	day, err := model.ParseDay("2026-10-13")
	if err != nil {
		t.Fatal(err)
	}
	portfolio := &model.Portfolio{
		Accounts: []model.Account{{ID: accountID, Name: &name, ReportingCurrency: model.CAD}},
		Transactions: []model.Transaction{{
			ID: "22222222-2222-4222-8222-222222222222", AccountID: accountID,
			Date: day, Currency: model.CAD,
			Kind: model.Kind{Type: model.KindDeposit, Amount: decimal.FromInt(100)},
		}},
	}
	market := store.EmptyMarket()
	var out, errOut bytes.Buffer
	ctx := Context{
		Layout: config.Layout{
			Backend: config.File, PortfolioDir: root, MarketDir: root,
			PortfolioLocation: filepath.Join(root, "portfolio.dat"), MarketLocation: filepath.Join(root, "market.dat"),
		},
		Version: "0.0.6", Out: &out, Err: &errOut,
	}
	if err := transferSave(ctx, portfolio, &market); err != nil {
		t.Fatal(err)
	}
	if err := portfolioBackup(ctx, nil); err != nil {
		t.Fatal(err)
	}
	pairs, directory, err := availableBackups()
	if err != nil || len(pairs) != 1 {
		t.Fatalf("backups = %+v, err %v", pairs, err)
	}
	pair := pairs[0]
	for path, prefix := range map[string]string{
		pair.portfolio: "portfolio.dat.", pair.market: "market.dat.", pair.metadata: "metadata.json.",
	} {
		if !strings.HasPrefix(filepath.Base(path), prefix+pair.stamp) {
			t.Fatalf("unexpected backup filename %q", path)
		}
	}
	metadataRaw, err := os.ReadFile(pair.metadata)
	if err != nil {
		t.Fatal(err)
	}
	var metadata map[string]any
	if err := json.Unmarshal(metadataRaw, &metadata); err != nil {
		t.Fatal(err)
	}
	if metadata["ditVersion"] != "0.0.6" || metadata["backupDate"] != pair.stamp || metadata["accountCount"] != float64(1) || metadata["transactionCount"] != float64(1) {
		t.Fatalf("incomplete backup metadata: %s", metadataRaw)
	}
	valuation, ok := metadata["valuation"].(map[string]any)
	if !ok || valuation["cash"] != "100.00" {
		t.Fatalf("metadata should include cost-basis cash balance: %s", metadataRaw)
	}
	if !strings.Contains(directory, filepath.Join(home, ".dit", "backup")) {
		t.Fatalf("backup directory = %q", directory)
	}

	portfolio.Transactions[0].Kind.Amount = decimal.FromInt(250)
	if err := transferSave(ctx, portfolio, &market); err != nil {
		t.Fatal(err)
	}
	if err := portfolioRollback(ctx, []string{pair.stamp, "--yes"}); err != nil {
		t.Fatalf("rollback failed: %v; stderr: %s", err, errOut.String())
	}
	restored, err := transferLedger(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if restored.Transactions[0].Kind.Amount.String() != "100" {
		t.Fatalf("rollback restored amount %s, want 100", restored.Transactions[0].Kind.Amount)
	}
	pairs, _, err = availableBackups()
	if err != nil || len(pairs) != 2 {
		t.Fatalf("rollback should also back up current state: backups %+v, err %v", pairs, err)
	}

	out.Reset()
	if err := portfolioRollback(ctx, []string{"--list"}); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), pair.stamp) || !strings.Contains(out.String(), "dit rollback "+pair.stamp) {
		t.Fatalf("backup list omitted the rollback command for %s: %s", pair.stamp, out.String())
	}
}

func TestRollbackRejectsInvalidTimestamp(t *testing.T) {
	ctx := Context{Out: &bytes.Buffer{}, Err: &bytes.Buffer{}}
	if err := portfolioRollback(ctx, []string{"yesterday"}); err == nil {
		t.Fatal("invalid timestamp was accepted")
	}
}
