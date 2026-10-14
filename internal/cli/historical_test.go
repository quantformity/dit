package cli

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// An as-of snapshot must replay to the date, price from stored history only,
// and never pretend a live quote existed.
func TestSummaryAsOfReplaysToTheDate(t *testing.T) {
	c := summaryCtx(t, true, false)
	out := &strings.Builder{}
	c.Out = out
	if err := summaryCommand(c, []string{"--as-of", "2024-06-17"}); err != nil {
		t.Fatalf("as-of: %v", err)
	}
	raw := out.String()
	for _, want := range []string{
		"Portfolio as of — 2024-06-17",
		"last stored close on or before this date",
		"By currency (native; not converted)",
		"SHOP.TO",
	} {
		if !strings.Contains(raw, want) {
			t.Fatalf("as-of output missing %q:\n%s", want, raw)
		}
	}
	// The report is bounded to the date: no today's-date banner creeps in.
	if strings.Contains(raw, "2026-10-") {
		t.Fatalf("as-of output leaked a today-dated line:\n%s", raw)
	}
}

func TestSummaryAsOfJSONCarriesProvenance(t *testing.T) {
	c := summaryCtx(t, true, true)
	out := &strings.Builder{}
	c.Out = out
	if err := summaryCommand(c, []string{"--as-of", "2024-06-17"}); err != nil {
		t.Fatalf("as-of json: %v", err)
	}
	var doc summaryDoc
	if err := json.Unmarshal([]byte(out.String()), &doc); err != nil {
		t.Fatalf("json: %v\n%s", err, out.String())
	}
	if doc.data()["asOf"] != "2024-06-17" || doc.data()["mode"] != "as-of" {
		t.Fatalf("as-of json missing asOf/mode: %s", out.String())
	}
}

func TestSummaryNetWorthSeriesIsBounded(t *testing.T) {
	c := summaryCtx(t, true, false)
	out := &strings.Builder{}
	c.Out = out
	if err := summaryCommand(c, []string{"--time-series", "--as-of-from", "2024-06-01", "--as-of-to", "2024-06-17"}); err != nil {
		t.Fatalf("series: %v", err)
	}
	raw := out.String()
	if !strings.Contains(raw, "Net worth over time") || !strings.Contains(raw, "2024-06-17") {
		t.Fatalf("series output unexpected:\n%s", raw)
	}
}

func TestSummaryAsOfRejectsBadDate(t *testing.T) {
	c := summaryCtx(t, true, false)
	out := &strings.Builder{}
	c.Out = out
	if err := summaryCommand(c, []string{"--as-of", "2024-13-45"}); err == nil {
		t.Fatal("expected a usage error for an impossible date")
	}
}

// A stray positional or unknown flag stays ignored (summary is SkipParse).
func TestSummaryIgnoresStrayArgsAlongsideAsOf(t *testing.T) {
	c := summaryCtx(t, true, false)
	out := &strings.Builder{}
	c.Out = out
	if err := summaryCommand(c, []string{"--as-of", "2024-06-17", "--wat", "extra"}); err != nil {
		t.Fatalf("stray args should be ignored, not an error: %v", err)
	}
	if !strings.Contains(out.String(), "Portfolio as of — 2024-06-17") {
		t.Fatalf("stray args changed the answer:\n%s", out.String())
	}
}

// A window without --time-series used to fall through to today's summary, which
// answers "what was I worth over 2024?" with today's numbers and no warning.
func TestWindowFlagsAloneStillProduceASeries(t *testing.T) {
	cfg, err := parseSummaryRunArgs([]string{"--as-of-from", "2024-06-01", "--as-of-to", "2024-06-05"})
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if !cfg.series {
		t.Fatal("--as-of-from/--as-of-to alone must be treated as a series request")
	}
	from, to, err := cfg.resolveWindow(time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatalf("resolveWindow: %v", err)
	}
	days := cfg.seriesDays(from, to)
	if len(days) == 0 {
		t.Fatal("bounded window produced no report days")
	}
	// Month mode reports month-ends, so a short window legitimately collapses
	// to its last day; what must NOT happen is falling through to today.
	if days[len(days)-1].String() != "2024-06-05" {
		t.Fatalf("series should end at the requested window, got %s", days[len(days)-1])
	}
	for _, d := range days {
		if d.String() > "2024-06-05" || d.String() < "2024-06-01" {
			t.Fatalf("series day %s is outside the requested window", d)
		}
	}

	// --daily over the same window must actually walk the days.
	daily, err := parseSummaryRunArgs([]string{"--daily", "--as-of-from", "2024-06-01", "--as-of-to", "2024-06-05"})
	if err != nil {
		t.Fatalf("parse daily: %v", err)
	}
	dFrom, dTo, err := daily.resolveWindow(time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC))
	if err != nil {
		t.Fatalf("resolveWindow daily: %v", err)
	}
	if got := len(daily.seriesDays(dFrom, dTo)); got != 5 {
		t.Fatalf("daily series = %d days, want 5", got)
	}
}

// A backwards window is a usage error, not a silently empty or reversed report.
func TestInvertedWindowIsAUsageError(t *testing.T) {
	cfg, err := parseSummaryRunArgs([]string{"--time-series", "--as-of-from", "2024-06-17", "--as-of-to", "2024-01-01"})
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if _, _, err := cfg.resolveWindow(time.Date(2026, 10, 14, 12, 0, 0, 0, time.UTC)); err == nil {
		t.Fatal("a window whose end precedes its start must be refused")
	}
}
