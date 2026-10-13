# dit command surface

Condensed from the shipped `dit help` output. Where this file and
`dit help <group>` disagree, the binary is right — read it, it is free and
read-only.

## Global options

| Option | Meaning |
|---|---|
| `--display CCY` | Display currency for money shown (default `CAD`). CAD, USD, GBP, CHF, EUR, JPY, AUD, NZD, CNY, HKD; anything else is a usage error. |
| `--offline` | Never touch the network. Commands that *require* a fresh quote refuse it. |
| `--backend file\|sqlite` | Portable JSON directory, or SQLite database (Go `modernc.org/sqlite`; no cgo requirement). |
| `--store PATH` | Portfolio store: directory or `portfolio.dat` file path (file), or database path (sqlite). |
| `--market-store PATH` | Price-history store. Defaults beside a `portfolio.dat`, otherwise under the portfolio directory. |
| `--json` | One JSON document on stdout for the supported read commands (see `json.md`). |
| `-h`, `--help` | Help. `dit help <group>` prints one group. Never mutates. |
| `--version` | Prints `dit [major].[minor].[revision] (YYYYMMDD.HHMMSS)`, then exits. |

Precedence: flags > environment (`DIT_BACKEND`, `DIT_STORE_URL`,
`DIT_MARKET_URL`) > `~/.dit/config.json` > defaults. On first run, config
sets `DIT_STORE_URL` to `~/.dit/portfolio.dat` and `DIT_MARKET_URL` to
`~/.dit/market.dat`; edit either value to relocate its document. Existing
Application Support store files are copied
there on first initialization and left intact.

Exit codes: **0** success · **1** runtime error (state conflict, lookup
failure, store I/O, no data at all for the request) · **2** usage error.

## Summary

```
dit                                   # = dit summary
dit summary --display usd
dit --offline summary                 # no quotes: holdings at cost, day-change dashed
```

Prints total value, cash by currency, per-account totals, holdings with
per-position unrealized P&L and `P&L%`. Holding `Value` cells carry the
position's own trading currency; other money columns use the display currency.
`%` columns are native-currency ratios (FX excluded by design). Day change
compares the latest quote against the last stored close strictly older than
the quote's day; no pair → dashed, never `0.00`.

## Accounts

```
dit accounts
dit account show <account> [--history]       # live valuation in account currency; --offline = cost basis/no FX
dit config set store PATH                   # change DIT_STORE_URL in ~/.dit/config.json
dit config set market PATH                  # change DIT_MARKET_URL in ~/.dit/config.json
dit backup                                  # timestamped portfolio+market backup + metadata
dit rollback --list                         # list available backup timestamps
dit rollback YYYYMMDD.HHMMSS [--yes]        # restore that snapshot
dit account add    --currency CCY [--name --institution --number --taxable --non-taxable --opened D --closed D --notes T]
dit account edit   <account> [same options]
dit account close  <account> [--date D]
dit account delete <account> [--force] [--yes]
```

`<account>` = name (case-insensitive, whitespace-trimmed) or UUID / unique
UUID prefix. Names are unique case-insensitively; a rename onto an existing
name is refused. `--force` is needed when the account has a ledger (it gets
removed too); `--yes` is required on a non-TTY.

## Transactions

Eight kinds: `deposit`, `withdraw`, `buy`, `sell`, `dividend`, `gic`,
`gic-redeem`, `fx`. Shared options: `--account`, `--date YYYY-MM-DD` (today if
omitted), `--fee` where the kind carries one.

```
dit tx list [filters]              # filters: --account --kind --ticker --since --until --limit
dit tx show <id>
dit tx pnl [--account A] [--ticker SYM]  # NOT on main — branch feat/tx-pnl only;
                                         # main errors "unknown tx subcommand
                                         # 'pnl'". Check `dit help tx` first.
dit tx deposit   --account A --amount N [--currency CCY]
dit tx withdraw  --account A --amount N [--currency CCY]
dit tx buy|sell  --account A --ticker SYM --shares N [--price P] [--currency CCY] [--fee F]
dit tx dividend  --account A --ticker SYM --amount N [--currency CCY] [--fee F]
dit tx gic       --account A --product NAME --principal N --rate PCT --maturity D [--compounding KIND] [--redeemable]
dit tx gic-redeem --account A --gic NAME|ID --proceeds N [--currency CCY] [--fee F]
dit tx fx        --account A --from CCY --to CCY --from-amount N --to-amount M [--fee F]
dit tx edit <id> [--date D] [--fee F] [value options]
dit tx delete <id> [--yes]
```

- Unfiltered `tx list` = **statement view** (Debit / Credit / running Balance
  per account and currency). Any filter = plain list, because running balances
  over a subset would mislead.
- `<id>` comes from the ID column of `tx list`; 8 hex chars are usually unique.
  Machine output (`account show --history --json`) always gives full 36-char UUIDs.
- `buy`/`sell` without `--price` fetches a quote (aborts on failure; refused
  under `--offline`). Entry currency = fetched quote currency, else the
  ticker's known trading currency, else the account's; `--currency` overrides.
- `--kind` accepts `deposit, withdrawal, buy, sell, dividend, gic, gic-redeem,
  fx` (canonical names like `stockPurchase` also work).
- Overdrafts, oversells (negative position = untracked short), and partial GIC
  redemptions are **recorded with warnings** — the ledger stores facts, not
  guardrails. Dividends register an unseen symbol automatically.
- `tx edit` is values-only, within the kind's own fields. Changing kind,
  account, or ticker means delete + re-add.

## Ticker registry

```
dit ticker | dit ticker list
dit ticker add <symbol> [--name --currency --tags a,b --notes]
dit ticker show <symbol>
dit ticker edit <symbol> [same options]
dit ticker delete <symbol> [--yes]
```

Display metadata only: trades work with or without an entry, deleting an entry
never touches the ledger. Deleting a referenced entry is gated by confirmation.

## Store

```
dit store path
dit store export [--to FILE] [--account NAME]     # single-account file is re-importable
dit store backup [--to DIR]                        # copies db + -wal/-shm sidecars too
dit store import FILE [--merge] [--force] [--yes]
```

Import is single-account. Default = **replace** that account's record and
ledger (automatic backup first unless `--force`). `--merge` appends: new
transactions only (duplicates by ID skipped), new account if the ID is
unknown, ticker symbols upserted without overwriting existing entries. Other
accounts are untouched. Malformed or multi-account files are refused before
anything is written.

## Full-portfolio transfer (`bundle/1`)

```
dit export [--to FILE] [--portfolio-only|--market-only]   # ONE file: ledger + prices
dit import FILE [--merge] [--force] [--yes]
```

A DIFFERENT format from `store export`/`store import` (those move one
account's ledger): this pair moves both stores in one file, and each pair
refuses the other's file. Use it when the answer needs prices, not just cash
— a ledger restored without its closes P&Ls as `—` everywhere.

Default import = **replace** both stores: confirms first (a non-interactive
run needs `--yes`) and copies both stores to `*.bak-<stamp>` unless
`--force`. `--merge` adds only — transactions by ID, closes day by day (a
stored real close stays; an imported real close retires a *derived* one), the
newer snapshot per symbol — so it neither confirms nor backs up. Damaged
input is refused, never half-read: an import that quietly stored fewer prices
than the file had would look like it worked. Merged prices arrive WITHOUT the
file's coverage watermark, so `dit update` still re-verifies the range.

## Quotes

```
dit quote SYM [SYM …]                       # live (network); --offline refused
dit quote USD/CAD GBP/JPY                   # live FX: quote ccy per 1 base
dit quote SYM… --as-of YYYY-MM-DD           # stored close (offline)
dit quote SYM… --from D [--to D]            # stored series, oldest first, inclusive
dit quote USD/CAD/HKD[/…] [--as-of D]       # FX matrix, single day only
```

A pair price is quote currency per 1 base (`USD/CAD 1.4183` = 1 USD buys
1.4183 CAD); `CAD/USD` is the reciprocal view. Stocks and pairs mix freely
(`dit quote AAPL USD/CAD`). Store reads print **provenance** per line:
`observed`, `backfilled — derived via …` (a model, labelled), or nothing. A
missing exact date shows the nearest earlier close with "Nd earlier". Non-zero
exit only when *none* of the request returned data; partial misses are listed.
The matrix must be the only request; `--from`/`--to` with it are usage errors;
unknown codes inside a chain are usage errors.

## Historical P&L — `dit pnl`

```
dit pnl [--horizon Nd|Nw|Nm|Ny|ytd | --from D [--to D] | --to D]
        [--account A[,A]] [--tickers T[,T]] [--ccy C[,C]] [--reporting-ccy CCY]
        [--time-series [--daily]] [--json] [--offline] [--display CCY] [--store PATH]
```

Store-only; never fetches. Two columns, never conflated: **Realized** (booked
ledger facts in the window) and **Position Δ** (mark-to-market drift between
the last close before the window and the last close by its end). `Total`
appears only when both are known. Default window = whole ledger, which is
exact because holdings sit at cost before the first trade.

- Reporting currency is single (`--reporting-ccy`, default `--display`, else
  CAD); conversion uses the FX close stored on/before the relevant date,
  marked `~` when composed. Stale (>1 week) or missing rates dash — today's
  rate is never projected backwards.
- `--time-series` slices the window (monthly above 8 weeks, weekly above 10
  days, daily below; `--daily` forces daily). `--daily` alone is a usage error.
  A sliced sum that disagrees with the window total is FX timing, and the
  footer says so rather than pretending otherwise.
- Usage errors (exit 2): `--horizon` with `--from/--to`, unknown horizon,
  malformed/impossible date, `--to` before `--from`, stray positional,
  `--daily` alone. Unknown `--account` = exit 1. Empty filter result = exit 0
  with a quiet message.

## Market data — `dit market`, `dit update`

```
dit update                             # one pass: market latest → gap-filling market
                                       # history (--all) → coverage audit. Network;
                                       # refuses --offline. --quick = tail-only history
                                       # pass (still audits); --rebuild erases daily
                                       # history first. Default re-verifies every holding
                                       # window, so it finds holes a watermark-trusting
                                       # incremental run would skip forever.
dit market latest                      # refresh current prices + FX for open positions
dit market history [--all|--rebuild]   # fill daily closes (incremental by default)
dit market backfill <target> --from <source> [--ratio R] [--dry-run]
dit market import FILE [--dry-run]     # CSV: SYMBOL,YYYY-MM-DD,PRICE
dit market show [--symbol S] [--days N]
dit market coverage [--from D --to D] [--account A] [--tickers T] [--reporting-ccy X] [--strict]
```

- `latest`/`history` need the network (`--offline` refuses them). `history`
  fetches only days each symbol was actually held, and only where the store is
  empty; `--all` re-verifies and fills gaps but never replaces a real close;
  `--rebuild` erases daily history first (latest snapshots survive).
- `show`, `coverage`, `import` work offline. `coverage` is the read-only audit:
  one row per (held symbol, recorded currency) plus one row per foreign
  currency's FX chain, reporting staleness, gaps ≥ 10 days, `WRONG CCY`,
  `NO CHAIN`. Default exit 0 (it is a report); `--strict` exits 1 on any
  finding for scripted use.
- `backfill` derives a proxy's missing history from an underlying
  (`TSLA.NE` from `TSLA ÷ ratio`); the ratio is calibrated on days where both
  were really quoted. Fills are tagged `derived via …`, never overwrite real
  observations, and never touch the ledger.

## Charts — optional `dit-chart` companion

`dit-chart` is a separate binary and is not included or built by this Go project. If installed independently, it reads one JSON document on stdin.

```
dit --json | dit-chart                     # terminal bars (summary/1 only)
dit --json | dit-chart --ascii             # 7-bit glyph tier (#, ^, ?)
dit --json | dit-chart --width 120
dit --json | dit-chart --html page.html    # one self-contained offline page
dit --json | dit-chart --html page.html --open
dit --json | dit-chart --open              # temp page per chart kind, opened now
dit --json | dit-chart --html -            # page to stdout
```

`--html` additionally charts `quote/1` series as line charts. Everything else
(`pnl/1`, snapshots, unknown schemas) is refused with exit 1, as is `--svg`.
A failed source document (`"ok":false`) prints its message instead of a chart.
Exit codes match `dit`: 0 charted, 1 nothing chartable, 2 usage.
