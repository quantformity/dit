# dit — command reference

`dit` (DirectInvestTracker) is a CLI for tracking a personal portfolio —
brokerage accounts, bank accounts, multi-currency cash and holdings,
equities, dividends, GICs, and FX conversions. **Transactions are the
source of truth**: everything you see (balances, holdings, P&L) is
derived from the ledger on each read; nothing else is stored.

Run `dit help [command]` anytime — help never mutates, even when attached
to a command that would.

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
| `-h`, `--help` | Help. Takes precedence over everything in its scope. |

Flags apply to the whole invocation; any order before or after the
subcommand is fine.

## Summary

```
dit                         # portfolio summary (default action)
dit summary                 # same, explicit
dit summary --display usd   # show totals in USD
dit --offline summary       # no network: positions with known prices only
```

Output: total value, cash rows by currency, per-account values, holdings,
and footnotes for facts the summary can't price (GICs at par, untracked
shorts, etc.).

## Accounts

`<account>` in every account command is a name (case-insensitive,
whitespace-trimmed) or a UUID / unique prefix of one.

```
dit accounts                                  # list accounts
dit account show <account>                    # details + balances
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
dit quote <SYMBOL> [SYMBOL ...]        # live last prices (Yahoo Finance)
```

Prints a table (symbol, price, currency, as-of time, source). Requires
the network — `--offline` is refused here, and a fetch failure aborts.
Exit non-zero only when *none* of the requested symbols returned a
quote; partial misses are listed, not an error.

```bash
dit quote SHOP.TO AAPL
dit quote BRK.B JPM
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
