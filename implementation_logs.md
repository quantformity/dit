# Implementation logs

Running log of what was built, what was verified, and what was learned.
Phase definitions live in `design.md`. Newest entries last.

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

## Current state (start of Phase 7)

- Phases 1–4 implemented and smoke-verified; latest commit `d6daa32`.
- `ticker`/`store`/`quote` groups parse but respond "planned for a
  later release" (usage error), by design.
- Scratch fixtures: `/tmp/dit-demo` (pristine), `/tmp/dit-p3|p4|p4b|p4c`
  (smoke-scarred), installed CLI at `/opt/homebrew/bin/dit`.

### Known gaps to close in Phase 7 (scenario phase)

1. **Bootstrap gap (verified, unfixed)**: `dit account add` on an
   *empty* store exits 1 ("no portfolio found") — a brand-new user
   cannot start. Mutation commands on an empty store must bootstrap an
   empty portfolio (writes stay atomic; reads stay friendly).
2. Currency parsing: entry commands accept lowercase (`cad`), but
   `deposit/withdraw --currency` is strict — unify (case-insensitive,
   reject `.unknown`).
3. Summary of a mixed-currency account shows `—` for Cash/Total in
   `--offline` mode (correct by the no-invented-rate rule, but the
   account table should hint why).
4. No end-to-end scenario harness yet — Phase 7's `scripts/scenario-e2e.sh`
   will assert the full "from nothing → multi-account, cross-currency,
   edit/delete, edge-facts" story against the installed binary.

### Next

- Phase 7: bootstrap fix + scenario script + run + verify (this phase's
  deliverable is a *green scripted run*, not new commands).
- Phase 5 (`dit ticker`) and Phase 6 (`dit store`, `dit quote`, polish)
  after it.
