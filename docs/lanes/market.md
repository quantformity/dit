# Market lane report

## Result

- `go build -o .build/ditgo ./cmd/dit`: passes.
- `go test ./...`: passes (offline).
- `go vet ./...`: passes.
- Acceptance gate: **71 passed / 336 failed**, unchanged baseline.
  Log: `.build/market-e2e.log` (ignored build artifact).
- Direct command tests compare **15 Swift stdout snapshots byte-for-byte**:
  coverage human/JSON (base, narrowed dates, before ledger, matching ticker,
  unmatched ticker, inverted reporting currency), observed show tail,
  missing-symbol show, derived show tail.
- Additional tests cover gap thresholds/ties/trailing darkness, watermark vs
  observation, currency mismatch, stale FX leg, usage errors, strict JSON's
  single document, corrupt cache vs strict ledger, and read-only file/SQLite
  inspection (including absent stores).

## Files added

- `internal/market/coverage.go`: pure coverage values, gap/watermark functions,
  source checks, dated FX chain facts, period boundaries, ledger coverage audit.
- `internal/cli/market.go`: `marketSpecs`, MarketShow, MarketCoverage,
  MarketHistory's offline/usage refusal paths. File reads do not create
  directories; SQLite reads use `mode=ro` and close connections.
- `internal/market/coverage_test.go`.
- `testdata/market/`: real Swift ledger/cache documents, CSV seeds, stdout
  snapshots and reproduction notes.
- This report.

No forbidden shared files were edited.

## Required shared changes (integration blockers)

1. `internal/cli/table.go`: `commandSpecs()` currently returns a local registry
   with nil market implementations and never reads `marketSpecs`. Change its
   final return to `return mergeLayers(registry, marketSpecs)` (combine other
   lanes' registries here as appropriate). This is why the built binary still
   fails every market target despite passing direct command oracle tests.
2. `internal/cli/dispatch.go`: inside the command error branch, recognize
   `coverageStrictJSON` and return `exitRuntime` **without** Context.Report:
   ```go
   if _, ok := err.(coverageStrictJSON); ok { return exitRuntime }
   ```
   Otherwise JSON+strict emits a second error document. The command already
   writes the coverage/1 document with complete:false and returns the sentinel.
   This hook avoids os.Exit in command code and permits tests/API callers.
3. Other lanes/shared integration must supply account/tx mutations, market
   import and backfill to seed scenario sections 14 and 21 under the Go CLI.
   The entire acceptance script seeds with the binary under test, so registry
   wiring alone cannot pass the coverage fixture bootstrap on this baseline.

## Reference synopsis discrepancy / deliberately excluded work

The requested `market history <SYM>` daily-close listing does **not exist**
in the reference Swift source or installed binary. History fetches; positional
symbols are usage errors, `--from/--to` are explicitly not wired, and offline
history exits 2 with the exact network-refusal message. `market show <SYM>`
also rejects positionals; the actual read path is `--symbol S [--days N]`.
Coverage accepts `--tickers`, not `--symbol`, and --json is global. This port
follows the observed/source contract, not the incompatible synopsis.

Live provider history remains unported and is explicitly refused at runtime;
no network attempt, cache write, or invented daily-close listing occurs.
Backfill/import are outside the three-command deliverable; fixtures were
seeded using Swift, not by adding those commands to this lane.

## Remaining edge risks

- Swift cache decoding normalizes duplicate days with **last** observation
  winning, while the existing Go model keeps **first**. Also malformed
  coveredThrough should be ignored, whereas the existing model's default
  decoding rejects that series section. These need changes confined to
  `internal/model/market.go` if damaged-cache parity is tested. This lane
  isolates malformed top-level cache sections at its read boundary but never
  applies leniency to ledgers or bundles.
- I/O-error prose comes from existing Go storage/OS errors, rather than exact
  Swift DataStoreError formatting; normal/absent/corrupt-document paths are
  tested, unreadable-file diagnostic bytes are not.
- Coverage replays just the holdings/cash/live-GIC facts because this baseline
  has no shared AccountBalances Go API. It follows Swift's zero-clamped sales,
  stable date ordering, fees, FX cash legs, and redeemed-GIC removal. If a
  shared balance package lands, use its replay instead of maintaining two
  implementations. No valuation or float price arithmetic is introduced.
