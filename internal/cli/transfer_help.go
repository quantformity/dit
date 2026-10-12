package cli

import "encoding/json"

const storeUsage = `USAGE: dit store <path|export|backup|import> [options]

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

const exportUsage = `USAGE: dit export [--to FILE] [--portfolio-only|--market-only]
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

const marketUsage = `USAGE: dit market <command> [options]

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

func commandHelp(name string) string {
	switch {
	case name == "export" || name == "import":
		return exportUsage
	case name == "store" || len(name) > 6 && name[:6] == "store ":
		return storeUsage
	case name == "market" || len(name) > 7 && name[:7] == "market ":
		return marketUsage
	}
	return ""
}
func portfolioDecodeMessage(data []byte, err error) error {
	if !json.Valid(data) {
		return confirmationRefusal("The data couldn’t be read because it isn’t in the correct format.")
	}
	return err
}
