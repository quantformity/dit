package cli

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestIncomeListsDividendsAndGICInterest(t *testing.T) {
	c := summaryCtx(t, true, false)
	out := &strings.Builder{}
	c.Out = out
	if err := incomeCommand(c, []string{"--year", "2024"}); err != nil {
		t.Fatalf("income: %v", err)
	}
	raw := out.String()
	for _, want := range []string{"SHOP.TO", "CAD 12.34", "gic-interest", "USD 210.75", "By currency"} {
		if !strings.Contains(raw, want) {
			t.Fatalf("income output missing %q:\n%s", want, raw)
		}
	}
	// Income is per-currency, never a single blended total.
	if strings.Contains(raw, "Total value") {
		t.Fatalf("income should not blend currencies:\n%s", raw)
	}
}

func TestIncomeAccountScope(t *testing.T) {
	c := summaryCtx(t, true, false)
	out := &strings.Builder{}
	c.Out = out
	if err := incomeCommand(c, []string{"--year", "2024", "--account", "TFSA"}); err != nil {
		t.Fatalf("income --account: %v", err)
	}
	raw := out.String()
	if !strings.Contains(raw, "SHOP.TO") {
		t.Fatalf("TFSA income should list the dividend:\n%s", raw)
	}
	if strings.Contains(raw, "gic-interest") {
		t.Fatalf("GIC interest belongs to Margin, not TFSA:\n%s", raw)
	}
}

func TestIncomeJSONSchema(t *testing.T) {
	c := summaryCtx(t, true, true)
	out := &strings.Builder{}
	c.Out = out
	if err := incomeCommand(c, []string{"--year", "2024"}); err != nil {
		t.Fatalf("income json: %v", err)
	}
	var doc struct {
		OK     bool `json:"ok"`
		Schema string
		Data   struct {
			Income []map[string]any  `json:"income"`
			Totals map[string]string `json:"totalsByCurrency"`
		} `json:"data"`
	}
	if err := json.Unmarshal([]byte(out.String()), &doc); err != nil {
		t.Fatalf("json: %v\n%s", err, out.String())
	}
	if doc.Schema != "income/1" || len(doc.Data.Income) != 2 {
		t.Fatalf("unexpected income document: %s", out.String())
	}
	if doc.Data.Totals["CAD"] != "12.34" || doc.Data.Totals["USD"] != "210.75" {
		t.Fatalf("unexpected totals: %+v", doc.Data.Totals)
	}
}

func TestIncomeRejectsUnknownFlag(t *testing.T) {
	c := summaryCtx(t, true, false)
	out := &strings.Builder{}
	c.Out = out
	if err := incomeCommand(c, []string{"--nope"}); err == nil {
		t.Fatal("unknown option should be a usage error")
	}
}

// An explicit --year must mean that year alone. Before this check the window ran
// from Jan 1 of that year all the way to today, so `--year 2024` would have
// reported 2025/2026 income under an "Income — 2024" heading.
func TestIncomeYearWindowIsThatYearOnly(t *testing.T) {
	now := time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)
	from, to, year, err := incomeWindow(now, map[string]string{"year": "2024"})
	if err != nil {
		t.Fatalf("incomeWindow: %v", err)
	}
	if from.String() != "2024-01-01" || to.String() != "2024-12-31" || year != 2024 {
		t.Fatalf("year window = %s..%s (year %d), want 2024-01-01..2024-12-31 (2024)", from, to, year)
	}
}

// A future year has no data yet, so its window clamps to today rather than
// running to a future Dec 31; the running year is year-to-date.
func TestIncomeWindowClampsFutureAndCurrentYear(t *testing.T) {
	now := time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)
	fFrom, fTo, _, err := incomeWindow(now, map[string]string{"year": "2030"})
	if err != nil {
		t.Fatalf("future year: %v", err)
	}
	if fFrom.String() != "2026-10-14" || fTo.String() != "2026-10-14" {
		t.Fatalf("future-year window = %s..%s, want an empty today-only window", fFrom, fTo)
	}
	cFrom, cTo, year, err := incomeWindow(now, map[string]string{})
	if err != nil {
		t.Fatalf("default window: %v", err)
	}
	if cFrom.String() != "2026-01-01" || cTo.String() != "2026-10-14" || year != 2026 {
		t.Fatalf("default window = %s..%s (year %d), want 2026-01-01..2026-10-14 (2026)", cFrom, cTo, year)
	}
}

// Explicit --since/--to still win, and an inverted window is a usage error
// rather than a silently empty or reversed report.
func TestIncomeWindowExplicitBounds(t *testing.T) {
	now := time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)
	from, to, _, err := incomeWindow(now, map[string]string{"since": "2025-03-05", "to": "2025-04-01"})
	if err != nil {
		t.Fatalf("explicit bounds: %v", err)
	}
	if from.String() != "2025-03-05" || to.String() != "2025-04-01" {
		t.Fatalf("explicit window = %s..%s", from, to)
	}
	if _, _, _, err := incomeWindow(now, map[string]string{"since": "2025-06-01", "to": "2025-01-01"}); err == nil {
		t.Fatal("inverted window should be a usage error")
	}
	if _, _, _, err := incomeWindow(now, map[string]string{"year": "2024"}); err != nil {
		t.Fatalf("plain year should not error: %v", err)
	}
}
