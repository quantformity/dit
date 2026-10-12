# txwrite lane

## Delivered

- `internal/cli/txwrite.go`: deposit, withdraw/withdrawal, buy, sell, dividend,
  gic, gic-redeem/redeem, fx, edit, delete/remove; `txWriteSpecs` registry.
- `internal/mutate/txwrite.go`: immutable add/edit/delete, validation, cash
  warnings, tracked shares, GIC resolution, deletion impact previews.
- Dashed uppercase version-4 UUIDs; existing short-prefix resolution remains usable.
- Unseen symbols auto-register; exact decimal arithmetic only. Quote lookup
  stays behind `provider.Provider`, with `DIT_PROVIDER_STUB` for every online test.
- One `store.SavePortfolio` per successful command, after all validation and
  confirmation. No save for cancellation, no-op, rejection, or lookup failure.
- Exact Swift transaction usage text, including usage-error stderr help.

## Parent wiring (required before shipping)

In `internal/cli/table.go`, replace its final return with this exact line:

```go
return mergeLayers(registry, summarySpecs, txListSpecs, marketSpecs, transferSpecs, txWriteSpecs)
```

No changes were made to table.go, dispatch.go, or registry.go. Consequently the
normal production binary still reports these writes as unported until the parent
adds that line. Parity below uses an opt-in **compiled Go lane test binary** running
these actual command functions; reads use the existing Dispatch. It does not use
Swift for Go writes. `DIT_TXWRITE_BINARY` is ignored by the production binary.

## Shared model additions

Only new files under `internal/model`: `txwrite.go`, `txwrite_test.go`.

- `TransactionInstant`: retain Date()'s subsecond reference-epoch instant while
  retaining the existing calendar-day projection for calculations.
- `TransactionDate`: explicit corrections clear a retained original instant,
  even for a same-day correction (Swift means UTC midnight).
- `TransactionStamp`: expose the preserved instant for correct replay ordering.

These are value-returning functions, not new manager types or backend methods.
No existing store implementation was changed; file rename and SQLite UPSERT are
already atomic saves. Tests cover model timestamp persistence, failed edits,
input/backing-array immutability, and both file and SQLite byte immutability.

## Measured gates

Executed in this worktree:

- `go build ./...`: pass.
- `go test ./...`: pass; no oracle subprocesses or network in ordinary tests.
- Original expanded twin suite: **20 identical / 54 differing** before;
  **66 identical / 8 differing** with lane implementation. Those eight remaining
  differences are outside the transaction-write probes: online summary negative
  zero, market history unported, export/backup path handling, bad-bundle wording.
  Online/default-suite observations are time/network-sensitive.
- Transaction-only probes added to `scripts/twin-run.sh`: **0 identical / 46
  differing before**, **46 identical / 0 differing after**. Includes all ten
  commands, overdrafts/oversells, unseen symbols, GIC redemption above/below
  principal, FX, same-value edits, invalid edits, unknown options, future/bad
  dates, missing amounts, noninteractive deletion, and destructive previews.
- `scripts/txwrite-parity.py`: **43 identical / 0 differing**. Captures stdout
  and stderr separately and compares bytes and exit codes. Starts the Go store
  through Go `store import --yes` of transaction-free account metadata, builds
  the entire transaction ledger through Go, compares accounts, tx list/filter,
  tx show for every entry, summary --offline, and market coverage against a
  separately Swift-written ledger. Repeats reads after edit/delete. Also compares
  persisted JSON facts. Random UUIDs and store locations are mapped between
  sides, not stripped indiscriminately. Explicit-date history is used; GIC's
  implicit purchase date is corrected with `tx edit` before redemption.
- Seven failing subprocess probes in that end-to-end suite compare **every
  Go store file byte-for-byte** with its pre-command snapshot. Unit tests also
  do this for the broader rejection matrix and SQLite databases.

Reproduce the lane binary and end-to-end run:

```sh
go test -c -o .build/txwrite-test ./internal/cli
DIT_TXWRITE_BINARY=1 GO="$PWD/.build/txwrite-test" python3 scripts/txwrite-parity.py
DIT_TXWRITE_BINARY=1 GO="$PWD/.build/txwrite-test" scripts/twin-run.sh
```

`TestMain` only enters executable mode when `DIT_TXWRITE_BINARY=1`; normal tests
run normally. Account creation belongs to another lane, hence the metadata-only
Go import bootstrap. No Swift sources or reference binary were edited.

## Oracle rules differing from the task's assumptions

The source and actual `/opt/homebrew/bin/dit` agree:

- Unknown account is runtime **1**, not usage 2; malformed numeric syntax is 2,
  but zero/negative cash-entry amounts and invalid edited payloads are runtime 1.
- Future dates are permitted. Date defaults to now except GIC accepts **no
  `--date` option** (unknown option / exit 2); correct its date with tx edit.
- Unknown tickers are accepted and registered, optionally printing a fuzzy hint.
- Insufficient cash and overselling warn but save; no holding is not a refusal.
- GIC redemption is all-or-nothing; lower proceeds warn, higher proceeds are
  allowed; purchase lookup includes previously redeemed purchases.
- FX has no entered rate or rate-sanity bound: positive measured amounts in two
  different known currencies are the validation contract.
- Edit preserves kind/account/ticker/currency. Redemption edits oddly ignore
  shares/price/maturity/compounding/product; this Swift quirk is preserved.
- A no-op edit literally says “already matches account <UUID>”, even for a
  transaction; that wording is preserved.

## Read-side seams needing parent action

The write/read suite found two pre-existing replay discrepancies. They cannot
be solved by changing transaction facts to fabricate earlier dates.

1. **Future events omitted by Go summary.** In
   `internal/valuation/value.go`, account replay's `if tx.Date > day { continue }`
   (around line 246) excludes future ledger facts, whereas Swift
   `AccountBalances.compute` replays the whole history. Repro: GIC purchased now,
   redeemed with `--date 2029-01-01`: Swift summary cash includes the redemption,
   GIC is 0, realized includes proceeds-minus-principal; Go summary omits it and
   retains the GIC principal. Required fix: remove the ledger-event day cutoff
   in that replay, retaining date cutoffs only where market observations require
   them. The successful explicit-history suite does not claim this is fixed.

2. **Same-day instants flattened in replay ordering.** Replace `.Date` ordering
   with `model.TransactionStamp(...)` ordering in
   `internal/ledger/statement.go` (`Ordered`, around line 38, and merged rows,
   around line 117), and `internal/valuation/value.go` (history sorter, around
   line 241). Keep stable storage order only when the actual stamps are equal.
   Repro: append a deposit with implicit now, then a withdrawal with explicit
   today's date: Swift orders the midnight withdrawal before the deposit; Go
   currently orders by append order because both project to the same Day.
   The new model accessor makes this change possible without exposing raw JSON.

Live implicit-price tests are deterministic pin-file tests on the Go side;
no byte-parity claim is made for fluctuating live quotes/network-error wording.
The reference Swift quote path does not implement the Go pin-file boundary.
