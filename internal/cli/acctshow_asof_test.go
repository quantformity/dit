package cli

import (
	"strings"
	"testing"

	"dit/internal/model"
)

// accountShow is reached directly with its own argument shape (account name +
// flags); the store is the read-only fixture, so nothing is written.
func TestAccountShowAsOfReplaysAndStaysOffline(t *testing.T) {
	c := summaryCtx(t, true, false)
	out := &strings.Builder{}
	c.Out = out
	if err := accountShow(c, []string{"TFSA", "--as-of", "2024-06-17"}); err != nil {
		t.Fatalf("account show --as-of: %v", err)
	}
	raw := out.String()
	for _, want := range []string{
		"Account summary — TFSA — 2024-06-17",
		"last stored close on or before this date",
		"SHOP.TO",
	} {
		if !strings.Contains(raw, want) {
			t.Fatalf("account as-of output missing %q:\n%s", want, raw)
		}
	}
}

// A display currency set explicitly (DisplaySet) overrides the account's own
// reporting currency; that is what DisplaySet exists to distinguish from the
// default that happens to equal the account currency.
func TestAccountShowHonoursExplicitDisplayOverride(t *testing.T) {
	c := summaryCtx(t, true, false)
	c.Display = model.USD
	c.DisplaySet = true
	out := &strings.Builder{}
	c.Out = out
	if err := accountShow(c, []string{"TFSA"}); err != nil {
		t.Fatalf("account show --display USD: %v", err)
	}
	raw := out.String()
	if !strings.Contains(raw, "display: USD") {
		t.Fatalf("expected the header to name USD as the display currency:\n%s", raw)
	}
}

// Without an explicit --display, account show keeps its default reporting
// currency (here CAD, which TFSA already uses), and DisplaySet stays false.
func TestAccountShowDefaultKeepsAccountCurrency(t *testing.T) {
	c := summaryCtx(t, true, false)
	c.Display = model.CAD
	c.DisplaySet = false
	out := &strings.Builder{}
	c.Out = out
	if err := accountShow(c, []string{"Margin"}); err != nil {
		t.Fatalf("account show Margin: %v", err)
	}
	// Margin reports in USD; with no override it must stay USD, not fall to
	// the global CAD default.
	if !strings.Contains(out.String(), "display: USD") {
		t.Fatalf("Margin should report in its own currency without an override:\n%s", out.String())
	}
}
