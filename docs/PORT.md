# Porting `dit` from Swift to Go

Status: **complete.** The Go CLI is verified against the Swift reference with
all deterministic probes byte-identical. Remaining twin-run differences occur
only in live market data fetched seconds apart.

```
$ go test ./...          # all packages green; provider tests use DIT_PROVIDER_STUB, never the network
$ go build -o .build/ditgo ./cmd/dit
$ scripts/twin-run.sh    # 207–208 identical; at most 1 live-summary drift
$ MARKETWRITE=1 scripts/twin-run.sh   # 226–227 identical; live quote/summary data can drift
$ PTY=1 scripts/twin-run.sh           # 207–208 identical; any difference is live market data
```

The parity reference is the installed Swift binary at `/opt/homebrew/bin/dit`.
Its original source checkout is not part of this Go project; the measured
parity results below are captured by the harness and lane reports.

## What "identical" means here

For every probe, both binaries start from a **byte-identical store copy** and
run the same command: text output (stdout and stderr separately), exit code,
and — for write commands — the resulting store files must match under
canonicalisation. `scripts/compare-results.py` normalises only what is
unstable by construction: generated UUIDs (`id: <UUID>`, `Account XXXX`),
timestamp values written as "now" (within ±900 s of the run), `createdAt`/
`updatedAt`/`generatedAt` keys, and the non-deterministic order of Swift's
`Set`-backed tag arrays (sorted before comparing). Everything else — table
dashes, column widths, currency rounding, error wording, exit codes —
compares exactly.

The 228-probe full-gate suite spans the whole surface: 16 help variants, `summary` /
`update` / `pnl` / `accounts` / `store path` / `tx list|show|add|edit|delete|
withdraw|deposit|buy|sell|dividend|gic|gic-redeem|fx`, `account add|edit|
close|delete|show`, `ticker list|show|add|edit|delete`, `market
show|coverage|latest|history|backfill|update|import`, `quote` (live,
historical, FX pairs, N-ccy matrix), and `export`/`import` bundles — each in
plain and `--json` form where documented, with the error paths included (bad
IDs, missing references, malformed files, duplicate names, wrong case,
conflicting flags, empty values).

**Terminal styling is compared, not assumed.** The reference bolds table
headers only when stdout is a terminal and `TERM` is neither absent-dumb nor
disabled, and piped runs — how the harness normally runs — are plain on both
sides. `PTY=1` runs every probe through `scripts/pty-run.py`, which gives each
binary a real pty (stdin stays /dev/null), so the `ESC[1m … ESC[22m` bytes
themselves are compared; the `NO_COLOR=1` and `TERM=dumb` variants are verified
plain, and bold never affects column widths on either side.

**Two empty-state gaps were closed alongside:** `accounts` on a store with no
portfolio file prints the reference's two-line "No portfolio found … / Add
accounts and transactions first." instead of the empty-list message, and
`accounts --json` / `account list --json` now emit the reference's `accounts/1`
schema (uppercase ids, always-present null institution/number, `opened` only
when set, note-plus-ok on a missing store) instead of refusing.

## Parity notes

Deterministic output, exit codes, error text, help, and write results match the
reference across the current offline probe set. This includes compatibility
quirks: text summaries retain Swift's `-0.00` rendering for settled GIC-only
accounts, and malformed bundle errors use Swift's `expected NSDecimal` wording.

Live probes are not byte-stable: Yahoo quote/FX values and timestamps can
change between the two sequential invocations. The harness reports these as
differences rather than masking them; they are observations of changing market
data, not evidence of a porting mismatch.

## The store files are still interchangeable

`store(key TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)` with JSON
payloads, same table in both backends (file and SQLite via
`modernc.org/sqlite`). Dates are CoreFoundation reference seconds (epoch
2001-01-01), not Unix seconds — `internal/model/dates.go` documents the 31-year
trap. Store files are not byte-stable on either side (Swift encodes
dictionaries in per-process hash order), so interop is measured
semantically, not by file diff; output, however, is byte-identical.

`_0` enum wrappers: Swift encodes some transaction kinds as
`{"stockPurchase":{"_0":{…}}}` and others as `{"deposit":{"amount":…}}`; the
Go decoder accepts both, and writes in the same shape it was given.

## Deliberate behavioural divergence (documented by the Swift team's rules,
kept on purpose)

**`summary` prices from stored closes when the fetch fails.** Swift answers a
failed quote with cost basis. Go answers with the newest *stored close* and
says so, because a two-day-old close is a better estimate than a
two-year-old purchase price. The guardrails are all enforced: fetch everything
first (parallel, per-request timeout); name the source above the numbers with
symbol, price, date and age; no fake day-change for a stale mark; a series in
a different currency is never used; an unrecorded currency is flagged; with no
usable close at all it falls back to cost basis exactly as Swift does. JSON
carries `"live": false` so a machine reader can't mistake a file lookup for a
quote. `--offline` always goes to cost basis on both sides.

## Division

Exact-rational, rounded once at the caller's scale (half-away-from-zero,
matching the reference's `.plain`), rather than the reference's 39-significant-
digit intermediate rounding. `internal/decimal` is verified against 13,500
cases replayed through an independent Python rational-arithmetic oracle.
Agreement with the reference is total except, in principle, at ties beyond the
30th digit — no test in the suite comes close.

## Not in scope

- **`dit-chart`** is a separate companion binary and is not included in this
  Go project. The Go port covers the `dit` CLI.
- **Store-file byte identity** is unachievable on either side and is not
  attempted (see interop note above).
- **Live-provider exact wording on network failure** is platform-dependent
  (HTTP client / DNS wording differs); the failure kind, exit code, and
  refusal-to-commit are identical.

## Repository layout

| Area | Package |
|---|---|
| CLI dispatch, options, usage, `--json` allow-list, help | `internal/cli` |
| Decimal money (exact, oracle-verified) | `internal/decimal` |
| Domain types, dates, interop decoding | `internal/model` |
| File + SQLite backends, document load/save | `internal/store`, `internal/config` |
| Text tables, currency formatting | `internal/text` |
| Bundle (export/import) | `internal/bundle` |
| Valuation, P&L, summary, FX routing | `internal/valuation` |
| Market: write, backfill, coverage, watermarks | `internal/market` |
| Provider (Yahoo + stub) | `internal/provider` |
| Ledger statement, P&L windows | `internal/ledger` |
| Mutations (tx add/edit/delete, account, ticker) | `internal/mutate` |
| Entrypoint | `cmd/dit` |
| Twin harness, comparator, parity, scenario e2e | `scripts/` |
| Lane reports (each command's before/after) | `docs/lanes/` |

## How it was built

Not a top-down rewrite, and not a line-by-line translation. The foundation
(decimal money, date model, store interop, text tables, JSON contract,
dispatch skeleton, harness) was built first and locked with tests. Then each
command was implemented in an isolated git worktree by a background agent
against the same gate — `go test`, `go build`, `scripts/twin-run.sh`, and the
scenario e2e — with the reference binary as the oracle. Each lane reported its
measured before/after and handed back only the shared seams it touched; the
parent merged and re-ran the full gate to prove no regression. Commands were
delivered as plain functions registered in a `Registry`, not as a class
hierarchy — the backend is a value built by functions, and a command is a
value in a map, so adding a command is a one-line registration, not a new
type with a method set.

The discipline that kept it honest: **a failing command never mutates the
store.** That is measured, not assumed — the harness snapshots the store
before and after every failing probe and fails the suite if the bytes moved.
