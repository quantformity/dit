# pnl lane

## Port

Read the complete Swift `CommandsPnL.swift` and `PnLWindow.swift`, plus
`FXHistory.swift`, the helpers, and the oracle's `docs/json.md` before implementing.

- `pnlSpecs` implements `pnl`, text and `pnl/1` JSON.
- Default/full-ledger windows, scoped ledger start, explicit inclusive dates,
  calendar-clamped Nd/Nw/Nm/Ny and ytd horizons, scope/filter validation,
  per-account versus portfolio grouping.
- Auto slicing is **daily ≤10 days, weekly 11–56, monthly >56**. There is no
  `--granularity` option. `--daily` only modifies `--time-series`.
- Boundary marks use the last close strictly before start and on/before end.
  Missing days carry the preceding observation; missing required observations
  withhold drift/total. Unlabelled series are usable; explicitly wrong-currency
  series are not. Proxy history remains `derived`, marked `*`.
- Historical FX uses daily pair series only, direct/inverted/USD-hub routes,
  refusing any leg older than seven days. Earlier/derived FX is marked `~`.
  Native JSON figures remain native; missing conversion legs withhold the
  combined total, including when a later currency has a usable conversion.
- Quiet and unmeasurable periods are counted separately; native slices are
  checked for reconciliation. Each slice converts at its own end date.
- No provider calls. `--offline` still reads historical market data.
- Swift's P&L detail tables actually have **four-space** indentation; period
  tables have two. This port follows the measured binary, not a uniform indent.

## Single replay, not a second money engine

`internal/valuation/value.go` now retains `Account.Income` (per instrument)
while running its existing replay. The existing sale/GIC/dividend calculation
is computed once and accumulated both into the old currency totals and this
new breakdown. GIC replay state additionally retains its product label.
No cost-basis rules or provider behavior were changed.

`ComputePnL` calls that replay twice with historical marks, then differences
its booked income and marked position value minus remaining cost. Window and
series code do not replay transaction kinds or independently calculate sale
cost basis. Everything uses `internal/decimal`.

## Gates and measurements

Executed in this worktree against `/opt/homebrew/bin/dit`:

- `go build ./...`: PASS.
- `go test ./...`: PASS (all 12 package results; no new network tests).
- Standard pnl probes added to `scripts/twin-run.sh`: **before 0 identical /
  32 differing; after 32 identical / 0 differing**.
- Opt-in `PNL_FIXTURE=1` stress probes: **14 identical / 0 differing**.
  Covers proxy provenance, wrong currency, absent boundary history, flat
  round trips/dividends, direct FX, inverted FX, USD-hub cross FX, seven/eight
  day FX boundaries, missing JPY leg, per-account output, and short notes.
- `CHECK_READ_ONLY=1` copies both store directories before each command and
  runs recursive byte comparisons afterward. **46/46 probe stores unchanged**,
  including usage failures and the unknown-account runtime failure.
- New unit tests cover exact JSON bytes, replay/window values, source immutability,
  calendar clamping, bucket adjacency/granularity, no snapshot FX fallback,
  missing-leg stickiness, GIC redemption linkage, same-day round trips, absent
  store directories, explicit false flags, and failing command byte comparisons.

Reproduce: `scripts/pnl-parity.sh`; baseline: `scripts/pnl-parity.sh --baseline`
(before parent wiring). It builds a real Go CLI, runs real Swift and Go commands
on identical store copies via twin-run, and removes its temporary build-tagged
adapter on exit. The adapter changes no parent-owned file; it merely supplies
`pnlSpecs` through an already merged lane map in the instrumented binary.
The normal Go binary deliberately remains unwired until the parent merges it.

## Parent-owned seam: exact wiring

In `internal/cli/table.go`, replace the merge return with this one line:

```go
return mergeLayers(registry, summarySpecs, txListSpecs, marketSpecs, transferSpecs, pnlSpecs)
```

No edits were made to `table.go`, `dispatch.go`, or `registry.go`.
`pnlSpecs` carries the full oracle help text, so usage errors need no other
help wiring. The existing JSON allowlist already includes pnl.

## Existing shared-loader limitation

The reused read-only `summaryLoad` / `store.LoadMarket` boundary suppresses
market-store I/O errors. Ordinary missing or malformed market data correctly
produces missing-history notes, but an actual unreadable market store cannot
currently add Swift's additional **text-only**
`market store unreadable: <error> — no position-change data` note.
A shared checked read-only loader that returns the market read error separately
is needed to expose that diagnostic; it must not turn the refetchable-cache
failure into ledger failure or create directories/databases. No alternate
store loader or second financial engine was introduced to paper over this seam.
Raw corrupt-ledger diagnostic wording also remains the shared store decoder's
responsibility; the ledger failure still exits 1 without mutation.
