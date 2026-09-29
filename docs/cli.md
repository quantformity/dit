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
`EUR`, `JPY`, `CNY`, `INR`, `HKD`, `SGD`.

**Exit codes**: `0` success · `1` runtime error (state conflict, lookup
failure, store I/O) · `2` usage error (unknown command/option, bad value,
missing required field).

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
runtime, 2 usage); parse `.ok` for the semantic result.

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
dit quote <SYMBOL> [...] --as-of YYYY-MM-DD        # the stored price for a date
```

The live form requires the network — `--offline` is refused there, and
a fetch failure aborts. Exit non-zero only when *none* of the
requested symbols returned a quote; partial misses are listed, not an
error.

`--as-of` reads the market store (no network, works with `--offline`)
and prints the newest close on or before that date, with a PROVENANCE
flag telling you what the number actually is:

| Provenance | Meaning |
|---|---|
| `observed` | a real close — fetched from Yahoo (or imported); this is a measurement |
| `backfilled — derived via TSLA ÷ 16.2645` | NOT a quote: model output from `market backfill` (underlying × FX ÷ a calibrated ratio); approximates, usually within ~1% while the peg holds |
| `(none)` / "no stored quote" | nothing known for that date and symbol (all-missing exits 1) |

If the exact date has no stored price (weekend, holiday, or a gap),
the nearest earlier one is shown with "Nd earlier" so a stale answer
is never mistaken for that day's close.

```bash
dit quote SHOP.TO AAPL
dit quote TSLA.NE --as-of 2026-03-11          # → backfilled (labelled)
dit quote USD/CAD --as-of 2025-01-02 --offline
```

## Market data — the quote store

```
dit market latest                      # refresh latest prices + FX for what you hold
dit market history [--all]             # fill daily closes (incremental)
dit market backfill <target> --from <source> [--ratio R] [--dry-run]
                                       # DERIVE missing history from a proxy
dit market import FILE [--dry-run]     # seed real closes from a CSV
dit market show [--symbol S] [--days N]   # inspect what the market store holds
```

`market latest` prints one aligned price table (symbols + FX pairs,
compact timestamps). `market show` prints two aligned tables — Latest
snapshots and History series — and `--symbol` restricts BOTH to one
ticker (it prints an honest "nothing stored for X" instead of empty
tables). A `history` run that fetches nothing collapses to one summary
line; the per-series table appears only when something actually
happened. Display formatting only — the data and exit codes are
unchanged.

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
  fetches are reported. `--all` erases the daily history first and
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

All market commands need the network (except `show` and `import`,
which work offline); `--offline` refuses `latest` and `history`. The
store is read by `dit quote --as-of` (it labels each price observed or
backfilled); `dit summary` still values positions from live quotes —
summary-level `--as-of` and offline valuation from this store are the
designed follow-up.

```bash
dit market latest
dit market history
dit market history --all
dit market show --symbol RBLX --days 10
dit market import old-prices.csv
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
