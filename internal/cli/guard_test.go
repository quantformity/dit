package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"dit/internal/model"
	"dit/internal/store"
)

func seedPortfolio(t *testing.T, id string, ccy model.Currency) model.Portfolio {
	t.Helper()
	return model.Portfolio{
		Accounts: []model.Account{{ID: id, ReportingCurrency: ccy}},
	}
}

// Seed a portfolio, capture its bytes, then replace them to simulate a sync or
// second run landing underneath the command. The guard must refuse and must not
// itself modify the store (it only reads).
func TestChangedUnderYouRefusesAndDoesNotWrite(t *testing.T) {
	ctx, dir := writeImportContext(t)
	first := seedPortfolio(t, "aaaaaaaa-0000-4000-8000-000000000000", model.CAD)
	if err := transferSave(ctx, &first, nil); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, store.PortfolioKey+".dat")
	original, _ := os.ReadFile(path)

	intuder := seedPortfolio(t, "dddddddd-0000-4000-8000-000000000000", model.USD)
	if err := transferSave(ctx, &intuder, nil); err != nil {
		t.Fatal(err)
	}

	err := changedUnderYou(ctx, original, dir, store.PortfolioKey, "portfolio")
	if err == nil {
		t.Fatal("guard should refuse when the store changed underneath")
	}
	if !strings.Contains(err.Error(), "changed since this command read it") {
		t.Fatalf("unexpected message: %v", err)
	}
	after, _ := os.ReadFile(path)
	want, _ := json.Marshal(&intuder)
	if string(after) != string(want) {
		t.Fatal("guard modified the store; it must only detect")
	}
}

func TestChangedUnderYouPassesWhenUnchanged(t *testing.T) {
	ctx, dir := writeImportContext(t)
	first := seedPortfolio(t, "aaaaaaaa-0000-4000-8000-000000000000", model.CAD)
	if err := transferSave(ctx, &first, nil); err != nil {
		t.Fatal(err)
	}
	original, _ := os.ReadFile(filepath.Join(dir, store.PortfolioKey+".dat"))
	if err := changedUnderYou(ctx, original, dir, store.PortfolioKey, "portfolio"); err != nil {
		t.Fatalf("unchanged store must pass: %v", err)
	}
}

func TestChangedUnderYouOverrideEnv(t *testing.T) {
	ctx, dir := writeImportContext(t)
	t.Setenv("DIT_ALLOW_CONCURRENT", "1")
	// Even a changed store is allowed through when the user opts out of the guard.
	if err := changedUnderYou(ctx, []byte("old bytes"), dir, store.PortfolioKey, "portfolio"); err != nil {
		t.Fatalf("DIT_ALLOW_CONCURRENT should bypass the guard: %v", err)
	}
}
