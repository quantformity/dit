package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"dit/internal/config"
	"dit/internal/model"
)

var fixtureNow = time.Date(2026, 10, 9, 20, 0, 0, 0, time.UTC)

type summaryDoc struct {
	OK      bool `json:"ok"`
	Schema  string
	Data    map[string]any `json:"data"`
}

func (d summaryDoc) data() map[string]any {
	if d.Data != nil {
		return d.Data
	}
	return map[string]any{}
}

func (d summaryDoc) holdings(t *testing.T) []map[string]any {
	t.Helper()
	rows, _ := d.data()["holdings"].([]any)
	out := []map[string]any{}
	for _, r := range rows {
		out = append(out, r.(map[string]any))
	}
	return out
}

func (d summaryDoc) shopRow(t *testing.T) map[string]any {
	t.Helper()
	for _, h := range d.holdings(t) {
		if h["symbol"] == "SHOP.TO" {
			return h
		}
	}
	t.Fatalf("no SHOP.TO holding in %+v", d.data())
	return nil
}

func (d summaryDoc) notes(t *testing.T) []string {
	t.Helper()
	rows, _ := d.data()["warnings"].([]any)
	out := []string{}
	for _, r := range rows {
		out = append(out, r.(string))
	}
	return out
}

func summaryCtx(t *testing.T, offline, jsonOut bool) Context {
	t.Helper()
	return Context{
		Layout:  config.Layout{Backend: config.File, PortfolioDir: filepath.Join("..", "..", "testdata", "fixtures", "richstore", "store"), MarketDir: filepath.Join("..", "..", "testdata", "fixtures", "richstore", "market")},
		JSON:    jsonOut,
		Offline: offline,
		Display: model.CAD,
	}
}

func writePin(t *testing.T, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "pin.json")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func runSummary(t *testing.T, c Context, now time.Time) (summaryDoc, string) {
	t.Helper()
	out := &strings.Builder{}
	c.Out = out
	if err := summaryRun(c, now); err != nil {
		t.Fatalf("summaryRun: %v", err)
	}
	var doc summaryDoc
	if c.JSON {
		if err := json.Unmarshal([]byte(out.String()), &doc); err != nil {
			t.Fatalf("summary JSON: %v\n%s", err, out.String())
		}
		if !doc.OK || doc.Schema != "summary/1" {
			t.Fatalf("doc = %s", out.String())
		}
	}
	return doc, out.String()
}

func TestSummaryLiveMarksFromPinnedObservations(t *testing.T) {
	pin := writePin(t, `{
	  "quotes": [{"symbol": "SHOP.TO", "currency": "CAD", "price": "243.83", "asOf": "2026-10-09T20:00:00Z"}],
	  "rates":  [{"base": "USD", "quote": "CAD", "rate": "1.4254", "asOf": "2026-10-09T20:00:00Z"}]
	}`)
	t.Setenv("DIT_PROVIDER_STUB", pin)

	doc, raw := runSummary(t, summaryCtx(t, false, true), fixtureNow)
	row := doc.shopRow(t)
	// Six shares, cost 88.25 each, now 243.83.
	if got := row["value"]; got != "1462.98" {
		t.Fatalf("value = %v, want 1462.98 (6 x 243.83)", got)
	}
	// Day change against the stored point strictly before the quote's stamp:
	// 6 x (243.83 - 93.10).
	if got := row["dayChange"]; got != "904.38" {
		t.Fatalf("dayChange = %v, want 904.38", got)
	}
	// The quote block carries its provenance and the previous close.
	quote, _ := row["quote"].(map[string]any)
	if quote == nil {
		t.Fatalf("no quote block: %s", raw)
	}
	if quote["price"] != "243.83" || quote["asOf"] != "2026-10-09T20:00:00Z" {
		t.Fatalf("quote = %v", quote)
	}
	prev, _ := quote["previousClose"].(map[string]any)
	if prev == nil || prev["price"] != "93.10" {
		t.Fatalf("previousClose = %v", quote["previousClose"])
	}
	// The pin is exactly one hour old as of fixtureNow plus that much; the
	// staleness note threshold is a minute, and it is fresh, so no note.
	var stale bool
	for _, n := range doc.notes(t) {
		if strings.Contains(n, "stale") {
			stale = true
		}
	}
	if stale {
		t.Fatalf("fresh pin produced a staleness note: %v", doc.notes(t))
	}
	if got := doc.data()["degraded"]; got != false {
		t.Fatalf("degraded = %v, want false", got)
	}
}

func TestSummaryFallsBackToStoredClosesWhenTheMarketIsUnreachable(t *testing.T) {
	// A pin with a scripted transport failure stands in for a dead network.
	pin := writePin(t, `{"quotes": [], "rates": [], "transportError": "connection reset by peer"}`)
	t.Setenv("DIT_PROVIDER_STUB", pin)

	doc, _ := runSummary(t, summaryCtx(t, false, true), fixtureNow)
	row := doc.shopRow(t)
	// With no live quote the position is priced from its newest stored close
	// (6 shares x 93.10), NOT from cost. The Swift tool uses cost here; this
	// port chooses the stored close and has to say so, which is what the rest
	// of this test checks. Cost would be 530.69.
	if got := row["value"]; got != "558.60" {
		t.Fatalf("value = %v, want 558.60 (6 shares at the 93.10 stored close)", got)
	}
	quote, isQuote := row["quote"].(map[string]any)
	if !isQuote {
		t.Fatalf("a stored close must still be reported as the price source: %v", row["quote"])
	}
	if quote["live"] != false {
		t.Fatalf("a file-sourced price must declare itself not live: %v", quote)
	}
	if quote["price"] != "93.10" {
		t.Fatalf("quoted price = %v, want 93.10", quote["price"])
	}
	// A delta between two stored closes is not today's move, so no day-change
	// figure is claimed.
	if row["dayChange"] != nil {
		t.Fatalf("a stale mark must not report a day change: %v", row["dayChange"])
	}
	// It says what failed, and what it used instead.
	joined := strings.Join(doc.notes(t), "\n")
	for _, want := range []string{"fetch failed", "connection reset by peer", "no live quote", "93.10"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("notes must name %q, got: %v", want, doc.notes(t))
		}
	}
	if got := doc.data()["degraded"]; got != true {
		t.Fatalf("degraded = %v, want true", got)
	}
}

func TestSummaryWithoutStoredHistoryStaysAtCost(t *testing.T) {
	// No market store at all: nothing to fall back to, so the numbers are cost
	// basis and the report does not pretend otherwise. This is the path the
	// Swift tool takes for every failed fetch.
	c := summaryCtx(t, false, true)
	c.Layout.MarketDir = t.TempDir()
	pin := writePin(t, `{"quotes": [], "rates": [], "transportError": "connection reset by peer"}`)
	t.Setenv("DIT_PROVIDER_STUB", pin)

	doc, _ := runSummary(t, c, fixtureNow)
	row := doc.shopRow(t)
	if got := row["value"]; got != "530.69" {
		t.Fatalf("value = %v, want 530.69 (cost incl. fees)", got)
	}
	if row["quote"] != nil {
		t.Fatalf("no price may be invented from an empty market store: %v", row["quote"])
	}
	joined := strings.Join(doc.notes(t), "\n")
	if !strings.Contains(joined, "fetch failed") {
		t.Fatalf("notes do not name the failure: %v", doc.notes(t))
	}
}

func TestSummaryOfflineIsCostWithNoObservations(t *testing.T) {
	// No provider at all may be consulted in offline mode, even if a pin is
	// present; the note must say what the numbers are (and are not).
	t.Setenv("DIT_PROVIDER_STUB", "/definitely/not/used")
	doc, _ := runSummary(t, summaryCtx(t, true, true), fixtureNow)
	row := doc.shopRow(t)
	if got := row["value"]; got != "530.69" {
		t.Fatalf("offline value = %v, want 530.69 (cost incl. fees)", got)
	}
	if row["quote"] != nil {
		t.Fatalf("offline summary must not carry a quote: %v", row["quote"])
	}
	joined := strings.Join(doc.notes(t), "\n")
	if !strings.Contains(joined, "offline") {
		t.Fatalf("offline note missing: %v", doc.notes(t))
	}
	if got := doc.data()["offline"]; got != true {
		t.Fatalf("offline flag = %v", got)
	}
}

func TestSummaryToleratesTheOracleLenientArguments(t *testing.T) {
	// The oracle accepts --bogus and stray positionals after `summary`.
	c := summaryCtx(t, false, true)
	c.Out = &strings.Builder{}
	if err := summaryCommand(c, []string{"extra", "--bogus", "thing"}); err != nil {
		t.Fatalf("summary with stray args must succeed: %v", err)
	}
	co := summaryCtx(t, true, false)
	co.Out = &strings.Builder{}
	if err := summaryCommand(co, []string{"--bogus", "extra"}); err != nil {
		t.Fatalf("offline summary with stray args must succeed: %v", err)
	}
}

func TestSummaryBadPinIsAFailedFetchNotACrash(t *testing.T) {
	t.Setenv("DIT_PROVIDER_STUB", "/definitely/not/a/pin.json")
	doc, _ := runSummary(t, summaryCtx(t, false, true), fixtureNow)
	row := doc.shopRow(t)
	// An unreadable pin is a failed fetch, and a failed fetch prices from the
	// stored close — the point of this test is that it degrades instead of
	// crashing, whatever the numbers come out at.
	if got := row["value"]; got != "558.60" {
		t.Fatalf("value = %v, want 558.60 (stored close)", got)
	}
	joined := strings.Join(doc.notes(t), "\n")
	if !strings.Contains(joined, "DIT_PROVIDER_STUB") {
		t.Fatalf("notes must name the pin: %v", doc.notes(t))
	}
}
