import DirectInvestTracker
import Foundation
#if canImport(Darwin)
    import Darwin
#endif

// MARK: - Help text
//
// One file for every help screen. NOTE: help bodies live inside
// multiline string literals whose indentation is stripped relative to
// the closing delimiter — shifting the whole file by the same amount
// does not change printed bytes.

// MARK: - Help

func helpText(for invocation: Invocation) -> String {
    switch (invocation.group, invocation.sub) {
    case ("", _):
        return """
        USAGE: dit [command] [options]

          dit                        portfolio summary (default)
          dit summary [options]      portfolio summary
          dit accounts               list accounts
          dit account <sub> [args]   manage accounts (see: dit account --help)
          dit tx <sub> [args]        list & manage transactions (see: dit tx --help)
          dit ticker <sub> [args]    manage the instrument registry (see: dit ticker --help)
          dit store <sub> [args]     path / export / backup / import (see: dit store --help)
          dit market <sub> [args]     market-data store (see: dit market --help)
          dit quote <SYM> [...]      live price lookup (see: dit quote --help)
          dit pnl [options]          historical P&L (see: dit pnl --help)
          dit help [command]         help

          Global options: --display CCY, --offline, --json, --backend
          file|sqlite, --store PATH, --market-store PATH, -h/--help.
          Flags override environment variables. Exit codes: 0 success,
          1 runtime error, 2 usage error.

          Machine-readable output: 'dit --json …' prints one JSON
          document (also for errors) for summary, accounts, account
          show, quote and pnl — schemas and conventions in
          docs/json.md.
          Pipe it to the chart tool: 'dit --json | dit-chart --ascii'
          (see 'dit-chart --help' — it refuses documents it cannot
          honestly chart).

          Group help: dit help <group> — e.g. 'dit help account'.
        """
    case ("summary", _):
        return """
        USAGE: dit [summary] [--display CCY] [--offline] [--backend file|sqlite] [--store PATH]

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
          movement never masquerades as trading gain.
        """
    case ("accounts", _), ("account", nil), ("account", "list"):
        return """
        USAGE:
          dit accounts | dit account list                 list accounts
          dit account show <account>                      details + balances
          dit account add --currency CCY [options]        create an account
          dit account edit <account> [options]            change values
          dit account close <account> [--date D]          mark closed
          dit account delete <account> [--force] [--yes]

          <account> is a name (case-insensitive) or UUID/unique prefix.
          Add/edit options: --name, --institution, --number, --currency,
          --taxable, --non-taxable, --opened, --closed, --notes.
        """
    case ("account", "show"):
        return """
        USAGE: dit account show <account> [--history]

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
            dit account show 4F2A --history
        """
    case ("account", "add"):
        return """
        USAGE: dit account add --currency CCY [--name NAME] [--institution NAME]
                 [--number MASKED] [--taxable|--non-taxable]
                 [--opened YYYY-MM-DD] [--closed YYYY-MM-DD] [--notes TEXT]

          --currency is required (it defines how the account reports its
          totals). Accounts are taxable unless --non-taxable is given.
          --closed is accepted for importing already-closed accounts.
        """
    case ("account", "edit"):
        return """
        USAGE: dit account edit <account> [--name NAME] [--institution NAME]
                 [--number MASKED] [--currency CCY] [--taxable|--non-taxable]
                 [--opened YYYY-MM-DD] [--closed YYYY-MM-DD] [--notes TEXT]

          Only the supplied options change; history is never rewritten.
        """
    case ("account", "close"):
        return """
        USAGE: dit account close <account> [--date YYYY-MM-DD]

          Marks the account closed (default: today). Its history remains
          visible; closed accounts are excluded from current totals.
        """
    case ("account", "delete"):
        return """
        USAGE: dit account delete <account> [--force] [--yes]

          Removes the account. If it has transactions, --force is
          required (they are deleted too — the ledger is the source of
          truth). Without --yes an interactive confirmation is demanded;
          non-interactive runs must pass --yes.
        """
    case ("tx", _), ("transaction", _):
        return """
        USAGE: dit tx <command> [options]

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
            dit tx gic --account TD --product "5-Year GIC" --principal 10000 \\
                --rate 4.1 --maturity 2031-01-09
            dit tx gic-redeem --account TD --gic "5-Year GIC" --proceeds 10410
            dit tx fx --account TD --from CAD --to USD --from-amount 1000 --to-amount 740
            dit tx edit 9F2C6D1A --fee 0 --date 2026-05-05
            dit tx delete 9F2C6D1A
        """
    case ("ticker", _):
        return """
        USAGE:
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
            dit ticker list
        """
    case ("store", _):
        return """
        USAGE: dit store <path|export|backup|import> [options]

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

          EXAMPLES
            dit store path
            dit store export --account TFSA --to ~/Exports/tfsa.json
            dit store backup
            dit store import ~/Exports/tfsa.json --merge --yes
        """
    case ("market", _):
        return """
        USAGE: dit market <command> [options]

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
          are real and which were derived (see 'dit market backfill').
        """
    case ("quote", _):
        return """
        USAGE: dit quote <SYMBOL> [SYMBOL ...] [--as-of DATE | --from DATE --to DATE]
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
            dit quote TSLA TSLA.NE --from 2026-09-01 --to 2026-09-30 --json
        """
    case ("pnl", _):
        return """
        USAGE: dit pnl [--horizon H | --from DATE [--to DATE]] [--account A[,A...]]
               [--tickers T[,T...]] [--ccy C[,C...]] [--reporting-ccy CCY]
               [--json] [--offline] [--display CCY] [--store PATH]

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

          Money rules: every row is native currency; the combined
          total appears only when every currency converts (stored
          latest rates, triangulated via USD when no direct pair —
          marked and labelled). --reporting-ccy picks the combining
          currency (default: --display, CAD otherwise). Prices and
          rates come from the market store only — this command never
          fetches ('dit market history' fills it).

          EXAMPLES
            dit pnl
            dit pnl --horizon 1y
            dit pnl --horizon 3m --json | dit-chart --ascii
            dit pnl --from 2026-01-01 --to 2026-09-30 --reporting-ccy USD
            dit pnl --account "TFSA" --tickers RBLX.NE --ccy USD
        """
    default:
        return """
        USAGE: dit [command] [options]

          dit                        portfolio summary (default)
          dit summary [options]      portfolio summary
          dit accounts               list accounts
          dit account <sub> [args]   manage accounts (see: dit account --help)
          dit tx <sub> [args]        list & manage transactions (see: dit tx --help)
          dit ticker <sub> [args]    manage the instrument registry (see: dit ticker --help)
          dit store <sub> [args]     path / export / backup / import (see: dit store --help)
          dit market <sub> [args]     market-data store (see: dit market --help)
          dit quote <SYM> [...]      live price lookup (see: dit quote --help)
          dit pnl [options]          historical P&L (see: dit pnl --help)
          dit help [command]         help

          Global options: --display CCY, --offline, --backend file|sqlite,
          --store PATH, --market-store PATH, -h/--help. Flags override
          environment variables. Exit codes: 0 success, 1 runtime
          error, 2 usage error.
        """
    }
}
