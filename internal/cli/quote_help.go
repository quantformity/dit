package cli

// Wording from the reference binary, including usage-error help.
const quoteHelp = `USAGE: dit quote <SYMBOL> [SYMBOL ...] [--as-of DATE | --from DATE --to DATE]
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
