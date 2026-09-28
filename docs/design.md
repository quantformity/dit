# DirectInvestTracker — Design & Phase Plan

Status marker: `✅ done · 🔨 implemented, hardening in progress · ⏭ planned`.
Implementation history lives in `docs/implementation_logs.md`.

## Product in one paragraph

A local-first, CLI-first tracker for self-directed investors: brokerage
accounts holding stocks, GICs, and cash across multiple currencies. The
**transaction ledger is the single source of truth** — holdings, balances,
and P&L are always derived from recorded transactions, never stored
independently, so a correction is always "fix the fact", never "fix two
summaries". Persistence is backend-agnostic; market data is fetched
on demand, never trusted blindly.

## Core principles (invariants that outrank features)

1. **Transactions are facts.** Every derived number recomputes from the
   ledger. No cached balances. One atomic save per mutation.
2. **The ledger records what happened, not what should fit.** Impossible
   payloads are refused (zero shares, negative amounts, fx in one
   currency, dangling GIC references). Merely *improbable* facts —
   overdraft withdrawals, sales below zero, GIC redemptions that end the
   certificate early — are **recorded with loud warnings**, because the
   user's brokerage really did that and the tracker must not hide it.
3. **Edits are real edits, but only for values.** Kind and account are
   identity, not values: changing them is delete + re-add, which keeps
   the correction visible in the ledger. A value edit rewrites one fact;
   it never forks the ledger.
4. **Nothing silently changes the store.** Every error path leaves the
   file/DB byte-identical (md5-verified).
5. **Decimal for all money.** No binary floats in monetary paths.
   Currency is a curated enum (10 + `.unknown`); display defaults to CAD
   with a USD hub for cross-currency routing.
6. **Thin CLI, fat library.** The executable parses arguments and prints;
   every rule lives in the `DirectInvestTracker` library, under tests.
   No SPM dependencies (stdlib + system libsqlite3 only).
7. **Explicit over magic.** Flags beat env vars beat defaults; a wrong
   flag is a usage error, never ignored; `--rate` is always a percentage
   (no 4.1-vs-0.041 guessing); unknown currencies/tickers are errors,
   except first-seen tickers which auto-register (registry follows facts,
   never gates them).

## Architecture

```
Sources/dit/main.swift          CLI: two-stage parse → dispatch → print (exit 0/1/2)
Sources/DirectInvestTracker/
  Currency, Tag                 foundation values
  EquityTicker                  symbol-as-identity registry (name, currency, tags)
  Account                       account header (reporting currency, taxable, dates)
  Transaction(+Details)         the ledger: kind-carrying facts, cashImpact
  AccountBalances               per-account derivation: cash pools, positions,
                                GICs, realized/dividend P&L, untrackedShorts
  Portfolio(+Summary)           cross-account aggregation, display currency
  MarketQuote/ExchangeRate/
  MarketDataCache/MarketDataPlan
  QuoteProvider/YahooQuoteProvider   on-demand quotes, freshness rules
  DataStore/FileDataStore/
  SQLiteDataStore/PortfolioStore/
  DataStoreFactory              backend-agnostic persistence; factory is the
                                single config interpreter (flags > env > default)
  AccountRef/TransactionRef     reference resolution (name / UUID / prefix)
  AccountMutations/
  TransactionMutations          write-side rules (validation, warnings, edits)
```

- Exit codes: `0` success · `1` runtime error (unknown id, lookup failure)
  · `2` usage error (prints usage).
- Store: default `~/Library/Application Support/DirectInvestTracker`;
  `--store`/`DIT_STORE_URL` + `--backend`/`DIT_BACKEND` (file | sqlite).
- Multi-currency cash: an account has a **cash pool per currency**; an fx
  conversion touches two pools; totals that cannot be converted display
  `—` instead of inventing a rate.

## Command surface (target v1)

```
dit summary [--offline]                    derived portfolio, display currency
dit accounts | account list/show           account reads
dit account add/edit/close/delete          account writes (delete: --force --yes)
dit tx [list] [filters]                    --account/--kind/--ticker/--since/--until/--limit
dit tx show <id>
dit tx deposit|withdraw --account A --amount N [--currency C]
dit tx buy|sell --account A --ticker S --shares N [--price P]   (auto-fetch price)
dit tx dividend --account A --ticker S --amount N
dit tx gic --product P --principal N --rate PCT --maturity D [--compounding K] [--redeemable]
dit tx gic-redeem --gic NAME|ID --proceeds N
dit tx fx --from C1 --to C2 --from-amount N --to-amount M
dit tx edit <id> [--date D] [--fee F] [value options]
dit tx delete <id> [--yes]
dit ticker add/list/show/edit/delete       ⏭ phase 5
dit store path/export/backup/import        ⏭ phase 6
dit quote SYM                              ⏭ phase 6
Global: --display CCY · --backend B · --store URL · --offline · --yes · --help
```

## Phases

1. ✅ **CLI plumbing** — two-stage parser (globals consumed anywhere,
   option stage closes command-word stream), Options helpers, exit-code
   convention, thin dispatch, help texts.
2. ✅ **Account management** — `dit account` add/edit/show/list/close/
   delete; AccountRef; taxable semantics; destructive gates (`--yes`,
   non-TTY refusal).
3. ✅ **Transaction ledger commands** — `tx list/show/deposit/withdraw/
   edit/delete`; TransactionRef; value-only edit rule + family rule;
   overdraft recorded+warned; delete impact preview from one
   pre-computation; one atomic save per mutation.
4. ✅ **Transaction entry forms** — `tx buy/sell/dividend/gic/gic-redeem/
   fx`; Yahoo auto-fetch when `--price` omitted (hard error `--offline`
   or lookup failure); first-seen ticker auto-registration; GIC
   all-or-nothing redemption with partial-redemption warning;
   untrackedShorts made visible in balances, summary, and footnotes.
5. ⏭ **Ticker registry (`dit ticker`)** — add/list/show/edit/delete of
   `EquityTicker` entries; symbol identity rules; currency correction
   for auto-registered tickers; `--ticker` validation gains a friendly
   "did you mean" only as sugar (unknown symbols stay allowed for trades).
6. ⏭ **Store & quote commands + polish** — `dit store path/export/
   backup/import` (import is single-account scoped; default replace with
   auto-backup `<file>.bak-<timestamp>`; `--merge` appends, skips
   same-ID; import file must contain exactly one account); `dit quote`
   (live quote + cache freshness); did-you-mean suggestions; end-to-end
   test harness; unify case-insensitive currency parsing everywhere.
7. 🔨 **Hypothetical-user scenario (emulation phase)** — *added on
   request; the phase that checks the previous six against how a real
   person would actually use the tool.*

   An executable end-to-end scenario (`scripts/scenario-e2e.sh`) drives
   the installed `dit` binary against a scratch store and **asserts**
   results, emulating a user building a portfolio from nothing:

   a. **From nothing**: first contact with an empty store → create the
      first account (this exposed the bootstrap gap: `account add` on an
      empty store must create the portfolio instead of erroring — fix is
      part of this phase), edit its metadata, list, show.
   b. **One transaction at a time**, with hand-computed expectations
      after each step (deposit → buy → dividend → fx → cross-currency
      buy), verified to the cent against manual arithmetic.
   c. **Modify and delete**: value edits (fee, date, amount, compound
      edits), refused identity edits (kind/account change → guidance),
      delete with impact preview, `--yes` gate, and re-record paths.
   d. **Multiple accounts**, including accounts whose reporting currency
      differs from the transactions inside them (a CAD-reporting account
      holding USD cash pools and USD-priced holdings; a USD-reporting
      account with CAD trades), display in CAD and in USD (`--display`).
   e. **Edge facts a real user generates**: overdraft withdrawal,
      oversell into an untracked short, partial GIC redemption,
      same-currency "fx", wrong-option mistakes — each must either
      record loudly (with the right warning) or refuse without touching
      the store.

   **Verification requirements**: every step asserts exit code + exact
   output fragments; final cash/position/P&L numbers are compared to
   independently hand-computed ledgers; the single-currency invariant
   (`cash + ΣcostBasis + gicValue == deposits − withdrawals + realized`)
   is checked where applicable; error paths are md5-proven to leave the
   store byte-identical; untracked shorts and negative pools must
   appear in summary footnotes, never silently.

## Deferred / optional backlog (not phases)

- Redis backend behind `DataStore` (protocol already supports it).
- Automated live-integration test against Yahoo (opt-in, network-gated).
- UI layer (TUI/GUI) on top of the same library derivation.
- `report`/`reconcile` commands; `--json` output (explicitly not in v1).