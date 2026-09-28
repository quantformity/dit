# Implementation logs

Running log of what was built, what was verified, and what was learned.
Phase definitions live in `docs/design.md`. Newest entries last.

---

## Stage 1 — Foundations & read stack (commits `f0411bc`…`89a5092`)

- `EquityTicker` registry (symbol-as-identity, name, trading currency,
  tags), lenient decoding; `Tag` normalized free-string labels.
- `DataStore` protocol + `FileDataStore` + `SQLiteDataStore` (system
  libsqlite3, no SPM deps) + `PortfolioStore` document layer;
  `DataStoreFactory` as the single config interpreter
  (flags > `DIT_BACKEND`/`DIT_STORE_URL` env > defaults).
- `AccountBalances` / `PortfolioSummary`: derivation of cash pools,
  positions (avg cost), GICs at par, realized/dividend/unrealized P&L;
  single-currency invariant documented.
- Market data: `QuoteProvider` protocol, `YahooQuoteProvider`,
  `MarketDataCache` with freshness gating, USD-hub routing for
  cross-currency display.
- `dit` executable: `summary`, `accounts`, `account show` first cut;
  `scripts/build.sh` copy-installs to `/opt/homebrew/bin/dit`.
- **Fixed en route**: default store path (SPM/macOS quirk:
  `FileManager.urls(for:)` returned `[]` → `homeDirectoryForCurrentUser`
  fallback, `240341f`).

## Stage 2 — CLI plumbing + full account management (commits `2342fc3`, `9f5c1fa`)

- Two-stage argument parser; globals (`--display/--backend/--store/
  --offline`) consumable anywhere; unknown options are usage errors;
  `--help` anywhere prints help instead of mutating; exit codes 0/1/2.
- `AccountRef`: exact name (case-insensitive) or UUID/prefix resolution;
  ambiguity never guessed.
- `dit account add/edit/show/list/close/delete`; destructive ops print
  impact first, require `--yes` on non-TTY.

## Stage 3 — Transaction ledger commands (commit `85ad0a0`)

- `tx list` (filters, deterministic sort, `--limit` keeps most recent),
  `tx show`, `deposit`, `withdraw` (currency override validated),
  `edit` (value-only; family rule: deposit↔withdrawal, buy↔sell refused
  as `kindChange` with delete+re-add guidance), `delete` with impact
  preview computed from one pre-computation.
- Library: `TransactionRef` (UUID or ≥4-char hex prefix, never guessed),
  `TransactionMutations` (validation, dangling-GIC-refund refusal,
  first-seen ticker auto-registration, overdraft recorded-with-warning,
  cash deltas mirroring the two-pool fx rule).
- Parser fix: opaque option (`--kind`, `--limit`) closes the
  command-word stream → `dit tx --kind sell` can't misdispatch.
- **Verified by smoke matrix** (scratch store, md5 before/after): every
  error path left the store byte-identical; GIC deletion restored cash
  exactly; unknown option / bad date / bad number → exit 2.
- Test suite grew 79 → 95 (swift-testing, 5 suites).

## Stage 4 — Transaction entry forms (commit `d6daa32`)

- `tx buy/sell/dividend/gic/gic-redeem/fx` implemented.
- Auto-fetch price from Yahoo when `--price` omitted; echoes what was
  recorded ("516.17 USD via yahoo"); hard error under `--offline` or on
  lookup failure (exit 1/2).
- Entry currency precedence: `--currency` > quote currency > registry
  ticker currency > account currency.
- `gic-redeem --gic` resolves product name (case-insensitive) or id
  prefix; a miss lists the account's live GICs (exit 1).
- FX needs explicit `--from-amount` + `--to-amount`; same-currency
  refused as usage error.
- **Model-honesty additions found by smoke-testing** (a demo oversell
  into −110 SHOP exposed that short liabilities vanished silently):
  - `AccountBalances.untrackedShorts` + `PortfolioSummary`
    `ShortSaleFlag`: sales below zero now surface as summary footnotes;
    the single-currency invariant explicitly carves them out.
  - Overdraft warning generalized from withdrawals to **every drained
    cash pool** (buys, GIC purchases, fx outgoing side).
  - Partial GIC redemption warns that redemptions are all-or-nothing in
    the model (remainder books as gone); a test pins that semantics.
- **Verified**: full smoke matrix on fresh copies of the demo fixture —
  fee-inclusive cost basis (NRG avg 40.80), auto-registration, oversell
  warning + footnote, dividend defaults, live MSFT fetch, offline guard,
  exact cash arithmetic after every command, error paths md5-clean.
- Test suite 104 tests, all passing.

## Verified platform/API facts (trust these; they cost time to learn)

- `Decimal(string: "180.00")` renders as `"180"` here — golden-string
  tests must match actual rendering, not input scale.
- `GICDetails.init` requires **all** params including `redeemable:`.
- `Transaction.init` puts `fee` **after** `kind`.
- Enum cases cannot be added in an extension here (the original
  `errorDescription` switch must stay exhaustive) — new `MutationError`
  cases go in the original enum.
- Static members need `Self.`/type prefix inside instance contexts.
- SPM test targets cannot import executable targets (why the CLI stays
  a thin shell over library logic).
- Product outputs land in `.build/out/Products/Debug`.

## Phase 5 — Ticker registry (commit `efb5de2`)

- `Portfolio` mutations: `addingTicker`, `updatingTicker`, `removingTicker`
  (new error cases: `tickerExists`, `tickerNotFound`, `tickerUnchanged`).
  Removal is ledger-safe: transactions keep the symbol text, so a
  referenced entry warns but stays deletable.
- CLI `dit ticker list/show/add/edit/delete(--yes)`, `--tags` parsing,
  9 new XCTest cases; smoke-verified add → collision → edit → unchanged
  rejection → tags clear → delete gate.

## Phase 6 — store / quote / polish (commit `8a9bf93`)

### Library

- `Portfolio.importing(_:mode:)` (StoreMutations.swift): single-account
  replace vs merge; validation: no account, >1 account, dangling accountID
  (all new `MutationError` cases); tickers upsert — existing registry
  entries are never overwritten by a file. 8 new tests.
- `PortfolioStore.keys()` passthrough in the middle layer.
- **Account name uniqueness** (found by the Phase 7 scenario, fixed in
  Phase 7): `addingAccount` and `updatingAccount(name:)` now refuse
  case-insensitive name collisions (`.accountAlreadyNamed`) — two
  same-named accounts made every name-based command ambiguous. 2 new
  tests.

### CLI `dit store`

- `path` (backend, location, document shape, keys), `export [--to] [--account]`
  (full or single-account JSON — the import format), `backup [--to DIR]`
  (timestamped copy of the file dir, or sqlite + wal/shm),
  `import FILE [--merge] [--force] [--yes]`: replace is the default and
  auto-backs up first (`--force` skips); merge dedups transactions by
  UUID and upserts tickers; malformed or multi-account files are refused
  before the store is touched; non-TTY replace requires `--yes`.

### CLI `dit quote SYM...`

- Live Yahoo table (symbol, price, ccy, as-of, source) via
  `YahooQuoteProvider`; partial misses are listed, exit non-zero only
  when nothing resolved; `--offline` refused (usage error) because the
  command *is* the fetch. Verified live: `AAPL 341.07 USD`.

### Polish

- `parseCurrency` unified for `--display`, `account add/edit`,
  `tx cash entries` (case-insensitive, `.unknown` rejected).
- `resolveAccount` wrapper: every account-ref failure now carries a
  did-you-mean hint (11 call sites), backed by a lightweight
  `didYouMean` (ci exact / substring / 2-char prefix).
- Soft, non-blocking hint when trade/dividend tickers are not in the
  registry (they still auto-register on first sight, as before).
- `store` + `quote` help sections written; `dit help` lists both groups.
- **Bootstrap fix (Phase 7's first item, done early)**: mutations on an
  empty store now bootstrap `Portfolio()` instead of erroring — `account
  add` works from nothing. Reads keep the friendly empty display.

### Phase 6 gotchas

- `FileManager.removeItem` on a non-existent path throws — guard with
  `fileExists` before deleting stale same-second backup targets.
- `store backup --to` for the file backend: the destination dir is
  created explicitly (the store dir itself is not the `--to` dir).
- Two `// MARK: - Helpers` occurrences in main.swift — anchor edits with
  surrounding context, never a bare MARK line.

## Phase 7 — Scenario / emulation (this commit)

- `scripts/scenario-e2e.sh`: 79 assertions playing one coherent user
  story against a fresh store — bootstrap from nothing, two accounts,
  registry, deposits, **overdraft recorded-with-warning** (exit 0),
  trades with explicit prices, **oversell recorded as a SHORT warning**,
  dividends (auto-register + near-miss), GIC buy + **partial redemption
  flagged** (all-or-nothing model), FX conversion, edit/correct
  (value-field yes, kind change no → usage error), ticker + account
  maintenance (referenced-ticker delete gate, rename-collision refusal,
  delete-with-ledger refused), offline summary / `--display`, store
  export → import (replace/merge/dedup/non-TTY gate) → backup, sqlite
  backend round trip, and the exit-code contract (0 success, 1 runtime,
  2 usage).
- Running the scenario found and fixed the account name-uniqueness gap
  (above) — the duplicate `account add` made every later command
  ambiguous; exactly the class of regression an E2E story should catch.
- One expectation corrected after observation: `--offline` + missing
  `--price` is a *flag contradiction* → usage error (exit 2), not a
  runtime failure.
- Exit codes verified end-to-end: 0 / 1 / 2 all land on the right
  commands; `--help` short-circuits before any mutation; `--yes`
  gates destructive ops on non-TTY.

### Final known gaps (out of scope, documented in the docs/design.md backlog)

- Redis backend, `report`/`reconcile`, `--json` output.
- Offline mixed-currency summary shows `—` (no invented rates); the
  account table could hint why.
