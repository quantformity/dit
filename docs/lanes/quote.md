# Quote lane

## Delivered

- `internal/cli/quote.go`: plain `QuoteLookup` function and `var quoteSpecs = Registry{...}`; live equities/FX, multiple symbols in request order (including duplicates), trim/uppercase normalization without ticker aliases, partial and total misses, historical single-day and range views.
- `internal/cli/quote_matrix.go`: 3+ currency matrix; direct/reciprocal/triangulated/missing cells, USD hub legs even when USD is absent from the requested chain, single-day validation, offline stored mode.
- `internal/cli/quote_help.go`: exact reference `help quote` wording for usage failures.
- `internal/cli/quote_format.go`: display-only ties-to-even rounding, using internal/decimal exclusively. The reference emits `1234.12` for `1234.125`; ledger rounding must not be changed to achieve that.
- `quote/1` JSON live/store/series/matrix envelopes: sorted keys, decimal strings, explicit nulls, provenance and missing markers. Equity prices use two places, live FX and matrix rates six places. Historical pair prices intentionally use two places, matching the reference.
- Tests use `providerForCommand` / `DIT_PROVIDER_STUB`, never the network. Regression coverage includes transport failures, empty results, missing directories, table layout, JSON, provenance, rounding, and matrix arithmetic.
- Two narrow provider fixes in `internal/provider/yahoo.go`: preserve a present timestamp of zero as the Unix epoch (TOB actually returns this); decode prices/rates as `json.Number` directly into decimal, removing the preexisting float64 money/rate conversion. `internal/provider/quote_decode_test.go` checks exact decimal lexemes and epoch timestamps with an injected transport.

## Authority versus brief

`/opt/homebrew/bin/dit` and `CommandsMarket.swift:quoteLookup` agree: plain live quote **does not fall back to latestQuote or daily closes**. It does not open the market store, does not add summary's stale-price note, and refuses `--offline`. Historical modes read daily closes and label observed/derived values and lag days. A fallback or a new staleness sentence here would break parity; therefore summary's valuation fallback was not repurposed. No other-currency series is substituted for a live quote. Historical mode displays the requested series in its own currency, exactly as Swift does.

TOB is not an alias for SHOP.TO: the live oracle presently returns TOB as unknown currency, price zero, timestamp epoch; a truly nonexistent symbol is a missing row. Human live timestamps use `Oct 9, 2026 at 4:00 PM` (the binary differs from the checkout's TextFormat.clock wording).

## Measurements and gates

- `go build ./...`: PASS.
- `go test ./...`: PASS; quote tests pin all provider work.
- `scripts/quote-parity.sh`: real `/opt/homebrew/bin/dit` versus Go binaries on copies of a single Swift-seeded store. **Before: 0 identical / 35 differing. After overlay wiring: 35 identical / 0 differing.** Includes four real live text/JSON probes, not just offline fixtures or mocked oracle answers.
- Added quote probes to `scripts/twin-run.sh`, plus USD/HKD and USD/EUR legs and exact rounding fixtures in `testdata/twin-seed.csv`. Matrix probes exercise direct, inverse, true triangulation, absent USD in the chain, and missing JPY cells.
- Twin-run now compares stdout and stderr separately with `cmp`, preserving final newlines; only the intentionally different store roots are normalized. For every failing quote on either side it runs recursive byte comparisons against pre-run seed copies for both portfolio and market directories. All such comparisons passed. Unit tests additionally snapshot directory names and every file's bytes before failing commands, and check that missing stores remain absent.
- Logs from the last run: `.build/quote-parity.log` (untracked build artifact).

## Parent-owned seams — required, NOT edited

1. `internal/cli/table.go`, final merge: exact requested one-line wiring:

   ```go
   return mergeLayers(registry, summarySpecs, txListSpecs, marketSpecs, transferSpecs, quoteSpecs)
   ```

2. `internal/cli/dispatch.go`, `resolve`, immediately after `name, spec := registry.Lookup(group, sub)` and before the final return:

   ```go
   if group == "quote" && rawSub != "" { rest = append([]string{rawSub}, rest...) }
   ```

   Current shared dispatch consumes the first symbol as a subcommand word and silently loses it. Preserve `rawSub`, not the lowercased `sub` (matrix query tokens echo original spelling).

`scripts/quote-parity.sh` builds the unmodified command first, then builds a Go overlay applying exactly these two lines to temporary copies. Neither parent-owned source file is changed. The ordinary binary remains unwired until the parent applies them. No edit was made to the Swift checkout or reference binary.

General `help` is still parent-owned/unported: the quote Spec supplies the authoritative HelpText; a future `dit help quote` implementation should obtain it from that Spec rather than inventing another copy.
