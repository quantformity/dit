# Valuation lane

## Status

Partial deliverable; NOT claiming the acceptance gate passed.

- `go test ./...`: passed.
- `go vet ./internal/valuation ./internal/cli`: passed.
- `go build -o .build/ditgo ./cmd/dit`: passed.
- Required scenario command: **71 passed, 336 failed** (unchanged baseline).
- Required `summary` and `summary --json` executable diffs: failed, pasted below.
- No protected/shared files edited.

Added:
- `internal/valuation/value.go`
- `internal/valuation/value_test.go`
- `internal/cli/summary.go`
- `LANEREPORT.md`

## What is implemented / verified

Pure valuation functions replay the ledger in stable date/storage order, derive fee-inclusive average costs, cash pools, realized sale/dividend/GIC P&L, live GIC principal at par, aggregated holdings, native totals, account totals, display totals, daily pairs, and untracked shorts. All financial arithmetic uses internal/decimal. No display-rounded amount is used for arithmetic. Stored-close selection delegates to MarketData.CloseOnOrBefore, keeps the observation date and via, and refuses a currency mismatch/unknown currency. Conversion prefers a direct pair, then reciprocal, then USD-hub composition. A missing conversion leg invalidates the combined total, retaining exact native components.

`CostSummary` is intentionally separate: it implements the checked-in Swift's `--offline` contract (no pricing and no FX). Last/P&L/day stay absent without a quote, while the cost value is explicitly labelled, matching Swift's actual renderer. This is NOT an invented market price.

The CLI has summarySpecs for summary and the bare form, rendering, summary/1 JSON, missing/empty portfolio handling, and a load-only adapter over the shared Store value. Shared store constructors create directories/schema even on reads, so the adapter reads file bytes / opens SQLite with mode=ro and never invokes a write operation. Explicit offline mode does not read the market document.

`TestRichStoreSwiftOfflineFigures` asserts actual captured Swift numbers on the unmodified richstore. `TestRichStoreOracleOffline` runs `/opt/homebrew/bin/dit` on a private copy and verifies the ENTIRE JSON byte-for-byte after using the oracle's generatedAt. The entire human report body also matches byte-for-byte (the volatile clock header is excluded). Tested values include positions 530.69, realized 66.15, dividends 12.34, CAD cash 24692.76, USD cash -789.25, CAD total 25223.45, USD total 4210.75, TFSA total 23865.65, and live GIC principal 5000.00. These are oracle values, not hand-computed expectations.

Additional tests cover unknown-currency refusal, stored observation dates, derived-current and derived-baseline provenance, no-baseline -> nil rather than zero, direct-pair priority, USD triangulation, missing legs, future-rate refusal, and source-document immutability.

## Blockers / integration changes required (NOT edited here)

1. **Protected `internal/cli/table.go` does not merge lane registries.** It installs `summary` with a nil Run and never references summarySpecs. Integration owner should change the final `return registry` in commandSpecs to mergeLayers(registry, summarySpecs, ...other lane specs...). Bare dispatch already routes to summary. Without this change, no summary command can reach the implementation and the executable acceptance count cannot gain any assertions. I did not circumvent this with init/global mutation or edit the protected file.

2. **The requested default-summary oracle is not offline.** Checked-in `Sources/dit/CommandsCore.swift` fetches Yahoo prices/FX in default mode. Stored daily closes are ONLY consulted as previous-close baselines. `--offline` explicitly ignores the market store and uses cost, no FX. The installed binary behaves the same. Default fixture summary fetched SHOP.TO at 243.83 on 2026-10-09 and USD/CAD at 1.4254, producing the numbers below. Neither is in richstore. The fixture has only SHOP.TO closes 91.25 / 93.10 from May 2024 and USD/CAD 1.3578 from May 2024, with empty latestQuotes/latestRates. Its SHOP.TO series currency is unknown (`""`). An offline stored-close engine cannot honestly reproduce the oracle's fresh Yahoo prices, provenance/source, staleness note, or daily pair. I implemented the requested stored-close engine for Compute/default summary and the actual Swift cost contract for explicit --offline. This intentional divergence needs an integration/product decision, not a fabricated price or hardcoded live oracle result.

3. Swift Foundation arithmetic produces `-0.00` in the live fixture Margin positions cell (total-cash-gic residual), while exact Go decimal arithmetic produces zero. Offline fixture parity does not suffer this. No numerical-noise hack was added.

4. Default output's generatedAt is volatile at second resolution; independent processes cannot in general match it byte-for-byte without clock injection. The oracle test uses its captured generatedAt, rather than claiming wall-clock equality.

5. Market cache loading uses shared LoadMarket's silent empty-cache degradation. The CLI does not yet distinguish missing vs unreadable cache in the degraded flag. Protected store APIs expose no degradation metadata.

## Oracle capture / actual required executable diffs

Scratch store: `/var/folders/mz/pnqx2ygd7sd6qx_k0hmr6yg40000gn/T/tmp.r3f9iAtl9C/store`

Go stderr (text mode):
```
error: summary is not ported to Go yet — this build implements: accounts, store path
```

Actual `diff <(Swift summary) <(Go summary)`:
```diff
1,42d0
< Portfolio summary — Oct 9, 2026 at 7:01 PM  (display: CAD)
< 
<   Total value      32,157.74 CAD
<   Cash             23,567.76 CAD
<   Positions        1,462.98 CAD
<   GICs (at par)    7,127.00 CAD
< 
<   Unrealized P&L   932.29 CAD
<   Day change       904.38 CAD   (vs previous close)
<   Realized P&L     66.15 CAD
<   Dividends        12.34 CAD
< 
< By currency:
< ┌─────┬───────────┬───────────┬──────────┬───────────┬────────┐
< │ Ccy │      Cash │ Positions │      GIC │     Total │    Day │
< ├─────┼───────────┼───────────┼──────────┼───────────┼────────┤
< │ CAD │ 24,692.76 │  1,462.98 │     0.00 │ 26,155.74 │ 904.38 │
< ├─────┼───────────┼───────────┼──────────┼───────────┼────────┤
< │ USD │   -789.25 │      0.00 │ 5,000.00 │  4,210.75 │      — │
< └─────┴───────────┴───────────┴──────────┴───────────┴────────┘
< 
< Accounts:
< ┌────────┬─────┬───────────┬───────────┬──────────┬───────────┬────────────┬────────┐
< │ Name   │ Ccy │      Cash │ Positions │      GIC │     Total │ Unrealized │    Day │
< ├────────┼─────┼───────────┼───────────┼──────────┼───────────┼────────────┼────────┤
< │ TFSA   │ CAD │ 23,334.96 │  1,462.98 │     0.00 │ 24,797.94 │     932.29 │ 904.38 │
< ├────────┼─────┼───────────┼───────────┼──────────┼───────────┼────────────┼────────┤
< │ Margin │ USD │    163.32 │     -0.00 │ 5,000.00 │  5,163.32 │          — │      — │
< └────────┴─────┴───────────┴───────────┴──────────┴───────────┴────────────┴────────┘
< 
< Holdings:
< ┌─────────┬─────────┬─────┬────────┬──────────┬────────┬──────────────┬───────────┬─────────┬───────────┬─────────┬───────┐
< │ Symbol  │ Name    │ Ccy │ Shares │ Avg cost │   Last │        Value │ Day (CAD) │    Day% │ P&L (CAD) │    P&L% │ Where │
< ├─────────┼─────────┼─────┼────────┼──────────┼────────┼──────────────┼───────────┼─────────┼───────────┼─────────┼───────┤
< │ SHOP.TO │ Shopify │ CAD │      6 │    88.45 │ 243.83 │ CAD 1,462.98 │    904.38 │ +161.9% │    932.29 │ +175.7% │  TFSA │
< └─────────┴─────────┴─────┴────────┴──────────┴────────┴──────────────┴───────────┴─────────┴───────────┴─────────┴───────┘
< 
< Notes:
<   - quote data as of Oct 9, 2026 at 4:00 PM — market may be closed, prices may be stale
<   - day change = latest quote vs the previous stored close of the same ticker (a model comparison where history is derived)
< 
< Store: /var/folders/mz/pnqx2ygd7sd6qx_k0hmr6yg40000gn/T/tmp.r3f9iAtl9C/store
```

Actual JSON diff:
```diff
1c1
< {"data":{"accounts":[{"cash":"23334.96","dayChange":"904.38","gic":"0.00","id":"571F5FD5-9E45-4E2A-99D9-06AB70967120","name":"TFSA","positions":"1462.98","reportingCurrency":"CAD","total":"24797.94","unrealizedPnl":"932.29"},{"cash":"163.32","dayChange":null,"gic":"5000.00","id":"F68B0F3C-310B-4144-BA48-09B3B665FDC2","name":"Margin","positions":"-0.00","reportingCurrency":"USD","total":"5163.32","unrealizedPnl":null}],"degraded":false,"displayCurrency":"CAD","generatedAt":"2026-10-09T23:01:52Z","holdings":[{"accounts":["TFSA"],"avgCost":"88.45","ccy":"CAD","dayChange":"904.38","dayChangeDisplay":"904.38","dayPct":"1.6190","name":"Shopify","pnl":"932.29","pnlDisplay":"932.29","pnlPct":"1.7567","quote":{"asOf":"2026-10-09T20:00:00Z","previousClose":{"date":"2024-05-02","price":"93.10","via":null},"price":"243.83","source":"yahoo"},"shares":"6","symbol":"SHOP.TO","value":"1462.98","valueDisplay":"1462.98"}],"offline":false,"store":"/var/folders/mz/pnqx2ygd7sd6qx_k0hmr6yg40000gn/T/tmp.r3f9iAtl9C/store","totals":{"byCurrency":{"CAD":{"cash":"24692.76","dayChange":"904.38","gic":"0.00","positions":"1462.98","total":"26155.74"},"USD":{"cash":"-789.25","dayChange":null,"gic":"5000.00","positions":"0.00","total":"4210.75"}},"cash":"23567.76","dayChange":"904.38","dividends":"12.34","gic":"7127.00","positions":"1462.98","realizedPnl":"66.15","totalValue":"32157.74","unrealizedPnl":"932.29"},"untrackedShorts":[],"warnings":["quote data as of Oct 9, 2026 at 4:00 PM — market may be closed, prices may be stale"]},"ok":true,"schema":"summary/1"}
---
> {"error":"summary is not ported to Go yet — this build implements: accounts, store path","kind":"runtime","ok":false}
```

## E2E tail

```
Scenario: 71 passed, 336 failed
Workdir kept for inspection: /tmp/dit-scenario.V94HC3
```
