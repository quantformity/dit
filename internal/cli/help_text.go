package cli

// Help screens, transcribed byte-for-byte from
// /Users/chup/workspaces/dit/Sources/dit/HelpText.swift (all `case`
// bodies plus the `default:` body — the main-screen text appears there
// twice with different line-wrapping, and both variants are preserved).
// Regenerate with scripts/gen_help.py; do not edit these strings by hand.

const helpBody1 = `USAGE: dit [command] [options]

  dit                        portfolio summary (default)
  dit summary [options]      portfolio summary
  dit accounts               list accounts
  dit account <sub> [args]   manage accounts (see: dit account --help)
  dit tx <sub> [args]        list & manage transactions (see: dit tx --help)
  dit ticker <sub> [args]    manage the instrument registry (see: dit ticker --help)
  dit store <sub> [args]     path / export / backup / import (see: dit store --help)
  dit export [--to FILE]     whole-portfolio backup: ledger + market data
  dit import FILE            restore / merge that file (see: dit export --help)
  dit market <sub> [args]     market-data store (see: dit market --help)
  dit quote <SYM> [...]      live price lookup (see: dit quote --help)
  dit pnl [options]          historical P&L (see: dit pnl --help)
  dit update                 refresh market data in one pass:
                             latest prices, then a gap-filling
                             daily-history run, then the
                             coverage audit (needs network;
                             refuses --offline). --quick takes
                             the cheap tail-only history pass,
                             --rebuild erases daily history first
  dit help [command]         help

  Global options: --display CCY, --offline, --json, --backend
  file|sqlite, --store PATH, --market-store PATH, -h/--help,
  --version.
  Flags override environment variables. Exit codes: 0 success,
  1 runtime error, 2 usage error.

  Machine-readable output: 'dit --json …' prints one JSON
  document (also for errors) for summary, accounts, account
  show, quote, pnl and market coverage — schemas and
  conventions in docs/json.md.
  Pipe it to the chart tool: 'dit --json | dit-chart --ascii'
  for terminal bars, or 'dit --json | dit-chart --open' for one
  self-contained interactive page (temp file, opens in any
  browser). See 'dit-chart --help' (it refuses documents it
  cannot honestly chart).

  Group help: dit help <group> — e.g. 'dit help account'.`

const helpBody2 = `USAGE: dit [summary] [--display CCY] [--offline] [--backend file|sqlite] [--store PATH]

  Portfolio summary: totals, per-currency rows, per-account
  values, holdings. Costs the network unless --offline.
  --display must be a supported currency code (e.g. CAD, USD, GBp).

  Holdings show values in their own trading currency (with
  the code), a converted 'Value (<display>)' column when
  currencies mix, and one-day P&L columns: 'Day (<display>)'
  compares the latest quote with the previous stored close
  (from the market store; dashed — never guessed — when
  unavailable), 'Day%' the resulting native price move.
  Money columns (Value/Day/P&L) speak the display currency;
  % columns (Day%/P&L%) are native-currency ratios, so FX
  movement never masquerades as trading gain.`

const helpBody3 = `USAGE:
  dit accounts | dit account list                 list accounts
  dit account show <account>                      details + balances
  dit account add --currency CCY [options]        create an account
  dit account edit <account> [options]            change values
  dit account close <account> [--date D]          mark closed
  dit account delete <account> [--force] [--yes]

  <account> is a name (case-insensitive) or UUID/unique prefix.
  Add/edit options: --name, --institution, --number, --currency,
  --taxable, --non-taxable, --opened, --closed, --notes.`

const helpBody4 = `USAGE: dit account show <account> [--history]

  Account details plus balances derived from its transactions,
  computed offline: positions show at cost basis and foreign
  amounts stay unconverted (no FX is applied).

  --history appends the account's full chronological ledger
  (deposits, trades, dividends, GICs, FX — oldest first, with
  transaction IDs). For filtered views use 'dit tx list
  --account NAME' (--kind/--ticker/--since/--until/--limit).

  EXAMPLES
    dit account show TFSA
    dit account show TFSA --history
    dit account show 4F2A --history`

const helpBody5 = `USAGE: dit account add --currency CCY [--name NAME] [--institution NAME]
         [--number MASKED] [--taxable|--non-taxable]
         [--opened YYYY-MM-DD] [--closed YYYY-MM-DD] [--notes TEXT]

  --currency is required (it defines how the account reports its
  totals). Accounts are taxable unless --non-taxable is given.
  --closed is accepted for importing already-closed accounts.`

const helpBody6 = `USAGE: dit account edit <account> [--name NAME] [--institution NAME]
         [--number MASKED] [--currency CCY] [--taxable|--non-taxable]
         [--opened YYYY-MM-DD] [--closed YYYY-MM-DD] [--notes TEXT]

  Only the supplied options change; history is never rewritten.`

const helpBody7 = `USAGE: dit account close <account> [--date YYYY-MM-DD]

  Marks the account closed (default: today). Its history remains
  visible; closed accounts are excluded from current totals.`

const helpBody8 = `USAGE: dit account delete <account> [--force] [--yes]

  Removes the account. If it has transactions, --force is
  required (they are deleted too — the ledger is the source of
  truth). Without --yes an interactive confirmation is demanded;
  non-interactive runs must pass --yes.`

const helpBody9 = `USAGE: dit tx <command> [options]

  dit tx list [filters]               transactions (all accounts by default)

  Unfiltered, 'tx list' prints a STATEMENT view: Debit /
  Credit / running Balance columns per account and currency,
  derived live from the ledger (cash only — positions and
  GICs never appear in a cash column). Any filter (--kind,
  --ticker, --since/--until, --limit) prints the plain list,
  because running balances over a subset would lie.
  dit tx show <id>                    one transaction, in full
  dit tx deposit  --account A --amount N [options]
  dit tx withdraw --account A --amount N [options]
  dit tx buy|sell --account A --ticker SYM --shares N
                  [--price P] [--currency CCY] [--fee F] [--date D]
  dit tx dividend --account A --ticker SYM --amount N
                  [--currency CCY] [--fee F] [--date D]
  dit tx gic --account A --product NAME --principal N --rate PCT
             --maturity YYYY-MM-DD [--compounding KIND] [--redeemable]
  dit tx gic-redeem --account A --gic NAME|ID --proceeds N
                  [--currency CCY] [--fee F] [--date D]
  dit tx fx --account A --from CCY --to CCY
            --from-amount N --to-amount M [--fee F] [--date D]
  dit tx edit <id> [--date D] [--fee F] [value options]
  dit tx delete <id> [--yes]

  buy/sell without --price fetches the latest quote (a lookup
  failure aborts; under --offline pass --price instead). A
  sale bigger than the holding is recorded but flagged.
  Entry currency defaults to the fetched quote's currency,
  else the ticker's known trading currency, else the
  account's — --currency overrides.
  --gic names the redeemed GIC by product name or id; no
  match lists the account's live GICs.

  Filters: --account A, --kind K, --ticker SYM, --since D,
  --until D, --limit N (most recent N).
  <id> comes from the ID column of 'dit tx list'; 8 characters
  usually identify a transaction uniquely.

  --kind values: deposit, withdrawal, buy, sell, dividend, gic,
  gic-redeem, fx (canonical names like stockPurchase work too).

  Edit rule: values only, within the kind's own fields (a
  deposit takes --amount; trades --shares/--price; a GIC
  --principal/--rate/--maturity/--compounding/--product; ...).
  Changing WHAT a transaction is (kind, account, ticker) is
  delete + re-add — the correction stays visible in the ledger.

  EXAMPLES
    dit tx --limit 10
    dit tx list --account "Wells Fargo" --kind sell
    dit tx deposit --account TD --amount 1000
    dit tx deposit --account TD --amount 500 --currency USD --date 2026-04-01
    dit tx buy --account TD --ticker SHOP.TO --shares 10 --price 180
    dit tx sell --account TD --ticker SHOP.TO --shares 4
    dit tx dividend --account TD --ticker AAPL --amount 12
    dit tx gic --account TD --product "5-Year GIC" --principal 10000 \
        --rate 4.1 --maturity 2031-01-09
    dit tx gic-redeem --account TD --gic "5-Year GIC" --proceeds 10410
    dit tx fx --account TD --from CAD --to USD --from-amount 1000 --to-amount 740
    dit tx edit 9F2C6D1A --fee 0 --date 2026-05-05
    dit tx delete 9F2C6D1A`

const helpBody10 = `USAGE:
  dit ticker | dit ticker list              list the instrument registry
  dit ticker add <symbol> [options]         register an instrument
  dit ticker show <symbol>                  entry details + references
  dit ticker edit <symbol> [options]        update one entry
  dit ticker delete <symbol> [--yes]        remove an entry

  Options: --name NAME, --currency CCY (the currency the
  instrument trades in), --tags a,b, --notes TEXT.
  The registry is display metadata: trades for a symbol work
  with or without an entry, and deleting an entry never
  touches the ledger. Deleting an entry that transactions
  reference is gated by confirmation.

  EXAMPLES
    dit ticker add BRK.B --name "Berkshire Hathaway" --currency USD
    dit ticker edit shop.to --tags "dividend, core"
    dit ticker list`

const helpBody11 = `USAGE: dit store <path|export|backup|import> [options]

  dit store path              where the store lives (backend + location)
  dit store export [options]  write a JSON copy of the portfolio
  dit store backup            timestamped copy of the store file(s)
  dit store import FILE [options]

  export options: --to FILE, --account NAME (a single-account
  file can be imported; a multi-account export cannot)
  import options: --merge (append instead of replace),
  --force (skip the automatic pre-import backup), --yes
  backup options:  --to DIR

  IMPORT SEMANTICS — an import file is single-account. The
  default (replace) swaps that account's record and ledger for
  the file's contents, taking an automatic backup of the store
  first (unless --force). --merge appends instead: new
  transactions (never duplicates by ID), a new account if the
  ID is unknown, new ticker symbols only. Other accounts are
  never touched.

  NOT THIS COMMAND: 'dit export' / 'dit import' move the WHOLE
  portfolio — every account plus the market data that prices it —
  in one 'bundle/1' file. A bundle is not a 'store import' file
  and a single-account dump is not a bundle: each pair refuses
  the other's format rather than half-reading it.

  EXAMPLES
    dit store path
    dit store export --account TFSA --to ~/Exports/tfsa.json
    dit store backup
    dit store import ~/Exports/tfsa.json --merge --yes`

const helpBody12 = `USAGE: dit export [--to FILE] [--portfolio-only|--market-only]
       dit import FILE [--merge] [--force] [--yes]

  The whole-portfolio pair: ONE file carrying the ledger AND the
  market data that prices it. 'store export'/'store import' move
  one account's ledger and are a DIFFERENT format — each pair
  refuses the other's file, so a wrong file is a usage error
  instead of a partial restore.

  EXPORT writes one JSON document beside the store (or at --to),
  with every account, transaction and ticker plus the daily
  closes, latest quotes and FX rates. A store missing one half is
  not an error — the file carries the other and says what was
  skipped. --portfolio-only writes the ledger without prices;
  --market-only writes prices without the ledger.

  import defaults to REPLACE: the file becomes both stores. It
  therefore confirms first (a non-interactive run must pass
  --yes) and copies both stores to '*.bak-<timestamp>' first
  unless --force. A file that is not a bundle, that carries
  neither half, or whose ledger references an account or a GIC
  purchase that neither the file nor the store has, is refused
  before a store is opened, copied, or written.

  --merge only adds: transactions already present by ID are
  skipped, prices land day by day (stored real closes win,
  imported real closes replace derived ones) and the newer
  snapshot wins per symbol. It removes nothing, so it neither
  confirms nor backs up.

  A replace restores the file's coverage watermarks exactly as
  written. A merge never adopts them: an imported range has not
  been verified HERE, so 'dit update' still re-checks it instead
  of trusting a claim that arrived in a file.

  EXAMPLES
    dit export                                    # full backup, beside the store
    dit export --to /tmp/portable.json
    dit import /tmp/portable.json --yes           # restore (confirms, then backs up)
    dit import /tmp/portable.json --merge --yes   # add only what is new`

const helpBody13 = `USAGE: dit market <command> [options]

  dit market latest              refresh latest prices + FX
  dit market history [--all|--rebuild]
                                 fill daily closes (default:
                                 incremental, watermark-paced);
                                 --all re-verifies every
                                 window and FILLS GAPS but
                                 keeps stored real closes;
                                 --rebuild erases the daily
                                 history first and refetches
  dit market backfill <target> --from <source> [options]
                                 DERIVE missing history for a
                                 quote-less tracker (e.g. a
                                 NEO .NE proxy) from its
                                 underlying
  dit market import FILE         seed real closes (CSV:
                                 SYMBOL,YYYY-MM-DD,PRICE)
  dit market show [--symbol S] [--days N]
                                 what the store holds (aligned
                                 tables; --symbol restricts
                                 BOTH the Latest and History
                                 tables to one ticker)
  dit market coverage [options]  AUDIT (offline, read-only):
                                 which held positions have
                                 usable price history, and
                                 where FX chains are missing
                                 or too stale to convert —
                                 find the holes BEFORE 'dit
                                 pnl' dashes on them

  coverage options: --from/--to DATE (audit window; default:
  the whole ledger up to today; --to is ALSO the day
  staleness is measured against), --account A (scope),
  --tickers T (price-table display filter), --strict (exit 1
  when any row has a gap — default exits 0: findings print,
  they do not error). Reports FACTS only: points, dates,
  staleness, gap runs ≥ 10 days (shorter holes are weekend
  dust in weekday-sampled data). A series in the wrong
  currency is named as never-usable; stale FX breaks
  conversion by rule, so it is a finding.

  backfill options: --from SOURCE, --ratio R (skip
  calibration), --dry-run. The ratio is averaged over the
  days where BOTH instruments were really quoted, then past
  prices are computed as source × FX ÷ ratio. Derived values
  are marked as derived and never replace real observations;
  the ledger is never touched.

  The market-data store is SEPARATE from the portfolio store:
  it lives beside it (a 'market' directory or 'market.sqlite'
  file) and can be moved with --market-store / DIT_MARKET_URL.
  It never feeds the ledger — transactions stay the source of
  truth; this is refetchable price data.

  'latest' stores one snapshot per held symbol and needed FX
  pair (overwritten each run). 'history' stores daily closes
  for the days each symbol was actually held, fetched only
  where the store has no data yet — re-running adds just the
  new end-of-day quotes. --all re-fetches each window and
  MERGES (fills holes the watermark had walked past; real
  closes are never replaced), --rebuild erases the daily
  history first and refetches everything (latest snapshots
  survive).
  Both need the network; --offline refuses them. 'history'
  ends with a coverage table (earliest / latest stored day
  and point count per series); anything newly fetched is
  called out in a line above it. 'import' and
  'show' work offline: import stores what you measured (an
  old app's cache, a vendor file), show marks which points
  are real and which were derived (see 'dit market backfill').`

const helpBody14 = `USAGE: dit quote <SYMBOL> [SYMBOL ...] [--as-of DATE | --from DATE --to DATE]
       dit quote CCY/CCY/CCY[/...] [--as-of DATE]        FX matrix

  dit quote SHOP.TO AAPL USD/CAD   live prices (FX too)
  dit quote TSLA.NE --as-of 2026-05-01   the stored close
  dit quote TSLA.NE --from 2026-09-15 --to 2026-09-25
                                 the stored series, oldest first

  Prints a table (symbol, price, currency, date, provenance).
  The live form needs the network — --offline is refused
  there. --as-of and --from/--to read the market store
  instead (no fetch, works with --offline) and label each
  price by where it came from: 'observed' (a close fetched
  or imported), 'backfilled — derived via …' (model output
  from a related ticker — an approximation, not a quote),
  or nothing. FX pairs ("USD/CAD", both sides ISO codes)
  are answered by the rate endpoint, live AND from the
  store; a live pair price is quote-currency per 1 unit
  of base. --from alone prints from that day to today;
  --to alone prints everything up to that day. A date with
  no stored quote (--as-of) shows the nearest earlier one
  and how many days back that was. Exit non-zero only when
  *none* of the requested symbols has any price; partial
  misses are listed, not an error.

  A chain of 3+ currencies (USD/CAD/HKD/EUR) prints the
  FX MATRIX instead: one table, every pairwise rate, each
  cell quoting the row's base. Rates the source does not
  publish directly are triangulated through USD and marked
  '*' — approximations, labelled as such, never posed as
  quotes. Single-day by design: --as-of picks the day
  (plain = live now, --offline = latest stored); --from/
  --to are refused. The matrix must be the only request.

  EXAMPLES
    dit quote AAPL SHOP.TO USD/CAD
    dit quote TSLA.NE NVDA.NE --as-of 2026-06-15
    dit quote USD/CAD --as-of 2025-01-02 --offline
    dit quote USD/CAD/HKD/EUR
    dit quote USD/CAD/HKD/EUR --as-of 2026-09-25 --offline
    dit quote TSLA TSLA.NE --from 2026-09-01 --to 2026-09-30 --json`

const helpBody15 = `USAGE: dit pnl [--horizon H | --from DATE [--to DATE]] [--account A[,A...]]
       [--tickers T[,T...]] [--ccy C[,C...]] [--reporting-ccy CCY]
       [--time-series [--daily]] [--json] [--offline] [--display CCY] [--store PATH]

  Historical P&L between dates, built from the ledger and the
  market store — two components, never merged:
    Realized    what the ledger booked inside the window (sale
                gains over cost, GIC redemption gains,
                dividends net of fees).
    Position Δ  mark-to-market drift across the window: value
                at the window's closing mark minus its value
                at the close before it opened.
  They add to the window's economic result without double
  counting; without a usable price pair at BOTH boundaries
  the Position Δ and Total are dashed — never guessed.

  Windows are inclusive on both ends. --horizon: Nd/Nw/Nm/Ny
  (e.g. 5d, 2w, 3m, 2y) counted back from --to or today, and
  'ytd'. No flags: the full ledger (exact by construction —
  nothing was held before the first trade). --to alone: from
  the ledger's first transaction to that date. --horizon and
  --from/--to are mutually exclusive (exit 2).

  Scope: no --account aggregates the whole portfolio into one
  view (rows merge across accounts); --account names you asked
  for THEM — rows stay per account. --tickers and --ccy filter
  positions; a filter that matches nothing reports "nothing",
  it never silently widens back to everything.

  Money rules: text output speaks ONE currency — the
  reporting currency (--reporting-ccy, default: --display,
  CAD). Native amounts never mix in the table; when rows
  carry a different recorded currency, a 'From' column names
  it. Cross-currency figures convert at the FX close stored
  ON/BEFORE the relevant date (direct pair, inverted twin,
  or USD triangulation — composed rates are marked ~, never
  smoothed). A stale (>1 week) or missing close means DASH:
  today's rate is never projected backwards. --reporting-ccy
  changes only this run's display — it never rewrites any
  account's stored reporting currency. Exact native figures
  (plus a converted 'reported' triple) stay in --json.
  Prices and rates come from the market store only — this
  command never fetches ('dit market history' fills it).

  --time-series slices the window into periods (auto: monthly
  above 8 weeks, weekly above 10 days, daily below — always
  labelled) and prints one row per period, each computed with
  its own baseline close and converted at ITS OWN end-date FX
  — a June slice never wears July's rate. --daily forces
  daily periods at any window length (alone it is a usage
  error — it only modifies --time-series). Contiguous periods
  telescope in native amounts: when every period is
  measurable the printout says "Σ periods = window total
  (exact)"; gaps stay dashed and the sum is refused, never
  faked. Combines with filters.

  EXAMPLES
    dit pnl
    dit pnl --horizon 1y
    dit pnl --time-series                          # default window, sliced
    dit pnl --time-series --daily                  # every day that speaks
    dit pnl --time-series --from 2026-01-01 --to 2026-09-30
    dit pnl --from 2026-01-01 --to 2026-09-30 --reporting-ccy USD
    dit pnl --account "TFSA" --tickers RBLX.NE --ccy USD`

const helpBody16 = `USAGE: dit [command] [options]

  dit                        portfolio summary (default)
  dit summary [options]      portfolio summary
  dit accounts               list accounts
  dit account <sub> [args]   manage accounts (see: dit account --help)
  dit tx <sub> [args]        list & manage transactions (see: dit tx --help)
  dit ticker <sub> [args]    manage the instrument registry (see: dit ticker --help)
  dit store <sub> [args]     path / export / backup / import (see: dit store --help)
  dit export [--to FILE]     whole-portfolio backup: ledger + market data
  dit import FILE            restore / merge that file (see: dit export --help)
  dit market <sub> [args]     market-data store (see: dit market --help)
  dit quote <SYM> [...]      live price lookup (see: dit quote --help)
  dit pnl [options]          historical P&L (see: dit pnl --help)
  dit update                 refresh market data in one pass:
                             latest prices, then a gap-filling
                             daily-history run, then the
                             coverage audit (needs network;
                             refuses --offline). --quick takes
                             the cheap tail-only history pass,
                             --rebuild erases daily history first
  dit help [command]         help

  Global options: --display CCY, --offline, --backend file|sqlite,
  --store PATH, --market-store PATH, -h/--help, --version. Flags override
  environment variables. Exit codes: 0 success, 1 runtime
  error, 2 usage error.`

const incomeHelp = `USAGE: dit income [--year YYYY | --since DATE --to DATE] [--account A[,A...]] [--json]

  Cash income over a window: dividends (net of fees) and GIC
  interest (proceeds above the redeemed principal), listed oldest
  first and totalled per currency. Trading and GIC realized P&L
  are capital results, not income — see 'dit pnl' for those.

  Amounts stay in the currency paid; a window spanning more than
  one currency is totalled per currency and never blended into one
  figure. Default window: the current calendar year to today.
  Reads the ledger only; makes no network calls (works offline).

  Examples:
    dit income
    dit income --year 2025
    dit income --since 2025-01-01 --to 2025-06-30
    dit income --account TFSA --account Margin
    dit income --year 2025 --json`

const txImportHelp = `USAGE: dit tx import FILE [--dry-run] [--allow-duplicates]

  Bulk-load transactions from a CSV file. Columns (a header line
  is optional, but if present it must be exactly these names):

    date,account,type,ticker,currency,quantity,price,amount,fee,notes

  Types: deposit, withdraw, buy, sell, dividend. A buy or sell
  needs ticker, quantity (shares) and price (record the price you
  paid; the importer never fetches). A dividend needs ticker and
  amount. currency defaults to the ticker's registered currency,
  else the account's reporting currency. fee is separate from and
  deducted out of amount.

  GICs and FX conversions reference other records, so they are not
  in the CSV path — use 'dit tx gic', 'dit tx gic-redeem' and
  'dit tx fx'.

  The import is all-or-nothing: if any row is malformed (bad date,
  unknown account, missing value) the whole import aborts and the
  store is left exactly as it was. Duplicate rows — matching a
  transaction already in the ledger or earlier in the same file —
  are skipped, so re-running an import is safe; --allow-duplicates
  turns that off. --dry-run validates and reports without writing.

  Examples:
    dit tx import trades.csv --dry-run
    dit tx import trades.csv
    dit tx import 2024-restate.csv --allow-duplicates`

// helpTextFor answers (group, sub) exactly like the Swift helpText(for:)
// switch: same keys, same order, and anything unknown falls through to
// the Swift default body (helpBody16), never to an error.
func helpTextFor(group, sub string) string {
	if group == "summary" && sub == "" {
		return helpBody2
	}
	if group == "accounts" && sub == "" {
		return helpBody3
	}
	if group == "account" && sub == "" {
		return helpBody3
	}
	if group == "account" && sub == "list" {
		return helpBody3
	}
	if group == "account" && sub == "show" {
		return helpBody4
	}
	if group == "account" && sub == "add" {
		return helpBody5
	}
	if group == "account" && sub == "edit" {
		return helpBody6
	}
	if group == "account" && sub == "close" {
		return helpBody7
	}
	if group == "account" && sub == "delete" {
		return helpBody8
	}
	if group == "income" {
		return incomeHelp
	}
	if group == "tx" && sub == "import" {
		return txImportHelp
	}
	if group == "transaction" && sub == "import" {
		return txImportHelp
	}
	if group == "income" {
		return incomeHelp
	}
	if group == "tx" && sub == "import" {
		return txImportHelp
	}
	if group == "transaction" && sub == "import" {
		return txImportHelp
	}
	if group == "tx" {
		return helpBody9
	}
	if group == "transaction" {
		return helpBody9
	}
	if group == "ticker" {
		return helpBody10
	}
	if group == "store" {
		return helpBody11
	}
	if group == "export" {
		return helpBody12
	}
	if group == "import" {
		return helpBody12
	}
	if group == "market" {
		return helpBody13
	}
	if group == "quote" {
		return helpBody14
	}
	if group == "pnl" {
		return helpBody15
	}
	if group == "config" {
		return configSetHelp
	}
	if group == "backup" {
		return backupHelp
	}
	if group == "rollback" {
		return rollbackHelp
	}
	if group == "serve" {
		return serveHelp
	}
	if group == "clone" {
		return cloneHelp
	}
	if group == "connect" {
		return connectHelp
	}
	if group == "disconnect" {
		return disconnectHelp
	}
	if group == "upgrade" {
		return upgradeHelp
	}
	return withConfigCommand(helpBody16)
}
