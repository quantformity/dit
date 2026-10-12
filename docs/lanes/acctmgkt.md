# acctmgkt — account and instrument management

## Delivered

`internal/cli/acctmgkt.go` exposes `var acctmgktSpecs Registry` for account add/edit/close/delete/show and ticker list/show/add/edit/delete (including bare `ticker`). Commands are plain functions; mutations validate before saving via the existing transactional `transferSave` function. There are no provider calls or floating-point money/rate paths.

Account statements include offline cash, GICs, dividends, realized P&L, cost-basis positions, optional chronological history, and `account/1` JSON. Instrument metadata includes name, trading currency, tags, notes, and transaction reference counts. Help blocks are copied from the reference binary into `acctmgkt_help.go`.

## Required parent wiring

Do not leave the normal binary unwired. In `internal/cli/table.go`, replace its final return with this exact line:

```go
return mergeLayers(registry, summarySpecs, txListSpecs, marketSpecs, transferSpecs, acctmgktSpecs)
```

No changes were made to `table.go`, `dispatch.go`, or `registry.go`. The build-tagged `acctmgkt_parity_overlay.go` merges these specs into an existing layer solely for real-binary parity measurement while respecting parent ownership. After parent wiring, the tag is unnecessary.

## Reference contract findings

The installed `/opt/homebrew/bin/dit` and `CommandsAccount.swift` agree, but differ from assumptions in the task:

- Account name is optional. Add prints `added account ...` and `id: UUID`, **not** a table. Duplicate nonempty names are rejected case-insensitively after trimming whitespace.
- Flags/options are `--taxable`, `--non-taxable`, and `--notes`; `--no-taxable` and `--note` are usage errors.
- Currency, taxable status, dates, number, name, institution, and notes remain editable with existing transactions. Currency edits do not rewrite transaction currencies.
- Close is a metadata edit: it accepts an account with cash/open positions, has no `--force`, and validates closed-before-opened dates.
- Add itself accepts closed-before-opened dates; edit/close reject that ordering.
- Delete requires `--force` for accounts with transactions, removes those transactions, and requires confirmation or `--yes`. Noninteractive refusal is exit 1; missing force is exit 2.
- Ticker has no `--source`. Default trading currency is unknown; show/add/edit/delete have deliberately distinct unknown-entry wording. Registry deletion leaves transactions untouched; only referenced entries require confirmation.
- `GBp` normalizes to GBP through the model's currency set, despite the error text mentioning GBp.

No speculative suggestions were added.

## Measurements and reproduction

Same final 65 probes, Swift-seeded store copied independently per side:

| Build | Identical | Differing |
|---|---:|---:|
| Original Go binary | 0 | 65 |
| Lane implementation, parity wiring | 65 | 0 |

Commands actually run:

```sh
go build ./...
go test -count=1 ./...
go build -tags acctmgkt_parity -o .build/ditgo-acctmgkt ./cmd/dit
ACCTMGKT_PROBES=1 GO="$PWD/.build/ditgo-acctmgkt" scripts/twin-run.sh
```

All gates passed. Tests completed without provider/network calls. The parity script compares stdout and stderr independently using `cmp`, retaining trailing newlines, and compares exit codes. It normalizes the different scratch paths and, only for successful account additions, independently generated UUIDs/unnamed-account UUID prefixes. Everything else is compared byte-for-byte.

Every nonzero-exit lane probe compares **both** store directories recursively against the pre-run seed using `diff -rq`. All passed; no failing command changed store bytes. The unit suite additionally checks complete file snapshots for 17 usage/runtime failures, closing/currency-editing accounts with positions, registry deletion retaining references, and ungrouped JSON quantities.

## Inherited date seam

`model.Account.OpenedDate` and `ClosedDate` use `model.Day`, whose decoder discards sub-day instants. Swift's default close date uses `Date()` rather than UTC midnight. The measured default-close output matches, but repeated same-day default close and edits of imported sub-day account dates are not covered by the 65 probes and cannot retain those instants through the current model representation. Full persisted-instant fidelity needs an account timestamp-preservation mechanism analogous to `model.Transaction.storedDate`/`decodedDay`; this lane does not change that shared model representation. All explicit YYYY-MM-DD date probes match.
