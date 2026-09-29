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

## Phase 8 — market-data store & update commands (2026-09-28)

### What was built

- **Second store, same cascade**: `MarketStore` (middle layer above the
  existing `DataStore` protocol) persists ONE atomic `market` document —
  latest snapshots + per-asset daily series — in its OWN backend:
  a `market/` directory or `market.sqlite` beside the portfolio store,
  relocatable via `--market-store` / `DIT_MARKET_URL`. Prices never
  enter the portfolio document; wiping quotes cannot touch the ledger.
- **`dit market latest`**: fetches current prices for symbols with open
  positions only (reuse of `marketDataPlan`) plus needed FX pairs; the
  store keeps one latest snapshot per symbol, overwritten per run.
- **`dit market history [--all]`**: daily closes fetched per (symbol,
  day-that-symbol-was-held) — holding windows derived by replaying the
  ledger, merged across accounts. Incremental by default: each series
  carries a coverage watermark, requests start strictly after it, and
  a successful fetch advances it (holidays never refetch). `--all`
  wipes the series first.
- New files: `MarketStore.swift`, `MarketUpdate.swift` (windows,
  updater, injected `PriceDataProvider` + Yahoo daily-series fetch),
  14 tests incl. a stub provider that asserts *which ranges were ever
  fetched*; scenario suite unchanged at 79/79.

### Errors found and fixed during testing (before any live run)

- A "weekday coverage" incrementality test would have refetched every
  holiday forever; replaced by the watermark rule.
- Window merging assumed chronological arrival — broken by cross-account
  ordering; now sort-then-merge.
- FX window initially keyed on the quote currency (found via a failing
  test that expected `USDCAD=X` fetches).

### Known data quirks found on the real portfolio

- Yahoo has no daily series for NEO tickers (`TSLA.NE` &co → one point
  only; latest prices DO work). A ticker-alias or NEO source is the
  follow-up if the 3.9%-of-portfolio NEO positions matter historically.
- Live store filled 2026-09-28: 19 series, ~6,900 daily points in ~1.5 s.

## 2026-09-28 — Phase 8b: derived history (`ticker backfill`, `market import`)

The NEO answer arrived as data, not a source: `history_cache.db` proved
.NE trackers ride their underlying × FX ÷ a fixed ratio (Sept 2026
spread ≤ 0.85% per tracker), and TSLA.NE/GOOG.NE Jan-2025 cost bases
agree with that model to ~3% across the whole window. NVDA.NE's does
not (cost implies ratio 4.85 vs observed 6.31 — either an older purchase
price or genuine decoupling), so the tool reports calibration spread
and the user decides.

- New command `dit ticker backfill <target> --from <source>
  [--ratio R] [--dry-run]`: calibrates the ratio as the MEAN of
  `source × FX ÷ target` over days where both were really observed
  (stored real closes + today's live quote, deduped by day), then
  fills weekdays without a real close inside the target's holding
  windows as `source(close, same day) × FX(on-or-before ≤ 3d) ÷ ratio`.
  No same-day source → the day stays honestly empty (counted, reported).
  Same-currency derivations skip FX entirely. Calibrated spread > 2%
  prints a decoupling warning. Works offline when the source history
  is already stored; otherwise fetches the missing source/FX series
  first (network required then).
- Provenance: `DailyPrice.via` — nil means OBSERVED. Real never
  silently coexists with derived: `merging` (provider/import path)
  replaces derived points with real ones and refuses to let anything
  replace a real point. Re-running backfill recomputes model points
  (idempotent: identical inputs → "unchanged", zero writes) and keeps
  every real close.
- New command `dit market import FILE [--dry-run]`: CSV
  `SYMBOL,YYYY-MM-DD,PRICE`, seeds real observations (used to load the
  3 real .NE closes per tracker before calibrating); `market show`
  grew a Source column and marks derived tail values.
- Live run (after rehearsal on a full copy of the live store): seeded
  9 real closes, then backfilled TSLA.NE/NVDA.NE/GOOG.NE — 431
  derived days each, calibrated ratios 16.2645 / 6.315 / 8.8386, 20
  empty weekdays per series (US market holidays — the empty-day rule
  working). Verified 431/431 derived points match exact Decimal math
  against the stored source series (first "mismatches" were checker
  artifacts: float double-rounding and a stricter-than-engine FX rule).
- Tests: `BackfillTests` 9 cases (exact-math asserts, idempotence,
  offline refusal, fetch-when-missing asserting request ranges,
  provenance merge rules, pre-`via` document decode) → 109 XCTest +
  106 swift-testing green; scenario-e2e extended with an offline
  backfill story → 98/98.

### Phase 8b follow-up: provenance flag on quotes (`dit quote --as-of`)

- `dit quote SYM [--as-of DATE]` — without `--as-of` behaves exactly
  as before (live Yahoo, Source column = provider). With `--as-of`
  (works under `--offline`): reads the market store, no network, and
  flags each answer `observed` (a real fetched/imported close),
  `backfilled — derived via …` (a backfill model value), or nothing.
  Weekend/holiday dates fall back to the nearest earlier close with an
  "Nd earlier" marker; all-missing exits 1, partial misses are listed.
- New `MarketData.point(onOrBefore:for:)` — the provenance-carrying
  lookup (`price(onOrBefore:)` now delegates to it).
- Verified live: observed Sept-17 close vs March-11 backfill vs Sunday
  fallback vs the USD/CAD pair; scenario suite 107/107, units green.

## 2026-09-29 — account `--history`, currency-labelled values, one-day P&L

- `dit account show <account> --history` (committed b5c7dca first): the
  account's full ledger, oldest first, with 8-char tx IDs; offline by
  construction; empty accounts print "no activity recorded". +4
  scenario checks.
- Holdings `Value` cells now carry the trading currency (`CAD 1,000.00`);
  mixed-currency portfolios gain `Value (<display>)` — the converted
  figure, dashed (never invented) when no FX rate exists, hidden when
  every position already trades in the display currency.
- One-day P&L: a `Day change` line, a `Day` column in By-currency and
  Accounts, and `Day`/`Day%` in Holdings. Contract per the user: latest
  quote compared against the PREVIOUS AVAILABLE market-data date —
  `MarketData.point(strictlyBefore:for:)` (the quote's own day is never
  its own baseline), no staleness cap, no carry-forward of cost basis:
  no pair → dashed column absent, never a fake 0.00.
- Plumbing: `DayPricePair` (current/previous/modelBaseline) feeds both
  `AccountBalances.compute` and the holdings pass; pairs are accepted
  only when `current` equals the price actually used, so a day figure
  can never compare observations that never entered the summary.
  Native-currency accumulation throughout (FX never masquerades as
  trading P&L); combined values convert once, nil when unconvertible.
- Derived baselines stay labelled: the footnote names tickers whose day
  move is model-vs-live through a backfilled proxy.
- Tests: +1 store lookup, +3 summary math (exact Decimal day totals,
  mismatch-pair refusal, same-day exclusion), +3 renderer shape checks
  (mixed table, unconvertible dashes, no-history keeps old layout).
  Suite now 110 XCTest + 113 swift-testing, scenario 111/111.

## 2026-09-29 (2) — Holdings money columns in the display currency

- Per request, Holdings `Day` and `P&L` now show PORTFOLIO REPORTING
  (display) currency: `Day (CAD)`/`P&L (CAD)` (dynamic with
  `--display`), converted at the current FX rate, dashed when there is
  no rate or no quote — never a silent native-currency leak, which the
  old unlabeled native cells were for USD rows (a second fix of the
  "unmarked number" problem the Value change addressed).
- Native values stay in the model (`dayChange`, `unrealizedPnL`) and
  feed the % columns: `Day%`/`P&L%` remain native-currency ratios by
  deliberate contract, so FX drift never masquerades as trading gain
  and the percent always reconciles with the native cost basis. A
  footnote states the split whenever currencies mix. Converted money
  + native % means a USD row's CAD P&L ≠ P&L% × cost in CAD — that is
  intentional (FX is in the $ but not the %); documented in cli.md.
- By-currency/Accounts `Day` columns stay per-row currency (exact
  layer; Accounts follows each row's reporting currency like its other
  $ columns).
- New fields: `unrealizedPnLInDisplayCurrency`,
  `dayChangeInDisplayCurrency` on `TickerHolding` (display layer only;
  the exact layer is untouched). +3 assertion groups; 113+110 units,
  111/111 scenario green; live-checked against Sept-28 closes.

## 2026-09-29 — Machine-readable output (`--json`) + `market backfill` rename

- New global `--json` flag (position-independent, takes no value). For
  `summary`, `accounts`, `account show [--history]`, and `quote
  [--as-of]` stdout becomes exactly ONE JSON document — on success AND
  on errors (envelope `{"ok":false,"kind":…}`); every other command
  refuses it as a usage error (exit 2). Exit codes unchanged: 0/1/2.
- Contract (docs/json.md, pinned by JSONOutputTests + e2e section 15):
  financial amounts are decimal STRINGS; `null` is "no data", never
  zero; native-currency figures and `*Display` conversions are
  separate fields; percentages are native-currency ratios; provenance
  is data — `via: null` means observed, non-null names the model
  (backfill), and `quote.previousClose` is always present so
  provenance lookup never branches on key existence. `--history`
  carries FULL 36-char transaction ids (tables truncate to 8).
- `dit ticker backfill` is now `dit market backfill`: the command
  writes the market store, not the registry, so it lives with
  `latest/history/import/show`. Old name removed (usage error), help,
  docs, and the scenario script updated.
- Test counts: 230 units (110 XCTest + 120 swift-testing), scenario
  e2e 130/130 (offline by design; the JSON checks assert pure-document
  stdout via python3 json parse + provenance labels as data).

## 2026-09-29 — Human tables for `dit market`

- `market latest` and `market history` stop printing ragged one-line
  prose: the update engine now returns structured rows (LatestRow /
  HistoryRow) and the CLI renders them with the shared aligned-table
  renderer. Prices and timestamps line up column to column.
- A `history` run where NOTHING was fetched collapses to one summary
  line ("all N series are covered…") instead of a wall of identical
  "skipped" rows; the table appears exactly when something happened,
  including mixed skipped/fetched runs.
- `market show --symbol X` now filters BOTH tables (Latest + History),
  says "nothing stored for 'X'" honestly, and uses the compact
  "YYYY-MM-DD HH:mm" timestamp (shared helper, local time — the
  machine contract's UTC ISO form is unchanged).
- `Table.render` trims trailing padding on lines whose last column is
  left-aligned (whitespace noise in diffs/wrapping).
- e2e +2 checks (filter narrows, filter honesty): 132/132; units
  unchanged at 230, with three assertions moved from prose lines to
  structured rows.
- Follow-up (same day, per request): `market history` now ends with a
  COVERAGE table — Ticker / Earliest / Latest / Quotes (stored points
  per series, post-update) — with newly fetched points called out in
  one line above. HistoryRow carries coverage (first/last/count/added)
  instead of "skipped" prose; every managed series gets a row, empty
  series show "— — 0" honestly. Quiet runs repeat facts, which is
  allowed; walls of identical words are not.

## 2026-09-29 — history fill modes: `--all` no longer erases

- `dit market history` gained `HistoryFillMode`: default is still the
  watermark-paced incremental fill; `--all` now RE-VERIFIES every
  holding window and merges (fills gaps the watermark had walked
  past — real closes are never replaced, only real replaces derived);
  the erase-and-refetch behaviour moved to `--rebuild`. Using both
  flags is a usage error (exit 2).
- Watermark honesty unchanged: a quiet incremental run still re-fetches
  nothing; refill proves it in `testHistoryRefillFindsGapsTheWatermark
  WalkedPast` (quiet run = zero provider requests for a covered
  window; refill = full-window request, 8 gap days added, stored real
  close survives).
- Units now 231 (111 XCTest + 120 swift-testing), scenario 132/132.

## 2026-09-29 — `dit quote --from/--to`: historical series printing

- `dit quote TSLA TSLA.NE --from 2026-09-01 [--to 2026-09-30]`
  prints every STORED close in the inclusive window, one aligned
  table per symbol (Date | Price | Provenance), oldest first. No
  network, works with `--offline` — same store-read contract as
  `--as-of`. `--from` alone runs to today; `--to` alone starts at
  the earliest stored day; `--to` before `--from` and mixing
  `--as-of` with a range are usage errors (exit 2).
- Human output: missing symbols listed, all-missing exits 1; no
  points are invented for empty days.
- Machine output: `--json` gets `quote/1` mode `"series"` (flat
  dated points, `count`, open bounds as null, missing symbol = one
  `basis:"none"` marker) — the single-document contract holds for
  every quote mode.
- New: `MarketData.points(from:to:for:)` (sorted, inclusive,
  open-ended), `JSONOutput.seriesQuotesJSON`; +3 unit tests and 9
  scenario checks (231+3 units, 144/144 scenario).

## 2026-09-29 — FX in `dit quote`

- Live FX worked only accidentally before: "USD/CAD" was sent to the
  equity endpoint and answered "(none)". Pairs (both sides ISO codes)
  now route to the rate endpoint — live AND from the store — and mix
  freely with stocks (`dit quote AAPL USD/CAD`).
- Direction contract: a pair price is QUOTE currency per 1 BASE
  (USD/CAD 1.4183 → 1 USD buys 1.4183 CAD); CAD/USD is the same pair
  read reciprocally. `--json` emits FX at 6 places (rates are not
  money — cent-rounded rates are different numbers).
- `ExchangeRate.pairRequest(for:)` + parsing tests; docs/cli.md and
  docs/json.md updated.
