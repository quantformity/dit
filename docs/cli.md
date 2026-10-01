# dit — command reference

`dit` (DirectInvestTracker) is a CLI for tracking a personal portfolio —
brokerage accounts, bank accounts, multi-currency cash and holdings,
equities, dividends, GICs, and FX conversions. **Transactions are the
source of truth**: everything you see (balances, holdings, P&L) is
derived from the ledger on each read; nothing else is stored.

Run `dit --help` (or `dit help`) for the full command listing, or
`dit <group> --help` / `dit help <group>` for one group — help never
mutates, even when attached to a command that would.

## Setup & configuration

The store location and backend can be set three ways, in decreasing
priority:

| Priority | Mechanism | Example |
|---|---|---|
| 1 | Flags (any command) | `dit --backend sqlite --store ~/Store/ dit.sqlite` |
| 2 | Environment | `DIT_BACKEND=file DIT_STORE_URL=~/Store/dit` |
| 3 | Default | `file` backend at `~/Library/Application Support/DirectInvestTracker` |

Useful environment variables:

- `DIT_BACKEND` — `file` (default) or `sqlite`.
- `DIT_STORE_URL` — the store file (sqlite db) or directory (file
  backend) to use. Default: `~/Library/Application Support/DirectInvestTracker`.

Supported display currencies: `CAD` (default), `USD`, `GBP`, `CHF`,
`EUR`, `JPY`, `AUD`, `NZD`, `CNY`, `HKD` (case-insensitive; anything
else is a usage error).

**Exit codes**: `0` success · `1` runtime error (state conflict, lookup
failure, store I/O) · `2` usage error (unknown command/option, bad value,
missing required field).

## Output format

Tables (the `summary` breakdowns, `accounts`, `account show`, `ticker`
listings, `tx list`, `quote`, and the `market` reports) print as
full-grid tables in Unicode box-drawing: a `│` wall between columns,
a `├─┼─┤` rule between every pair of rows, and a `└─┴┘` bottom edge.
Cells are padded to the widest value, so tables read aligned straight
off stdout; labels are left-aligned, money stays right-aligned.
Vertical bars inside data render as broken bars (`¦`) so a value can
never tear a grid wall. `--json` is unaffected: the machine contract
(docs/json.md) never embeds table syntax, and provenance travels in
dedicated fields (`via`, `basis`), never in display markers.

## Global options

| Option | Meaning |
|---|---|
| `--display CCY` | Report currency for money shown. Case-insensitive. Defaults to `CAD`. |
| `--offline` | Never touch the network. Commands that *require* a fresh quote hard-error (pass explicit values instead). |
| `--backend file\|sqlite` | Backends: portable JSON directory, or libsqlite3 database. |
| `--store PATH` | Where the store lives. With `file`, a directory; with `sqlite`, a database file (a directory is accepted; `portfolio.sqlite` inside it is used). |
| `--market-store PATH` | Where the MARKET-data store lives (see `dit market`). Defaults to a `market` directory / `market.sqlite` file beside the portfolio store; env: `DIT_MARKET_URL`. |
| `--json` | Machine-readable output for supported read commands (`summary`, `accounts`, `account show`, `quote`): stdout is exactly ONE JSON document with a stable envelope — even on errors. Other commands refuse it (exit 2). Schemas: `docs/json.md`. |
| `-h`, `--help` | Help. `dit --help` (or `dit help`) prints the full command listing; `dit <group> --help` prints one group's commands. Takes precedence over everything in its scope. |

Flags apply to the whole invocation; any order before or after the
subcommand is fine. `--json` keeps exit codes unchanged (0 ok, 1
runtime, 2 usage); parse `.ok` for the semantic result. Machine docs
can be piped into `dit-chart` (see "Charts" below): the renderer
only accepts schemas it understands.

## Summary

```
dit                         # portfolio summary (default action)
dit summary                 # same, explicit
dit summary --display usd   # show totals in USD
dit --offline summary       # no network: positions with known prices only
```

Output: total value, cash rows by currency, per-account values, holdings
(alphabetical by symbol; with per-position unrealized P&L and a
**P&L%** column: percent return
on cost basis, computed in the position's own trading currency so FX
movement never masquerades as gain, dashed when there is no real quote
or the cost basis is zero/negative), and footnotes for facts the
summary can't price (GICs at par, untracked shorts, etc.).

Value conventions in the tables:

- Holding `Value` cells carry the position's own trading currency
  (`CAD 6,000.00`, `USD 284,256.00`) — an unmarked number in a
  mixed-currency table is not self-describing.
- Money columns other than that native `Value` speak the portfolio's
  **display currency**: `Value (<display>)` (appears when currencies
  mix), and the `Day (<display>)` / `P&L (<display>)` columns in
  Holdings. Conversion uses the current FX rate; unconvertible →
  dashed, a rate is never invented. A single-currency portfolio hides
  `Value (<display>)` (it would only repeat the native column).
- `%` columns are **native-currency ratios**, deliberately not
  converted: `Day%` is the price move versus the previous close, and
  `P&L%` is return on cost, both computed in the position's own
  trading currency — so FX movement can never masquerade as trading
  gain, and the percent always reconciles with the native cost.
  (A USD position's CAD P&L figure therefore includes FX drift; the
  P&L% beside it does not. A footnote states this when currencies
  mix.)
- With market data available, one-day change columns appear: `Day`/
  `Day%` in Holdings, a `Day` column in the By-currency and Accounts
  tables (per-row currency, as everywhere in those tables), and a
  `Day change` line at the top (display currency). Day change compares
  each position's latest quote with that ticker's **previous available
  stored close** — the last observation strictly older than the
  quote's own day, however old, from the market store. No pair →
  dashed or absent, never a fabricated 0.00. When the baseline was a
  derived (backfilled) point — e.g. the .NE trackers' proxy history —
  the footnote says so: the day move mirrors the underlying through
  the model, it is not a real quote of that ticker.

## Accounts

`<account>` in every account command is a name (case-insensitive,
whitespace-trimmed) or a UUID / unique prefix of one.

```
dit accounts                                  # list accounts
dit account show <account>                    # details + balances
                                              # (--history appends the
                                              #  full chronological ledger,
                                              #  offline, with tx IDs)
dit account add --currency CCY [options]      # create an account
dit account edit <account> [options]          # change values
dit account close <account> [--date D]        # mark closed (gets a closed-date; still in listings & summary)
dit account delete <account> [--force] [--yes]
```

Add/edit options: `--name`, `--institution`, `--number`, `--currency`,
`--taxable`, `--non-taxable`, `--opened YYYY-MM-DD`, `--closed YYYY-MM-DD`,
`--notes TEXT`.

Names must be unique (case-insensitive) — the CLI resolves accounts by
name, so a duplicate name is refused and a rename onto an existing name
is refused too.

```bash
# Two accounts, one in each home currency
dit account add --currency CAD --name TFSA --non-taxable --institution "Desjardins"
dit account add --currency USD --name "Mercury" --institution "Mercury"

dit account show TFSA
dit account show "CAD RRSP" --history          # ledger: date, kind, detail + tx id
dit account edit Mercury --notes "broker + cash"
dit account close TFSA --date 2031-12-31        # mark as closed

# Destructive: --yes is required on non-interactive terminals;
# --force is required when the account has a ledger (it gets removed too).
dit account delete TFSA --yes
```

## Transactions — entry & correction

The ledger supports eight kinds, each a first-class event:

| Kind | Command |
|---|---|
| cash in | `dit tx deposit` |
| cash out | `dit tx withdraw` |
| buy | `dit tx buy` |
| sell | `dit tx sell` |
| dividend | `dit tx dividend` |
| GIC purchase | `dit tx gic` |
| GIC redemption | `dit tx gic-redeem` |
| FX conversion | `dit tx fx` |

All entry commands share: `--account A` (name or UUID), `--date
YYYY-MM-DD` (today if omitted), and `--fee` where the kind carries one.
Amounts are plain decimals (`1200.50` works, `1,200.50` does not);
dates are strict `YYYY-MM-DD`.

```
dit tx list [filters]               # transactions (all accounts)
dit tx show <id>                    # one transaction, in full
dit tx deposit   --account A --amount N [options]
dit tx withdraw  --account A --amount N [--currency CCY] [options]
dit tx buy     --account A --ticker SYM --shares N [--price P] [options]
dit tx sell    --account A --ticker SYM --shares N [options]
dit tx dividend --account A --ticker SYM --amount N [options]
dit tx gic     --account A --product NAME --principal N --rate PCT
               --maturity YYYY-MM-DD [--compounding KIND] [--redeemable]
dit tx gic-redeem --account A --gic NAME|ID --proceeds N [options]
dit tx fx      --account A --from CCY --to CCY --from-amount N --to-amount M
               [--fee] [options]
dit tx edit <id> [--date D] [--fee F] [value options]
dit tx delete <id> [--yes]
```

Listing filters: `--account A`, `--kind K` (`deposit`, `withdrawal`,
`buy`, `sell`, `dividend`, `gic`, `gic-redeem`, `fx`), `--ticker SYM`,
`--since D`, `--until D`, `--limit N`.

**Statement view**: with NONE of those filters, `tx list` becomes a
bank-statement table — `Debit` / `Credit` / `Balance` columns,
computed on the fly per account and currency (cash only; positions and
GICs never enter a cash column; a trade's fee rides with it, an fx
debits the source currency). Accounts that hold more than one currency
at ANY point of the shown history get one aligned `Bal CCY` column per
currency — a purse that empties keeps its column and reads `—` (no
cash there) rather than silently vanishing. Single-currency accounts
keep the compact one-column `Balance after`. With ANY filter you get
the plain list, because running balances over a filtered subset would
be theater. The `--kind`/`--ticker`-style lookups above are unaffected.

`<id>` is the ID column of `dit tx list`; 8 hex chars are usually unique.

### Buy/sell without `--price`

If `--price` is omitted, `dit` fetches the latest quote for the symbol
and records what was fetched, telling you. Under `--offline` (or when
the quote is unavailable) this hard-errors — pass `--price` explicitly.

### Recording rules to know

The ledger **records facts, not policy**:

- **Overdrawn** account (withdraw/buy beyond cash) — recorded, with a
  loud warning and a footnote in the summary.
- **Oversell** (more shares than you held) — recorded; the position goes
  negative and is footnoted as an **untracked short**.
- **Partial GIC redemption** — a redemption ends the GIC in this model
  (all-or-nothing); a partial `--proceeds` is recorded with a warning
  that the remainder is booked as gone. If you mean only part came
  back, delete that redemption and record what actually happened.
- **Dividends** — cash in, no holdings change. A symbol not yet
  registered in the ticker registry is added automatically.

These warnings are *loud on purpose*: the goal is a faithful ledger,
not a guardrail that silently rewrites your intent.

```bash
# Cash
dit tx deposit --account TFSA --amount 12000 --date 2026-01-15
dit tx withdraw --account TFSA --amount 500 --currency CAD

# Trades (explicit price = fully offline; omitted price = fetched)
dit tx buy  --account Mercury --ticker AAPL --shares 10 --price 210.5 --date 2026-02-01
dit tx sell --account Mercury --ticker AAPL --shares 4 --price 225 --fee 0.05

# Dividend (auto-registers the symbol if unseen)
dit tx dividend --account Mercury --ticker BRK.B --amount 12 --date 2026-03-15

# GIC, then redemption at par-ish (recorded, warned, not priced)
dit tx gic --account TFSA --product "3-Year GIC" --principal 10000 \
           --rate 4.5 --maturity 2029-01-20 --redeemable
dit tx gic-redeem --account TFSA --gic "3-Year GIC" --proceeds 11350 --date 2029-01-20

# FX: swap the two cash pools in an account
dit tx fx --account TFSA --from CAD --to USD --from-amount 1000 --to-amount 740

# Correct or delete
dit tx list --account TFSA --kind deposit
dit tx edit 8CD1E99F --amount 12500 --date 2026-01-16
dit tx delete 017693AF --yes
```

## Ticker registry

The registry is **display metadata** — trades for a symbol work with or
without an entry; deleting an entry never touches the ledger. It exists
so listings/summaries can show a name, the trading currency, and tags.

```
dit ticker | dit ticker list              # list the registry
dit ticker add <symbol> [options]         # register
dit ticker show <symbol>                  # entry details + references
dit ticker edit <symbol> [options]        # update
dit ticker delete <symbol> [--yes]        # remove (gated if referenced)
```

Options: `--name NAME`, `--currency CCY` (the currency it trades in),
`--tags a,b`, `--notes TEXT`.

```bash
dit ticker add BRK.B --name "Berkshire Hathaway" --currency USD --tags "dividend, core"
dit ticker edit shop.to --tags "dividend, retail, core"
dit ticker show AAPL
dit ticker delete TSLA --yes       # --yes required on non-TTY if transactions reference it
```

## Store — path, export, backup, import

```
dit store path              # where the store lives (backend + location)
dit store export [options]  # write a JSON copy of the portfolio
dit store backup            # timestamped copy of the store file(s)
dit store import FILE [options]
```

- `export`: `--to FILE`, `--account NAME`. A single-account export is a
  file you can import back into another store; a multi-account export
  (the default) is human-readable and portable.
- `backup`: `--to DIR`. For the file backend, copies the whole store
  directory; for sqlite, copies the db plus any `-wal`/`-shm` sidecars.
- `import`: `--merge` (append instead of replace), `--force` (skip the
  automatic pre-import backup), `--yes` (required on non-TTY for
  replace).

Import is single-account scoped. Default is **replace**: the target
account's record + ledger are swapped for the file's contents (an
automatic backup is taken first unless `--force`). `--merge` appends:
new transactions are added (duplicates by ID are skipped), an existing
account is kept, new ticker symbols are upserted (existing registry
entries are never overwritten). Other accounts in the target store are
never touched. Malformed or multi-account import files are refused
before anything is written.

```bash
dit store path
dit store export --account TFSA --to ~/Exports/tfsa.json
dit store backup
dit store backup --to ~/Backups
dit store import ~/Exports/tfsa.json --merge --yes
```

## Quotes

```
dit quote <SYMBOL> [SYMBOL ...]                    # live last prices (Yahoo Finance)
dit quote USD/CAD GBP/JPY                          # live FX rates (quote ccy per 1 base)
dit quote <SYMBOL> [...] --as-of YYYY-MM-DD        # the stored price for a date
dit quote <SYMBOL> [...] --from DATE [--to DATE]   # the stored series, oldest first
dit quote USD/CAD/HKD[/...] [--as-of DATE]         # FX MATRIX (single day only)
```

FX pairs (both sides ISO codes) are answered by the rate endpoint
when live, and by the stored FX series for `--as-of`/`--from`/`--to`.
A pair price is QUOTE currency per 1 unit of BASE: `USD/CAD 1.4183`
means 1 USD buys 1.4183 CAD. `CAD/USD` works too (reciprocal view of
the same pair); mix pairs and stocks freely: `dit quote AAPL USD/CAD`.

The live form requires the network — `--offline` is refused there, and
a fetch failure aborts. Exit non-zero only when *none* of the
requested symbols returned a quote; partial misses are listed, not an
error.

**FX matrix** — a chain of 3+ ISO codes (`USD/CAD/HKD/EUR`, one
argument) prints ONE table of every pairwise rate instead of per-
symbol lines. Each cell is the column currency per 1 unit of the row
base. Rates come directly from the source when it publishes the cross
(live Yahoo usually does); anything else is triangulated through the
two USD legs and marked `*` — a labelled approximation, never posed
as a quote. Reciprocals of observed quotes print unmarked (exact
inversions). The matrix is **single-day only**: `--as-of DATE` reads
one day from the store, plain means live now, `--offline` takes the
latest stored rates. `--from`/`--to` are refused (exit 2), and the
matrix must be the only request. Exit 1 when not a single rate is
known for the chain. Unknown codes inside a chain are a usage error
(`USD/CAD/XYZ` → exit 2), not a silent miss.

`--as-of` and `--from`/`--to` read the market store (no network, work
with `--offline`) and print what is STORED with a PROVENANCE flag
telling you what each number actually is. The range form prints every
stored close inside the inclusive window, one table per symbol;
`--from` alone runs to today, `--to` alone starts at the earliest
stored day. It never invents a point for a day the store does not
have.

| Provenance | Meaning |
|---|---|
| `observed` | a real close — fetched from Yahoo (or imported); this is a measurement |
| `backfilled — derived via TSLA ÷ 16.2645` | NOT a quote: model output from `market backfill` (underlying × FX ÷ a calibrated ratio); approximates, usually within ~1% while the peg holds |
| `(none)` / "no stored quote" | nothing known for that date and symbol (all-missing exits 1) |

If the exact date has no stored price (weekend, holiday, or a gap),
the nearest earlier one is shown with "Nd earlier" so a stale answer
is never mistaken for that day's close.

```bash
dit quote SHOP.TO AAPL USD/CAD
dit quote TSLA.NE --as-of 2026-03-11          # → backfilled (labelled)
dit quote USD/CAD --as-of 2025-01-02 --offline
dit quote TSLA TSLA.NE --from 2026-09-01 --to 2026-09-30
dit quote USD/CAD/HKD/EUR                     # live matrix
dit quote USD/CAD/HKD/EUR --as-of 2026-09-25  # one stored day
```

## Historical P&L — `dit pnl`

```
dit pnl                                     # full ledger history (default)
dit pnl --horizon 2w|3m|1y|ytd|90d          # relative window ending today
dit pnl --from DATE [--to DATE]             # explicit window (both ends inclusive)
dit pnl --to DATE                           # ledger start … DATE
dit pnl [--account A[,B]] [--tickers S[,S]] [--ccy USD[,CAD]] [--reporting-ccy CAD]
dit pnl --time-series […]                   # slice the window into periods
dit pnl --time-series --daily                # force one row per day
```

Pure store read — never the network. Two columns answer two different
questions and are **never conflated**:

- **Realized** — booked ledger facts inside the window: sale proceeds
  over proportional cost, dividends net of fees, GIC redemptions over
  principal. Exact, because it is what the ledger says happened.
- **Position Δ** — mark-to-market drift: value of holdings at the last
  close *strictly before* `FROM` versus the last close *by the window
  end*. Derived, and dashed when no usable price pair exists.

`Total = Realized + Position Δ` is printed **only when both are
known**. A position that drifted without any trade still appears (the
drift IS the window's P&L); a quiet zero-drift position does not.

Honesty rules the report will not break:

- Default window starts at your first trade, where holdings sit at
  cost — so the default report needs no baseline price and is exact.
- No price pair → Position Δ and Total dash, the position is excluded
  from currency totals, and a footnote names the symbols and how to
  fill the gap (`dit market history --all`). A total with a missing
  half is worse than a dash.
- Text output speaks **one currency — the reporting currency**
  (`--reporting-ccy`, default: `--display`, else CAD). There are no
  native per-currency tables: a USD amount is shown as CAD, or it is
  dashed. The `From` column names each row's recorded currency.
- Conversion is HISTORICAL: each figure converts at the FX close
  stored on or before the date it belongs to (the window end for
  the plain view; each period's own end for `--time-series`). Direct
  pair, inverted twin, or USD triangulation are all legal sources —
  composed or older-than-the-day rates are marked `~` and quoted
  with the real date (`Total (CAD): … [converted at USD→CAD 1.4
  (2026-07-31)]`). No stored close for the date — or one more than
  a week old — means DASH: today's rate is never projected
  backwards, and the Total line refuses rather than mixing a CAD
  guess with USD facts. Fill history with `dit market history --all`
  or `dit market import` (FX pair lines like `USD/CAD,2026-07-31,
  1.40` count — pair series ARE dated rates).
- The combined `Total (CAD)` appears only when every currency is
  complete AND convertible; otherwise `— (not combinable)`. Native
  amounts are never lost: `--json` keeps them exactly (plus a
  `reported` triple converted at the dated FX).
- `--reporting-ccy` is RUNTIME ONLY — it decides how this report is
  displayed and never rewrites what the ledger stores. No conversion
  happens at all when the portfolio already sits in the reporting
  currency (header says `as recorded — no conversion needed`).
- Position series explicitly stored in a *different* currency than
  the holding are never used (different instrument, not a conversion).

**`--time-series` — the window sliced into periods.** One row per
period in the reporting currency, each period computed by the same
engine with its own baseline close (strictly before the period start)
and converted at ITS OWN end-date FX — a June slice never wears
July's rate. Period size is
AUTO — monthly above 8 weeks, weekly above 10 days, daily below — and
always named in the header (`series: monthly periods`); `--daily`
forces daily periods at any length (marked `(forced)`), and alone it
is a usage error — it only modifies `--time-series`. Because the
slices are contiguous, they telescope in NATIVE amounts: when every
period is measurable the footer says `Σ periods = window total
(exact)`; if any period lacks a price pair the sum is refused
(`Σ ≠ … GAPS, not zeros`) — a sliced report can never quietly
disagree with the whole. A converted-Σ that differs from the window
total is FX TIMING (each period used its own close), and the footer
says exactly that instead of pretending.
Truly quiet periods (nothing booked, measured zero drift) collapse
into a counted note; periods with UNMEASURABLE drift are counted
separately — "nothing happened" and "nothing is knowable" are
different facts. Works with the filters and `--json` (the slices ride
along under `"series"`); `--time-series=false` is the normal view.

Usage errors (exit 2): mixing `--horizon` with `--from/--to`, unknown
horizon token, malformed or impossible date, `--to` before `--from`,
stray positional. An unknown `--account` is a lookup error (exit 1).
Filters that match nothing exit 0 with a quiet message — filters
never silently widen back to "all". `--json` emits `pnl/1` (see
`docs/json.md`).

```bash
dit pnl --horizon 1m                       # last month's story
dit pnl --time-series                      # same window, sliced by period
dit pnl --time-series --daily              # one row per day, all of them
dit pnl --time-series --from 2026-01-01 --to 2026-09-30
dit pnl --account "CAD TSFA"               # per-account tables
dit pnl --tickers TSLA.NE --ccy CAD        # one instrument
dit pnl --to 2026-06-30 --reporting-ccy USD
dit --json pnl --from 2026-01-01 | my-tool   # machine contract
```

## Charts — `dit-chart` (the pipe renderer)

`dit-chart` is a separate small tool in the same package: it reads
**one JSON document on stdin** (from any `dit … --json`) and draws
ASCII bar charts. Format flags decide the output; data decides the
chart type.

```
dit --json | dit-chart                    # summary → charts (Unicode blocks)
dit --json | dit-chart --ascii            # plain tier (# ^ ?), pure 7-bit
dit --json | dit-chart --width 100        # drawing width (default: COLUMNS, 80)
dit --json | dit-chart --svg out.svg      # REFUSED for now (exit 2, honest)
```

- **Chartable input**: `summary/1` and `quote/1` series. Unknown
  schemas — including `pnl/1` — are REFUSED (exit 1, "no chart
  defined for …"), never drawn as "generic bars"; a failed source
  document (`"ok":false`) prints its message instead of a chart.
- **Honesty carries through the pipe**: null amounts render dashed
  (`—`/`?` marker), never as zero-length bars; derived (backfilled)
  valuations keep their `*` marker and legend; `--offline` docs say
  values are AT COST.
- **Two glyph tiers** (for cross-platform outlook): the default uses
  Unicode blocks `█✕▲`; `--ascii` guarantees bytes 128+ appear
  nowhere (safe for LANG=C, cp936 consoles, and grep-able tests).
- **Exit codes** match `dit`: 0 charted, 1 nothing chartable, 2 usage.

```bash
dit --json | dit-chart --ascii > pnl.txt     # save a text snapshot
dit --json | dit-chart --width 120           # big terminal
grep -c '#' <(dit --json | dit-chart --ascii)  # quick machine check
```

## Market data — the quote store

```
dit market latest                      # refresh latest prices + FX for what you hold
dit market history [--all|--rebuild]   # fill daily closes (incremental; --all re-verifies, --rebuild erases)
dit market backfill <target> --from <source> [--ratio R] [--dry-run]
                                       # DERIVE missing history from a proxy
dit market import FILE [--dry-run]     # seed real closes from a CSV
dit market show [--symbol S] [--days N]   # inspect what the market store holds
dit market coverage [--from D --to D] [--account A] [--tickers T] [--reporting-ccy X] [--strict]
                                       # AUDIT what the store knows for what you hold
```

`market latest` prints one aligned price table (symbols + FX pairs,
compact timestamps). `market show` prints two aligned tables — Latest
snapshots and History series — and `--symbol` restricts BOTH to one
ticker (it prints an honest "nothing stored for X" instead of empty
tables). `market history` ends with a per-series coverage table —
earliest day, latest day, and point count of what the store now
holds — with newly fetched points called out in a line above it.
Display formatting only — the data and exit codes are unchanged.

### Derived history (`market backfill`)

Some instruments (the NEO `.NE` trackers, for example) have no daily
price source anywhere. If one is a fixed-ratio stand-in for a real
underlying (`TSLA.NE` ≈ one `TSLA` share divided by a ratio, converted
at the day's FX), you can fill its history from the underlying:

```bash
dit market backfill TSLA.NE --from TSLA --dry-run   # inspect first
dit market backfill TSLA.NE --from TSLA             # calibrate + fill
```

The ratio is calibrated as the AVERAGE of
`source close × FX ÷ target close` over every day where BOTH were
really observed (stored closes plus today's live quote) — not invented;
`--ratio` skips calibration and uses the given constant. Gaps are then
filled as `source close × the day's FX ÷ ratio`, weekdays only, inside
the symbol's holding windows (replay of the ledger tells it where a
position actually existed). Honesty guarantees: fills carry a
`derived via …` provenance tag (visible in `market show` and in
`--json` as `"via": …`), real observations are never overwritten (a
future real close supersedes a derived value for the same day), and
the calibration spread is reported — a wide spread means the tracker
is de-coupling and the derived history will drift with it. This is a
MODEL, and it is labelled as one everywhere. No network needed if the
underlying's history is already stored (`--offline` works); otherwise
it fetches the missing source series first.

Price data lives in a store SEPARATE from the ledger — a `market`
directory (file backend) or `market.sqlite` (sqlite backend) beside the
portfolio store, movable with `--market-store` / `DIT_MARKET_URL`. The
market store is a cache of fetched facts, never a source of truth:
wiping it loses nothing you could not refetch, and no command here
ever touches the ledger.

- `latest` fetches the current price of every symbol with an OPEN
  position (plus the FX pairs your display needs) and stores ONE
  snapshot per symbol, overwritten each run. Prices that stay missing
  are listed as warnings, not hidden.
- `history` fills end-of-day closes, but only for the days each
  symbol was actually held (derived from your transactions — a symbol
  sold in May fetches nothing after May), and only where the store
  has no data yet. Re-running adds just the new closes; failed
  fetches are reported. `--all` re-fetches every holding window and
  MERGES — it fills gaps the watermark had walked past while keeping
  every stored real close (real never replaces real; only real
  replaces derived). `--rebuild` erases the daily history first and
  refetches everything (latest snapshots survive).
- `show` reads the store offline: latest table, per-series coverage
  (with a Source column telling you whether points are observed or
  derived), and `--symbol S --days N` prints the last N closes of one
  series (derived ones marked `(derived)`).
- `import` takes a CSV of `SYMBOL,YYYY-MM-DD,PRICE` lines (one per
  day; `#` comments and a header line are skipped) — the way to seed
  measured history from elsewhere (an old app's cache, a vendor file).
  Imported observations are real: they replace derived guesses for the
  same day. Unparsable lines are reported, line-numbered.

All market commands need the network (except `show`, `coverage` and
`import`, which work offline); `--offline` refuses `latest` and
`history`. The
store is read by `dit quote --as-of` (it labels each price observed or
backfilled); `dit summary` still values positions from live quotes —
summary-level `--as-of` and offline valuation from this store are the
designed follow-up.

### Coverage — find the holes before `dit pnl` dashes on them

`market show` answers "what does the store hold?". `market coverage`
asks the harder question: "for what my ledger holds TODAY, what does
the store KNOW?" It is a pure offline audit — no network, no writes,
no valuations, no percentages (weekday-sampled series make day-fraction
"coverage" a lie anyway). It reads the same sources the reports read
and reports their failure modes by name:

- **Prices**: one row per held symbol and its recorded currency — a
  ticker held in both USD and CAD needs TWO series and gets two rows.
  Facts per row: closes in window, their date range, staleness against
  the audit day, the longest missing-day hole (reported only at ≥ 10
  days — shorter runs are weekend/holiday dust), a `*derived` marker
  for proxy series, and a `WRONG CCY` verdict for a series stored in
  a currency that can never be read for that position.
- **FX**: one row per foreign currency the scope uses (cash,
  positions, GICs) — the CHAIN into the reporting currency and
  whether it is fresh enough to convert, checked at the audit day AND
  at every period end a `--time-series` report would slice at. A
  chain of 8-month-old legs is `STALE` (the FX clock refuses it —
  conversion dashes), not covered; a currency with no pair anywhere is
  `NO CHAIN`.

The audit window defaults to the whole ledger up to today (use
`--from/--to` to narrow; `--to` is also the day staleness is measured
against). Gaps are only counted FROM the day the ledger first needed
the data — darkness before a first purchase is nobody's gap. Default
exit is 0 (it is a report): `--strict` flips that to 1 when any row
has a finding, for scripts. Filters behave everywhere: `--tickers`
narrows the price table, `--account` scopes the whole audit, unknown
flags and reversed windows are usage errors (exit 2).

```bash
dit market latest
dit market history
dit market history --all
dit market show --symbol RBLX --days 10
dit market import old-prices.csv
dit market coverage                    # what would dash, and why
dit market coverage --strict           # …and fail a script when it does
```

## A realistic walkthrough

```bash
# 1. Two accounts
dit account add --currency CAD --name TFSA --non-taxable
dit account add --currency USD --name Mercury

# 2. Register the instruments you care about
dit ticker add SHOP.TO --name Shopify --currency CAD --tags "dividend, retail"
dit ticker add AAPL --name Apple --currency USD

# 3. Cash in
dit tx deposit --account TFSA --amount 20000 --date 2026-01-15
dit tx deposit --account Mercury --amount 10000 --currency USD --date 2026-01-15

# 4. Buy some stock (explicit price, so no network needed)
dit tx buy --account Mercury --ticker AAPL --shares 20 --price 210 --date 2026-02-01
dit tx buy --account TFSA --ticker SHOP.TO --shares 5 --price 80 --date 2026-02-02

# 5. Collect a dividend
dit tx dividend --account Mercury --ticker AAPL --amount 20 --date 2026-03-15

# 6. Put some cash in a GIC and later redeem it
dit tx gic --account TFSA --product "2-Year GIC" --principal 15000 --rate 4.4 \
           --maturity 2028-01-20 --redeemable
dit tx gic-redeem --account TFSA --gic "2-Year GIC" --proceeds 16300 --date 2028-01-20

# 7. Convert some CAD to USD
dit tx fx --account TFSA --from CAD --to USD --from-amount 2000 --to-amount 1480

# 8. Look at everything
dit
dit --display USD summary          # show totals in USD
dit --offline summary              # offline: known prices only, no quotes
dit tx list --account Mercury --kind buy
dit quote AAPL BRK.B                # live prices
```
