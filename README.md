# dit — transaction-first portfolio tracking for the terminal

`dit` tracks stocks, Canadian GICs, and investment cash across multiple
currencies and accounts. The **transaction ledger is the source of
truth**: holdings, balances, and P&L are always derived from it, never
stored. Two binaries live in this package:

- **`dit`** — the CLI (ledger, accounts, market data, reports)
- **`dit-chart`** — a pipe renderer that turns `dit --json` output into
  terminal charts or one self-contained interactive HTML page

Swift 6 / SwiftPM, no third-party dependencies (Foundation + stdlib
only), `Decimal` for every amount. macOS today; the HTML path runs in
any browser on any OS.

## The honesty contract

Every presentation rule in this repo serves one promise: **the output
never claims more than the data supports.**

- Derived/model figures are labelled where they appear: `~` is a
  triangulated FX rate, `*` is a DERIVED (backfilled) quote — an
  approximation, not an observation.
- Missing data prints as `—` / `NO DATA` / `GAPS` / `STALE`. It is
  never replaced by a plausible number. An unknown account total stays
  a dash; a value that cannot be converted honestly shows separately
  by currency instead of being summed into a fake total.
- Historical currency conversion uses ONLY stored daily pair series;
  a rate older than 7 days REFUSES to convert (dashes, with a remedy
  line telling you what to fetch).
- Charts never mix currencies on one axis, never draw unknowns as
  zero-length bars, and never bridge a ≥ 10-day data hole.
- The chart renderer does no finance: it refuses unknown schemas
  instead of "plotting generic bars", and its embedded JS is
  draw-and-tooltip only — values arrive as exact document strings.

## Build & install

```bash
swift build                          # debug
swift build -c release               # release binaries under .build/release/
swift test                           # unit tests (~195, offline)
bash scripts/scenario-e2e.sh         # end-to-end story (~357 checks, offline by design)
```

Put it on your PATH however you like, e.g.:

```bash
cp .build/release/dit .build/release/dit-chart /opt/homebrew/bin/
```

## Sixty-second tour

```bash
# 1. accounts (one per brokerage bucket; the currency is the DEFAULT,
#    accounts may hold more currencies)
dit account add --currency CAD --name "CAD Business Cash"
dit account add --currency CAD --name "CAD RRSP" --taxable false

# 2. register an instrument (display metadata; trades work anyway)
dit ticker add SKHY --name "SK Hynix (ADR)" --currency USD

# 3. record money — every row prints the transaction id it created
dit tx deposit --account "CAD RRSP" --amount 10000
dit tx buy --account "CAD RRSP" --ticker MSFT.TO --shares 100 \
    --price 35.93 --fee 9.99
#    cross-currency buys: money that was converted at the bank gets a
#    matching fx leg so the real rate (spread included) stays honest
dit tx fx --account "CAD Business Cash" --from CAD --to USD \
    --from-amount 2826.21 --to-amount 1954.39
dit tx buy --account "CAD Business Cash" --ticker SKHY --shares 10 \
    --price 194.44 --currency USD --fee 9.99

# 4. market data
dit update                            # latest snapshots + daily closes, one run
dit market coverage                   # audit what the store knows for what you hold

# 5. look at it
dit summary
dit account show "CAD RRSP" --history
dit pnl --from 2026-01-01
dit --json summary | dit-chart --open   # dark interactive dashboard, one file
```

## The command family

```
dit                            summary (default; live quotes unless --offline)
dit summary | accounts | account show|add|edit|close|delete
dit tx list|show|deposit|withdraw|buy|sell|dividend|gic|gic-redeem|fx|edit|delete
dit ticker list|show|add|edit|delete
dit store path|export|backup|import
dit market latest|history|backfill|import|show|coverage
dit quote <SYM|PAIR|CHAIN> [--as-of D] [--from D --to D]
dit pnl [--horizon H | --from D [--to D]] [--time-series]
dit update                        ← the daily one-liner (market latest + history)
```

Global options: `--display CCY`, `--offline`, `--json`,
`--backend file|sqlite`, `--store PATH`, `--market-store PATH`.
Flags beat environment (`DIT_BACKEND`, `DIT_STORE_URL`,
`DIT_MARKET_URL`), which beat defaults. Exit codes: `0` success,
`1` runtime error, `2` usage error — unknown options are usage errors,
never ignored.

## Data & stores

Two independent stores, both backends implemented (`file` and
`sqlite`): the **portfolio store** (accounts, ledger, ticker registry)
and the **market store** (latest snapshots + daily close/FX series).
Default location is `~/Library/Application Support/dit` (a legacy
`…/DirectInvestTracker` directory is honoured read-only). Deleting the
market store is always safe: it is cache, not truth. Deleting the
portfolio store is not — `dit store backup` exists for that.

## dit-chart

Reads ONE JSON document on stdin (from `dit … --json`) and renders or
honestly refuses:

```
dit --json | dit-chart                        terminal bars (Unicode tier)
dit --json | dit-chart --ascii --width 100    plain 7-bit tier
dit --json | dit-chart --html page.html       interactive dark dashboard (one file)
dit --json | dit-chart --open                 temp file per chart kind + open viewer
dit --json | dit-chart --html -               page to stdout
```

`--html` is offline-safe: no CDN, no network. `summary/1` renders as
a stat-card dashboard (per-currency, one shared scale around a zero
baseline); `quote/1` time series render as line charts with ≥ 10-day
data holes BREAKING the line and backfilled series dashed.
`--svg` and unknown schemas are refused by design.

## Docs

`docs/cli.md` (full CLI reference), `docs/json.md` (machine schemas),
`docs/design.md`, `docs/implementation_logs.md` (decision history).

## Privacy note

`scripts/import-investments.sh` and `scripts/add-opening-deposits.sh`
were generated from a personal portfolio (real account names, tickers,
quantities, prices). They are kept for reproducibility of this
repo-owner's own setup — scrub them before making this repository
public or adding collaborators.