---
name: dit
description: Read and write a personal investment portfolio through the `dit` CLI — accounts, cash, trades, dividends, GICs, FX conversions, live and stored quotes, historical P&L, and market-data coverage audits. Use when asked about holdings, balances, cost basis, dividends, FX rates, or portfolio P&L, or when recording or correcting investment transactions. Needs the `dit` binary on PATH.
---

# dit — portfolio ledger CLI

`dit` is a local CLI over a personal portfolio. **Transactions are the source
of truth**: balances, holdings, and P&L are re-derived from the ledger on each
read, so query rather than assume, and never maintain a parallel calculation.

Two stores, both local:

- **portfolio store** — the ledger (accounts, transactions, ticker registry).
  Backend `file` (JSON dir) or `sqlite`.
- **market store** — a refetchable cache of price history beside it. Wiping it
  loses nothing; it is never the source of truth.

## First moves (all read-only)

```bash
command -v dit || echo "MISSING: build with swift build -c release, or scripts/build.sh"
dit store path          # backend, location, account/transaction/ticker counts
dit help                # full command listing
dit help <group>        # one group: account, tx, ticker, store, market, quote, pnl
```

Help is authoritative and never mutates — prefer it over remembered flags.
Point at a non-default store with `--store PATH` / `DIT_STORE_URL`, or switch
backend with `--backend file|sqlite`. Flags work before or after the subcommand.

## Fast path for "how is the portfolio doing?"

```bash
scripts/brief.sh                # read-only briefing: totals, top holdings, data gaps, P&L
scripts/brief.sh --live         # same, fetching live prices (slower, needs network)
scripts/brief.sh --days 90      # 90-day P&L window instead of the whole ledger
```

`scripts/brief.sh` (with `scripts/format_json.py`) runs the read commands
below, honours the envelope + exit codes, and prints dashes for unknowns. Run
it first, then drill into whatever it flags; it never writes. Run it with
`bash` from the skill directory or an absolute path.

## Read recipes

```bash
dit                                # summary: totals, cash, per-account, holdings (+ needs network for prices)
dit --offline summary              # same, no network: positions valued at cost, no day-change
dit accounts                       # registry listing
dit account show "Questrade" --history    # one account: balances + full chronological ledger
dit tx list                        # unfiltered = bank-statement view (Debit/Credit/Balance)
dit tx list --account TD --kind sell     # filtered = plain list (running balances would lie)
dit tx show 8CD1E99F               # one transaction in full; ids from `tx list`
dit ticker list                    # instrument registry (display metadata only)
dit quote AAPL USD/CAD             # LIVE prices + FX (needs network)
dit quote TSLA --from 2026-09-01 --to 2026-09-30   # stored series, no network
dit pnl --horizon 3m               # historical P&L, store-only, never fetches
dit pnl --time-series --from 2026-01-01 --to 2026-06-30
dit market coverage                # audit: which holdings lack usable price history / FX chain
```

Prefer the narrowest command that answers the question. `account show` and
`pnl` never touch the network; plain `dit`/`summary`/`quote`/`market latest`
do (use `--offline` in a sandbox — note it changes the answer, see below).

## Machine output (`--json`) — the reading contract

Supported: `summary`, `accounts`, `account show`, `quote`, `pnl`,
`market coverage`. **Everything else refuses with exit 2** — do not add
`--json` to a write command and read the failure as a success. (`tx pnl`
is listed in `reference/json.md` but is NOT on `main` — it lives on branch
`feat/tx-pnl`; the main binary rejects it.)

```bash
dit --json summary | jq .          # exactly ONE JSON document on stdout, always
```

- Envelope: `{"ok":true,"schema":"<name/1>","data":{…}}` or
  `{"ok":false,"kind":"runtime|usage","error":"…"}`. Parse `.ok` first;
  tables never appear under `--json`.
- **Exit codes**: `0` success · `1` runtime (lookup failure, state conflict,
  store I/O, or *no* requested symbol had data) · `2` usage. Output being
  non-empty proves nothing; check the exit code *and* `.ok`.
- **Money, quantities, and rates are strings, not JSON numbers** (`"100.00"`,
  6-place rates). Carry them as decimal strings; do not float-sum money.
- **`null` means "no data", never zero.** A `null` day change means no
  previous close existed. A real zero is the string `"0.00"`.
- **Provenance is data**: `via: null` = an observed price; a non-null `via`
  (e.g. `"derived via TSLA ÷ 16.2645"`) or `"basis":"derived"` is a **model
  output** — label it if you show it, never present it as a quote.
- Native amounts (`value`, `pnl`, `dayChange`) and their `*Display` /
  `reported` siblings are different numbers; percentages (`pnlPct`, `dayPct`)
  are **native-currency** ratios with FX deliberately excluded. Read one view,
  never mix the two.
- `offline: true` (summary) means no pricing happened at all; `degraded: true`
  means the market store was unreadable. Both are states, not errors.

Full field-by-field contract: `reference/json.md`. Command surface and flags:
`reference/cli.md` (and `dit help <group>` on the machine running it).

## Write recipes

```bash
dit account add --currency USD --name Mercury --institution "Mercury"
dit tx deposit --account TFSA --amount 12000 --date 2026-01-15
dit tx buy     --account Mercury --ticker AAPL --shares 10 --price 210.5
dit tx sell    --account Mercury --ticker AAPL --shares 4 --price 225 --fee 0.05
dit tx dividend --account Mercury --ticker BRK.B --amount 12
dit tx fx      --account TFSA --from CAD --to USD --from-amount 1000 --to-amount 740
dit tx edit    8CD1E99F --amount 12500 --date 2026-01-16
dit tx delete  017699AF --yes
```

- Omit `--price` on buy/sell to fetch the latest quote; under `--offline` that
  hard-errors — pass `--price` explicitly instead of dropping the entry.
- `tx edit` changes **values only**. Changing what an entry *is* (kind,
  account, ticker) is delete + re-add, so the correction stays visible.
- Amounts are plain decimals (`1200.50`, never `1,200.50`); dates are strict
  `YYYY-MM-DD`. Account names are case-insensitive but quote them when they
  contain spaces; symbols are literal (`BRK.B`, `TSLA.NE`).
- The ledger records **facts, not policy**: overdrawn cash, an oversell into a
  negative position ("untracked short"), and a partial GIC redemption are all
  *recorded with a loud warning*. Report the warning; never invent a balancing
  entry to make numbers tidy.
- Destructive paths (`tx delete`, `account delete`, `store import` replace)
  need `--yes` on a non-interactive terminal, and `--force` when an account
  still has a ledger. **Ask the user before running any of these, and run
  `dit store backup` first.**
- After writes, re-read (`dit tx list --account …`, `dit --offline summary`)
  and confirm what actually got booked instead of trusting the exit code.

## Market data

```bash
dit update                      # one pass: latest prices, then a gap-filling
                                # daily-history run, then the coverage audit
                                # (needs network; refuses --offline)
dit update --quick              # cheapest pass: top up the tail only, no
                                # re-verification of older holes
dit update --rebuild            # erase the daily history and refetch it
dit market latest               # just the latest snapshots
dit market history [--all|--rebuild]   # just the daily closes
dit market coverage             # offline: where P&L reports will dash, and why
dit quote TSLA --as-of 2026-03-11 --offline    # read one stored close
```

`dit update` already ends with the coverage audit, so one call both fixes
the data and says what is still missing. When you cannot fetch (no
network, or you are mid-report), run `dit market coverage` on its own —
or `--strict` in a script — **before** a P&L report: it names the missing
series and stale FX chains up front, so the dashes in your answer are
explained rather than mysterious. Fill gaps with `market history` /
`market import`; use `market backfill` only to model a proxy instrument,
and always relay that its numbers are derived.

## Charts (optional presentation)

```bash
dit --json | dit-chart --ascii > snapshot.txt     # terminal bars
dit --json | dit-chart --open                     # one self-contained HTML page, opened
```

`dit-chart` refuses documents it cannot honestly chart (exit 1) and renders
`null` as a dash, never as a zero-length bar.

## Pitfalls

- Empty or dashed output is a *finding* — a missing price series, an
  unconvertible currency, an offline run. Say so; do not substitute an
  estimate, a current price for a past date, or today's FX for a historical one.
- `pnl` totals are withheld when a component is unknown (`"total": null`,
  `reconciles: false`, `"(not combinable)"`). That refusal is the tool being
  correct; do not reconstruct the total yourself.
- `account show --json` reports **cost** data, not a valuation.
- `tx pnl` (branch `feat/tx-pnl` only, not `main`) attributes with FIFO
  lots while the ledger accounts at average cost — slices may differ from
  `dit pnl` windows; lifetime totals reconcile.
- Filters never widen silently: a filter that matches nothing returns nothing
  (exit 0), it does not fall back to "everything".
- One invocation = one JSON document. Need summary *and* coverage *and* P&L?
  Run three commands and parse each on its own — never splice one stream.
- Do not hardcode a store path or a currency: read `dit store path`, and let
  `--display` / `--reporting-ccy` decide the currency of a report.
