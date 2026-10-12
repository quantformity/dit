# Coverage lane 2 report — the default reporting currency

Scope: one fidelity defect in `dit market coverage`, found by
`scripts/twin-run.sh` on the twin seed (TFSA/CAD + Margin/USD, SHOP.TO series,
USD/CAD series). The Swift oracle is `/opt/homebrew/bin/dit`; it was read, never
edited.

## The wrong answer, before

Human mode (twin seed, both binaries, paths normalised):

```
Swift:  … window 2024-01-04 … 2026-10-09 · reporting into CAD
Go:     … window 2024-01-04 … 2026-10-09 · reporting into —
```

and the whole FX section was missing from Go:

```
FX into CAD (what combining foreign totals needs):
  │ USD→CAD │ ok — USD/CAD direct, last close 2026-10-08 (1d) — but missing at 26/27 period ends (e.g. 2024-08-31) │
```

JSON mode went further and answered a different question:

| key | Swift | Go (before) |
| --- | --- | --- |
| `reporting` | `"CAD"` | `""` |
| `fx` | one USD→CAD row, `usableNow:true`, `boundariesMissing:26`, `boundariesTotal:27` | `[]` |
| `complete` | `false` | `true` |

`complete:true` is the dangerous half: `--strict` is the hook that tells
someone "you could run a historical report over this window and nothing would
dash". On this seed the oracle exits 1 and prints
`coverage gaps listed above …`; the Go port exited 0.

## Where the oracle gets the default

`Sources/dit/CommandsMarket.swift` (`marketCoverage`):

```swift
let reporting = try options["reporting-ccy"].map { try parseCurrency($0, option: "--reporting-ccy") }
    ?? global.display
```

`Sources/dit/Support.swift`:

```swift
struct Global {
    /// Currency combined totals are expressed in (default CAD).
    var display: Currency = .cad
```

So the default reporting currency is **the global display currency, whose
starting value is `.cad`** — not something the coverage command derives from the
accounts, and never "no currency". `--display USD` moves it; `--reporting-ccy`
overrides it; nothing empties it.

## What the port did instead

`internal/cli/market.go` already reads the display currency
(`reporting := c.Display`), and `market.Report` is a faithful port of the Swift
guard `currency != reportingCurrency, currency != .unknown, reportingCurrency
!= .unknown`. The break was upstream of both, in `cmd/dit/main.go`: the parsed
globals started with an empty display string, and `cli.DisplayCurrency("")`
returns `model.Currency("")` — which *is* `model.Unknown`. One defect, two
symptoms:

1. Rendering. `Currency.String()` renders Unknown as `—`, and the JSON side
   writes the raw code, hence `reporting into —` and `"reporting":""`.
2. The audit. With no reporting currency there is nothing to combine, so
   **every** FX row was skipped — `fx: []`, no FX table — and
   `CoverageReport.Complete()` had no FX rows left to fail on. `complete` went
   `true` and `--strict` exited 0 not because the check was wrong but because
   the thing it checks had been deleted from the report.

Confirming it was one defect and not two: `dit --display CAD market coverage`
already printed the oracle's answer byte for byte. The arithmetic in
`internal/market` was right; the wiring that hands a command its default was
not.

## The fix

`cmd/dit/main.go` declares the default next to the other global defaults and
seeds it into the starting globals, so `Context.Display` always carries a real
currency code and no command has to guess what an empty one means. `--display`
still overrides it, and `checkDisplay` still refuses an unknown code instead of
substituting a plausible one.

Nothing in `internal/market` changed. `Complete()` and `AuditFX` still say
"incomplete" for the same reason the oracle does: the USD/CAD chain answers at
the audit date but is missing at 26 of the 27 period ends the monthly slicing
would use. The `true` is gone because the FX rows are back, not because the
gate was loosened.

## Why no test saw it

`internal/market/coverage_test.go` builds its `cli.Context` with
`Display: model.CAD` written out by hand, and compares against snapshots taken
from the oracle at its own default CAD. Every unit test therefore supplied the
very thing the binary failed to derive. Added `cmd/dit/main_test.go`, which runs
`market coverage` through the real path — `parseGlobals` → `newContext` →
`Dispatch` — against the Swift-written store pair:

- the default display is pinned as CAD *and* as a currency that decodes to
  something other than Unknown;
- human, `--json` and `--strict` output must equal `testdata/market/coverage.txt`
  / `coverage.json` byte for byte, with the strict exit code and its stderr line.

Reverting just the fix makes both tests fail: the report loses its FX section
and claims `"complete":true`, which is the failure the test exists to catch.

## Measured numbers

| Gate | Before | After |
| --- | --- | --- |
| `go build ./...` | passes | passes |
| `go test ./...` | 10 packages ok, cmd/dit had no tests | all packages ok, cmd/dit now carries 4 pinned cases |
| `go vet ./...` | clean | clean |
| `scripts/twin-run.sh` (16 probes) | **10 identical / 6 differing** | **12 identical / 4 differing** |
| `twin-run "market coverage" "market coverage --json"` | 0 / 2 | **2 identical / 0 differing** |
| `twin-run "market coverage --strict"` (extra probe) | differing (exit 0 vs oracle 1) | identical, exit 1 both |
| `scripts/parity.sh` | 2 matched / 0 differed | 2 matched / 0 differed |
| `scripts/e2e-parity.sh` (Swift scenario suite) | 80 passed / 327 failed | 80 passed / 327 failed |

The scenario suite's pass/fail set is byte-identical before and after — only
temp-directory names differ — so nothing there moved either way.

Still differing in twin-run, all separate and untouched here: `summary` (the Go
port does not fetch live quotes, so mixed-currency totals differ),
`market show SHOP.TO` / `market show KO` (a usage error prints no help block),
`market history` (no network provider ported).

## Files

- `cmd/dit/main.go` — `defaultDisplay`, `newContext`, seeded globals.
- `cmd/dit/main_test.go` — new.
- `docs/lanes/coverage2.md` — this report.

No edits to `internal/bundle`, `internal/valuation`, `internal/store` or
`internal/model`, and none to the Swift project.
