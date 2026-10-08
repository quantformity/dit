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

## 2026-09-30 — Refactor sweep: one formatting brain, one replay order, split CLI

- Behaviour-preserving cleanup only; verified by capturing every offline
  output (summary, statements, histories, charts, help screens, JSON docs)
  before and after — byte-identical except wall-clock timestamps.
- `TextFormat.swift` (library): the ten hand-rolled NumberFormatter /
  DateFormatter spellings collapse into named primitives. DISPLAY text
  (grouped) and MACHINE text (plain, docs/json.md) stay separate families;
  `day`/`isoStamp` are UTC, `clock`/`minuteClock`/`localDay` are the local
  display kinds. SummaryRenderer, JSONOutput, MarketUpdate, TransactionDisplay
  and the CLI now delegate; ChartRenderer keeps its own moneyLabel because
  its round-then-print contract differs on purpose.
- `Replay.ordered` (library): the stable "date, then storage position" sort
  existed in four places; now it exists in one, and every listing that shows
  derived state shares it.
- `Portfolio` gains `accountName(for:)` (dash for a vanished account) and
  `trackedSharesHeld(accountID:symbol:)` for the SHORT warning — deliberately
  unclamped, unlike AccountBalances' position view.
- `Sources/dit/` splits from one 3,013-line main.swift into main (dispatch),
  Support (errors/options), HelpText, five command files, and Helpers
  (shared parsing/lookup rules). Command bodies and help bytes unchanged;
  dedent keeps multiline-literal output byte-stable because strip is
  relative to the closing delimiter.
- Dead `requirePortfolio` removed on the way.
- Tests: +9 (TextFormat contracts, replay determinism, Portfolio helpers);
  137 XCTest + swift-testing pass, e2e 190/190.

## 2026-09-30 — Docstring pass + tables switch to Markdown format
- Every public type, method, init, and non-obvious property in the
  library now carries a doc comment; CLI command functions and shared
  helpers got one-line purpose docs. Doc-only change, verified with
  the full suite.
- `Table.render` switched from space-separated aligned text (with a
  `─` rule) to Markdown pipe tables: `| cell | cell |` + a
  `---`/`---:` separator rule, padded to column width. Raw terminal
  reading keeps its alignment; piping into (or pasting into) a
  Markdown viewer now yields a real rendered table. Pipes in data are
  escaped (`\|`); alignment markers (`---:`) keep money columns
  right-aligned in both worlds.
- Deliberate: no `--md` flag. Markdown is the default table style,
  not a mode; `--json` stays the machine contract and never carries
  table syntax.
- Fixed a pre-existing docs drift found on the way: docs/cli.md
  advertised INR/SGD (not in the Currency enum) and omitted AUD/NZD.
- e2e: the `txid` helper scraped the first whitespace field of the
  old space tables; it now parses the first pipe cell. 190/190 after.

## 2026-09-30 — tables settle on the full-grid style (supersedes the pipe experiment)
- The same day's Markdown-pipe switch was superseded before release:
  `Table.render` now emits the full Unicode grid — `│` column walls,
  `├─┼─┤` between every pair of rows, `└─┴─┘` bottom edge — matching
  the tabulate-style layout asked for. Rule segments span cell width
  + padding so every ┼/┬/┴ joint lands exactly on a row wall.
- Vertical bars in data render as broken bars (`¦`) so a value can
  never tear a grid wall; alignment lives in the padding (labels
  left, money right), not in a separator marker.
- The two script parsers (e2e `txid`, `import-investments.sh` GIC
  lookup) key off the grid's shape — a data row's ID is the 8-hex
  field after the `│` wall — so they are format-proof against
  further style changes. 190/190 + full unit suite green.

## 2026-09-30 — `dit pnl`: windowed historical P&L (library + CLI + e2e §19)
- New read path `PnLWindow` (library) + `dit pnl` (CLI). Pure store
  read, never network. Window forms: default = FULL ledger, `--horizon`
  (Nd/Nw/Nm/Ny/ytd), or explicit `--from`/`--to`; mixing forms is a
  usage error (exit 2). Window semantics: ledger events with
  FROM ≤ d ≤ TO are the window; the baseline price is strictly BEFORE
  FROM. Default starts at the first trade, where holdings sit at cost,
  so the default report needs no baseline price and is exact.
- P&L stays decomposed: `Realized` (ledger truth: sale over
  proportional cost, dividends net of fees, GIC redemptions over
  principal — mirroring AccountBalances, including the
  redemption-without-purchase skip) and `Position Δ` (mark-to-mark
  across the window). `Total` only when BOTH are known; realized-only
  hides real drift, a half-known sum is worse than a dash.
- Two-boundary replay: state is replayed strictly-before-window and
  through-window-end; the window's realized is the DIFFERENCE of the
  two, so slices reconcile with full history by construction.
- Drift-only stories appear (a position that merely drifted is the
  window's P&L); quiet zero-drift positions do not. Shorts created
  inside the window are flagged, not silently valued.
- Series currency rule: exact match trusted; UNLABELLED imports are
  taken at face value in the position's currency; a series explicitly
  in another currency is never used. Combined totals require every
  currency complete AND every rate stored (latest rates + FX pair
  series both seed the rate closure); otherwise withheld.
- Fixed on the way: `parseDate` now round-trips, so impossible dates
  like 2026-02-30 exit 2 instead of silently rolling to Mar 2.
- `--json` emits `pnl/1` (docs/json.md): nulls for unmeasurable,
  fixed-scale strings, `basis` observed/derived/null. `dit-chart`
  refuses `pnl/1` (exit 1) until a chart shape is designed — refusal
  is the honest default.
- e2e §19 pins the math (July window: realized 22 + drift 5 = 27)
  and the dash/withheld semantics across 52 new checks: 242/242.

## 2026-10-01 — `--time-series`: the window sliced into periods
- `dit pnl --time-series` prints one row per period × currency. Each
  period is one `PnLWindow.compute` call with its own baseline close
  (strictly before the period start) — a view over the SAME engine,
  not a second P&L model.
- Buckets are contiguous by construction (the monthly walk starts at
  the first of the month, weeks chain from the window start), which
  is what makes drifts telescope: Σ period drifts = window drift
  whenever every slice is measurable. The renderer asserts it:
  "Σ periods = window total (exact)" or "Σ ≠ … GAPS, not zeros".
- Period size auto-picks (monthly >8 weeks, weekly >10 days, else
  daily) and is always labelled; no hidden parameters.
- Empty vs unmeasurable stays a real distinction: truly quiet periods
  (no booked facts, measured-zero drift) collapse with a counted
  note; periods with NO price pair are counted separately and break
  the reconciliation — "nothing happened" is a fact, "nothing is
  knowable" is a data gap, and neither may render as 0.00.
- JSON: `--time-series` adds `data.series` (points keep the null
  contract; `reconciles` is the integrity flag for machine callers).
- e2e §20: 19 checks pin the identity (10 + 41 = 51 on the fixture),
  the auto-granularity labels, quiet/dashed windows, `--time-series=false`,
  and JSON reconcile flags both ways. 261/261 + 163/112 unit tests.
- Added `--daily` (modifier of `--time-series`): forces daily periods
  at any window length, header marked "(forced)"; alone it exits 2 —
  same no-mix discipline as horizon/dates. Identity is
  granularity-independent: dense-fixture daily slices still sum
  exactly (27.00 == window total, unit-tested); the real store's
  sparse history correctly REFUSES the sum and names its 2
  unmeasurable gaps. 269/269 e2e (8 daily checks), 164 unit tests.

## Entry 14 — 2026-10-01 — one reporting currency; FX as a CLOCK, not a snapshot

`dit pnl` now speaks ONE currency in text (reporting currency —
`--reporting-ccy`, default `--display`, else CAD). The native
per-currency table is gone from text (it stays byte-exact in
`--json`); rows carry a `From` column naming each ledger currency.
`--reporting-ccy` is a runtime display choice only — it never
rewrites a stored account/portfolio reporting currency.

The conversion is HISTORICAL, and this was the design line: the
latest-snapshot rate is deliberately NOT a source anymore. A new
`FXClock` (Sources/DirectInvestTracker/FXHistory.swift) reads dated
FX pair series only — the last close on/before the date a figure
belongs to (window end for the plain view; each period's own end for
`--time-series` — "a June slice never wears July's rate"). Legal
paths: direct pair, inverted twin (reciprocal, labelled), USD-hub
triangulation (marked derived). Closes older than a week are
REFUSED, not stretched; missing means DASH. Today's rate was used
for June's P&L before this change — that counted as a mixed view;
it is now recognised as a disguised guess and is gone.

Markers: `*` derived price history (unchanged), `~` FX from an
earlier/derived rate — legends always print; the real store's 2025
series shows it (May/Nov month-ends backdate to a Friday).

Time-series honesty chain updated: the telescoping identity stays a
NATIVE check (cross-currency sums are display, not arithmetic), so
the footer distinguishes three facts — "Σ = window (exact, same FX
throughout)", "Σ ≠ window in CAD — FX TIMING; native slices still
add exactly", and the GAPS refusal. The flat-rate e2e fixture proves
the first (converted 14.00 + 57.40 = 71.40 = 51.00 × 1.40); the
real store exercises the second (USD→CAD drifted 1.44→1.37 across
2025).

JSON stays additive: native fields untouched; rows/totals gain
`reported` triples converted at the dated FX (only where conversion
is involved), series points gain `reportedTotal`, `combined` gains
`at` + `rates` (real example: "USD→CAD 1.4247 at 2026-10-01").
Real-store cross-check: default total prints 409,500.13 CAD — the
honest single-currency answer to the user's 409,527.13 mixed-units
sheet sum; `--reporting-ccy USD` correctly converts CAD rows via
the inverted USD/CAD series ("0.7137 … 1d earlier, inverted").

Tests: FXHistory suite (7), conversion test now pins staleness
refusal, e2e §19/§20 reseeded with a dense flat USD/CAD history
(default-window checks pinned to --to 2026-10-01 so script runs
stay date-proof). 275/275 e2e; 171 swift-testing + 112 XCTest.


## Entry 15 — `dit market coverage`: auditing data gaps before reports dash on them (Oct 1 2026)

The single-currency P&L can now DASH whole periods (no usable FX at a
boundary) and DASH position-change columns (no price pair). Coverage
closes the loop: a read-only, offline audit answering "for what my
ledger holds, what does the market store KNOW — and where would a
report have to dash?" No second financial model: it reads the same
sources the reports read (daily symbol series, FXClock chains) and
prints facts only.

Decisions worth keeping:

- **Per-symbol data-need windows.** The first version scanned gaps
  from the LEDGER start; on the real store it screamed "GAPS 482d"
  for VRT, whose series starts exactly on the buy day — a fabricated
  finding. Now each row checks from the first ledger event that
  references it (buy/sell/dividend for prices, first event expressed
  in the currency for FX). Darkness before anyone traded is nobody's
  gap.
- **Gaps ≥ 10 days only.** Weekday-sampled series always lack
  weekends; holiday clusters run to 8-9 days. Shorter runs are
  calendar dust — listing them would hide the real holes.
- **Wrong-currency is a stated fact, never a green check.** A CAD
  position whose only series is USD-cleared is never used by the
  reporting views (FX honesty rules); coverage names it WRONG CCY
  with the reason, so nobody mistakes "data exists" for "data used".
- **FX coverage = CHAIN + FRESHNESS, per reporting boundary.** A
  chain of 8-month-old legs exists but converts NOTHING (the FX
  clock refuses it) — reported STALE, with the refill remedy, not
  the import one. Convertibility is checked at every period-end the
  `--time-series` slicing would use, so what gets reported is
  exactly what a real report would dash on.
- **Strict is opt-in.** Default exit is 0 (it is a report, like
  `quote` range); `--strict` flips exit 1 when rows have findings,
  and `--json --strict` keeps the single-document contract (the
  finding lives in `"complete":false`; strict only flips the code).

Also fixed on the way: `main()` now sets stdout LINE-buffered
(`setvbuf(_IOLBF)`) — with block-buffered stdout and unbuffered
stderr, merged captures (`2>&1`, the e2e harness) interleaved the
two streams mid-line, corrupting grid rows; the §21 strict check
caught it by refusing to match an error message that WAS being
printed, just shredded. Streaming hygiene, same family as the
render honesty rules.

Files: `MarketCoverage.swift` (new lib audit: SymbolCoverage,
FXChainCoverage, CoverageReport, `MarketCoverage.report`),
`marketCoverage` + cell renderers in `CommandsMarket.swift`,
dispatch + json-schema gate in `main.swift`, help text, 11 unit
tests (MarketCoverageTests), e2e §21 (a fixture carrying one
instance of every fact class — dense, inside-hole, dead series,
missing series, triangulated chain, no-path chain). Counts: 182
swift-testing + 112 XCTest, 324/324 e2e.

## Entry 16 — 2026-10-01 — the project becomes `dit`

Renamed everything that carried the old name: package `DirectInvestTracker`
→ `dit`, library module → `DitCore` (Sources/DitCore/, Tests/DitCoreTests/),
workspace folder `DirectInvestTracker2` → `dit`. The CLI never had a long
name — the binary, docs, and now the package all agree on `dit`.

The default store path moved to `~/Library/Application Support/dit`, but
READ-ONLY COMPATIBILITY was the hard requirement: when `dit` does not exist
and a pre-rename `…/DirectInvestTracker` folder does, the factory resolves
to the legacy folder instead (when both exist, `dit` wins). No data was
moved or copied — existing stores keep working, verified by running the
real live store through the new binary. `import-investments.sh` mirrors
the same resolution so it stays usable against older builds.

Tests: the old default-path assertion (which pinned the literal old name)
became a pure, injectable resolver + three cases (fresh → dit, legacy-only
→ legacy, both → dit); machine-state-dependent checks now derive their
expectation from the same resolver, so they pass on machines with either
layout. 182 swift-testing + 113 XCTest, 324/324 e2e.

## Entry 17 — 2026-10-01 — what dit-chart actually is (docs matched to code)

Audited the chart tool for the user and found documentation drift:
cli.md/json.md/help said dit-chart charts "summary/1 and quote/1
series". It never charted quote/1 — chartableSchemas has always been
summary/1 only, and quote range documents are refused with "no chart
defined". The claim described an intention, not the tool; fixed in
docs and pinned with an e2e refusal check (quote/1 must keep being
refused until an honest chart for time series exists — bars of
closing prices dressed up as horizontal category bars would flatten a
trend into a size comparison, which is exactly the lie the refuse-
by-default rule exists to prevent). A series chart, if it ever comes,
needs its own chart type (sparkline), not the category renderer.

dit-chart in one breath: reads exactly ONE JSON doc from stdin,
charts summary/1 only (four charts: totals per account, position
values with %-of-total and the * derived-quote marker kept, unrealized
P&L and day change as +/- bars around a shared-scale zero), two glyph
tiers (Unicode default, --ascii plain), --width 40..400, refuses --svg
(exit 2). Unknown schema / bad JSON / failed source document -> exit 1
with a reason. No money math, no network, no re-derivation of
anything.

Counts: 326/326 e2e (a strict-failure check counts exit-code and
pattern separately — that is why one added check moves the counter by
two).

## Entry 18 — 2026-10-01 — `dit-chart --html`: the pipe grows an interactive window

Cross-platform ask: an interactive charting frontend that works on
macOS/Windows/Linux. Decision: the browser IS the GUI. `--html PATH`
makes dit-chart write ONE self-contained offline file (chart data +
a ~2.7 KB drawing script embedded — no CDN, no network, works over
file://, email it to yourself and it still opens). `--open` hands the
page to the system viewer (open/xdg-open). `--html -` streams the
page to stdout.

What changed vs the "one renderer" rule, and what did NOT: the
renderer still never re-implements finance. HTML mode gained a real
LINE-CHART type for `quote/1` series (the schema ASCII honestly could
not serve), with the honesty rules ported:
- one chart per STATED currency — mixed or unstated units never share
  an axis (two unknowns together would bet they are the same unit);
- data holes ≥ 10 days break the stroke (same dust-vs-hole reasoning
  as the coverage audit; a weekend is not a data hole);
- backfilled series render dashed and labelled DERIVED;
- tooltips show the document's exact strings — the drawing script
  parses floats for GEOMETRY only, money is never recomputed;
- unknown/chartless documents still produce NO file and exit 1.

Tests: ChartHTMLTests (10) pin the above with crafted documents;
e2e §22 (22 checks) runs the real pipeline on the coverage fixture —
GAPPY's deliberate 14-day hole must arrive at the page as a line
break, refused documents must write no file, and usage errors stay
exit 2. One e2e lesson: a strict check counts exit-code and pattern
separately, so the counter moved 324→348 with 21 checks added.

Counts now: 192 swift-testing + 113 XCTest + 348/348 e2e.
Terminal mode unchanged: still summary/1 bars only.

## Entry 19 — 2026-10-01 — HTML bar geometry bug: negatives crossed the zero line

User screenshot from the real store: the "Day change per position"
page showed AAPL (−3,226) and TEM (−768) as red bars starting at the
LEFT EDGE and stretching PAST the center zero line. Two lies in one
shape: negatives used the full track width (2× the positives' scale)
and their anchor put part of the bar in the positive half. The ASCII
renderer had this right from day one (half-span `cells(...)` around a
zero column); the HTML port lost it.

Fixed: center-zero negatives now `left:calc(50% - w/2); width:w/2` —
grow leftward, end AT the line, one shared scale (mirrors ASCII).
All-negative charts keep zero at the right edge (also ASCII-parity).
Two regression tests pin it: exact geometry for the mixed-sign case
(reconstructed from the screenshot's values) and the all-negative
edge rule; both fail loudly against the old form.

## Entry 20 — 2026-10-01 — HTML bars match the ASCII zero-line layout

User asked for the HTML bar charts to look like the ASCII version
(screenshot of the terminal output): one continuous dashed zero
column through the whole signed chart, "CAD" and "0" ticks above it,
legend lines beneath, and a stronger guarantee that bars anchor at
zero (Entry 19 had fixed mixed-sign charts; all-negative ones still
read awkwardly with zero pinned to the track edge).

New layout rule, one sentence: SIGNED charts always center the zero
line with one shared half-track scale (half = maxAbs), bars grow
FROM the line; a true zero draws nothing; unknowns stay dashed.
That is the ASCII parity promise — and because the bar geometry is
now written as `calc(50% - w); width:w` for negatives and
`left:50%; width:w` for positives, "never crosses the line" is true
BY CONSTRUCTION (a bar cannot reach past 50% because its width caps
at 50%), not just by assertion. The zlayer (line + ticks) spans only
the bar rows — legends sit outside the chart box, so the line stops
above them, as in the screenshot.

Verified on the real store: 63 plottable bars across the three
signed charts, all anchored, 0 crossers; unit suite rewritten to pin
the new form (mixed-sign geometry + all-negative center-line case);
350/350 e2e (same checks, one renamed).

## Entry 21 — 2026-10-01 — HTML charts adopt the React app's dashboard look

The user pasted a screenshot of the OLD DirectInvestTracker app's
MarketInsights page (React + Recharts, found at
~/workspaces/DirectInvestTracker/frontend/src/pages/MarketInsights.tsx)
and asked for dit-chart --html to carry that look and feel.

Ported, keeping the renderer-only rule: dark #030712 page with
#1f2937/#374151 cards; a stat-card strip (Total MTM / Total P&L /
Today's P&L / Cash / GIC) built ONLY from summary/1 `totals`
strings — a missing figure means NO card, so offline docs show no
fake numbers; vertical column charts replace the row-per-bar layout
(flat purple per-account, flat blue per-holding, green/red per-sign
for P&L and day change — the template's colour language); dashed
gridlines with a solid zero line; a hover band + dark tooltip that
prints the document's EXACT strings; and per-chart honest legends
("dashed stub = …", zero-line note, DERIVED note).

Geometry stays honest: Swift computes each chart's domain (always
containing zero, padded to nice 1/2/2.5/5×10^n steps), tick labels,
zero-line fraction, and per-column height fractions; the ~6 KB JS
paints rects and hover state only — it parses numbers only to draw,
never to derive money. Columns cannot cross zero by construction
(|h| ≤ space on its own side), unknowns draw a dashed stub (never a
zero bar), true zeros draw nothing. Chart/ChartSpec grew a `kind`
field (account/value/pnl/day) purely so the HTML layer picks colours
without string-sniffing titles; ASCII output is unchanged.

Verified: 64 columns on the real store, 0 crossing zero, KPI cards
equal the doc's figures; node --check on the drawing script;
195 unit tests (three rewritten to assert the payload-level truth —
shared scale, no-cross bounds, KPI exactness — plus a new no-cards-
when-empty case); 350/350 e2e debug and release.

## Entry 22 — 2026-10-02 — `dit update`: the one-shot market refresh

User asked for a single command that downloads BOTH the latest quotes
and the daily history for every ticker. The two halves already
existed (`market latest`, `market history`); `update` composes them
(latest first, then incremental history) so the daily routine is one
line. Kept deliberately thin:

- refuses `--offline` up front (a fetch command that silently did
  nothing would be the worst kind of quiet success);
- stray arguments are usage errors, matching the CLI's law;
- the portfolio is checked ONCE before any network call — an empty
  store is a quiet exit 0, and no bytes leave the machine when there
  is nothing held;
- `--json` has no schema here and says so (exit 2) instead of
  printing prose into a machine stream;
- `marketLatest(announceNext:)` lost its "next: …" nag when it runs
  inside `update` (history follows immediately; "next" would lie).

Tested offline-safe in §23 of the e2e script (refusals + the
pre-network quiet path — the script stays network-free by design);
verified live against a throwaway fixture: latest AAPL + USD/CAD
snapshots and 47 daily points (AAPL 23 + USD/CAD 24, holding windows
from Sep 1) stored by one `dit update`. 195 unit + 357/357 e2e.

## Entry 23 — 2026-10-05 — `dit update` fills gaps and audits, not just the tail

Found while using `dit update` on a live store: it completed in 0.42s
and reported success while two real holes stayed open. Two separate
causes, one user-visible symptom ("I refreshed and the report is still
wrong").

1. **The FX three-day tolerance.** `updateHistory` skipped a currency
   pair whose newest stored close was within three days of today. On a
   Monday that prices the whole book off Friday's rate — and coverage
   still called the chain "usable", so nothing warned. A 3-day USD/CAD
   drift is ~0.02%, which on a mostly-USD portfolio is a four-figure
   CAD error moving the wrong way. Replaced with: a pair is current
   only when it reaches today. A successful-but-empty fetch still
   advances the watermark, and the skip still fires when the store
   already has today, so a same-day rerun does no network work.

2. **Watermark-incremental never re-verifies.** `update` ran the
   history pass in `.incremental`, which trusts the watermark, and a
   watermark marks a range verified the moment a fetch RETURNS — not
   when it returns everything. A series can sit on twelve scattered
   closes and be skipped forever. `update` now runs `.refill`
   (`market history --all`): re-fetch every holding window, merge, and
   keep stored real closes. `--quick` keeps the old cheap path;
   `--rebuild` passes through to `.rebuild`.

`update` also ends with the coverage audit, so the command that fixes
the data also states what is still missing — the multi-step
"audit, refresh, refill" routine is one line now.

Proof, same seeded damage, same machine:

| | VRT closes | USD/CAD closes | 3-month P&L |
|---|---:|---:|---:|
| old `dit update` | 12 (unchanged) | 455 (unchanged) | 78,766.37 @1.4258 |
| new `dit update` | 112 | 457 | 78,999.52 @1.4261 |

The old build silently fixed nothing; the new one stored 102 points and
moved the reported P&L by ~233 CAD by making it reflect real data.
Cost when the store is already current: ~0.15s, no fetches.

Tests: 195 Swift-Testing + 114 XCTest green (one XCTest rewritten to
assert FX refills when it lags — its old expectation *was* the bug —
plus a new same-day-rerun-does-no-work case); 361/361 e2e, four new
assertions covering the flag surface (`--all` rejected, `--quick` and
`--rebuild` accepted, stray positional rejected).

## Entry 24 — 2026-10-06 — bold headers for stdout tables

All CLI tables share `Table.render`, so styling belongs there rather
than at individual command call sites. Header labels get ANSI bold
only when stdout is a terminal; borders, padding, and data stay plain.
Widths are measured before adding escape sequences, preserving the
existing grid and left/right alignment. Piped and redirected output
has no escapes, and JSON never goes through the table renderer.
A non-empty `NO_COLOR` or `TERM=dumb` disables terminal styling.

Added seven unit tests for exact plain/bold output, alignment,
sanitization, empty tables, and terminal/environment policy. The e2e
suite now runs `scripts/check-table-headers.py` against its synthetic
coverage fixture: 13 read commands across all table-report families,
using a real pseudo-terminal and a pipe; every header label is bold,
non-header lines are unstyled, and stripped tables match plain tables.
It also checks both opt-outs and valid escape-free JSON on both outputs.
No real portfolio stores or network access are needed for these checks.

Validation: 114 XCTest + 202 Swift-Testing tests passed; 362/362 e2e
assertions passed, including the terminal integration checks.
