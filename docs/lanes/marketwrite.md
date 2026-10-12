# marketwrite

## Delivered

- `market latest`: held-symbol snapshots plus USD hub rates; writes `latestQuotes` and `latestRates`, not portfolio quotes. Missing quotes/rates are warnings. Missing portfolio is the Swift quiet success.
- `market history`: real daily fetching, holding-window filtering, watermark-paced incremental requests, `--all` gap filling without replacing real closes, and `--rebuild` erasure of daily series while preserving snapshots. Successful empty responses advance the watermark. The Swift refusal of `--from/--to` remains intentional.
- `market backfill`: registry currency lookup, optional source/FX fetching, real-only calibration (including stored latest quotes), six-place mean ratio, spread warning, weekday synthesis, exact-day source closes, up-to-three-day FX carry, four-place derived prices, `via` labels, preserved real closes, recomputation of derived values, and dry run.
- `market import`: exactly three nonempty comma-separated fields, comment/header skipping, Swift line numbering (empty physical lines do not count), Foundation-style date rollover and numeric-prefix parsing, malformed-line warnings capped at eight, duplicate incoming-line counts, real-over-derived replacement, pair currency inference, dry run. A fourth BASIS column is **not accepted**, despite the Swift comment suggesting one.
- `update`: latest → history (`--all` by default, incremental with `--quick`, erase/refetch with `--rebuild`) → existing coverage audit. Fetch output is buffered until all fetch work has finished. Writes are staged until the operation succeeds.

Files: `internal/cli/market_write*.go`, `internal/cli/market_backfill.go`, `internal/market/write*.go`, `internal/provider/daily*.go`; small extensions to existing market/summary/provider wiring.

## Gates and measured parity

`go build ./...` and `go test -count=1 ./...` pass. Twelve new top-level tests exercise CSV, merge, provider transport and pin decoding, latest/history/update persistence, cross-currency derivation, dry runs, watermark pacing, and error immutability. Tests use pin files or injected transports; none requires network.

Real binary comparisons: `/opt/homebrew/bin/dit` vs `.build/ditgo`, stores seeded once by Swift and copied per probe:

| Suite | Before | After |
| --- | --- | --- |
| `MARKETWRITE=1 scripts/twin-run.sh` | 3 identical / 17 differing | 20 identical / 0 differing |
| Missing-portfolio refresh suite | 0 identical / 6 differing | 6 identical / 0 differing |
| Total | 3 / 23 | 26 / 0 |

Before binary was built from this worktree's original HEAD using `git archive` into ignored `.build/before`. Commands for the missing-portfolio suite:

```sh
MARKETWRITE_EMPTY=1 scripts/twin-run.sh 'market latest' 'market history' \
  'market history --rebuild' 'update' 'update --quick' 'update --rebuild'
```

The harness now compares stdout and stderr **separately and byte-for-byte**, including trailing newlines, after path normalization. In MARKETWRITE mode it also compares persisted JSON facts (only independent write-time `updatedAt` is excluded), and compares both stores against pre-run byte snapshots for every failing probe. Mixed import parity measured four additions from four accepted lines (including two duplicate incoming derived-replacement lines); proxy parity measured two derived points, plus one preserved real anchor, and zero changes on rerun.

Additional real failing-command proof: `market history --rebuild` and `update` with `DIT_PROVIDER_STUB=.build/outage.json` both exited **1**; `diff -r .build/proof-before .build/proof` returned **0** after each. Unit tests additionally execute `update --rebuild` with successful pinned latest quotes/rates and failing daily fetches, proving neither phase leaks writes on error.

## Determinism limits / deviations

- Deterministic history parity seeds identical closes and verified watermarks on both sides, so the incremental Swift invocation skips the network. Offline backfill and import are deterministic real write comparisons.
- Go provider pins cover successful live-snapshot and daily-fetch paths, including `--all`, `--rebuild`, and full `update`; Yahoo daily decoding is tested through its existing injected HTTP transport. **These are not claims of online Swift parity.** Swift does not honor Go pin files, and its latest command always fetches even when stored closes exist. No claim is made to reproduce the earlier online 1,368-point run deterministically. Provider network-error wording remains platform-dependent.
- The ground rule that errors must not mutate stores takes precedence over Swift's current all-fetches-fail history behavior: Swift saves its attempted history pass before returning the all-failed error. Go intentionally does not save that pass; likewise, a failed `update` does not commit a preceding successful latest phase. `--rebuild` erases staged history before fetching, not the persisted cache before success.
- Existing summary quote freshness/staleness text is untouched. Latest shows the provider timestamp exactly as Swift does; it does not apply summary freshness rejection to storage.

## Shared seams / exact wiring

No changes were made to `internal/cli/table.go`, `dispatch.go`, or `registry.go`.

The lane exposes `var marketWriteSpecs = Registry{...}`. To enable real command parity without touching those parent-owned files, the existing `marketSpecs` in the lane-owned `market.go` composes it locally with `mergeLayers(marketWriteSpecs, Registry{...})`; therefore **no parent change is required** for this patch to run.

If the parent wants all registry composition in `table.go`, remove that local composition and use this exact one-line replacement there:

```go
return mergeLayers(registry, summarySpecs, txListSpecs, marketSpecs, marketWriteSpecs, transferSpecs)
```

Provider shared boundary now has `DailySeries func(string, model.Day, model.Day) (provider.DailySeries, error)`. The invalid-pin fallback in `summary.go` also fills this function, so a malformed pin never falls through to Yahoo or a nil call. Yahoo uses the **existing** configured `Do` function/client. Latest money JSON decoding was changed from float64 to `json.Number` → `internal/decimal`.

Pin extension (days are ISO UTC dates, prices are decimal strings):

```json
{"series":{"SHOP.TO":{"currency":"CAD","points":[{"day":"2024-06-17","price":"96.4"}]},"CAD=X":{"currency":"CAD","points":[{"day":"2024-06-17","price":"1.3578"}]}}}
```

Missing series is a successful empty answer. `transportError` fails all calls; optional `dailyError` fails only daily calls (for update atomicity tests). Existing quote/rate pin shapes are unchanged.
