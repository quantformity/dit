package cli

var acctmgktHelp = map[string]string{
	"account show": `USAGE: dit account show <account> [--history]

  Account details plus a summary-style view scoped to this account.
  Text values use the account's reporting currency, with live quotes
  and FX like dit summary; --offline disables network and FX, showing
  positions at cost basis with foreign amounts unconverted. --json keeps
  the raw per-currency account/1 ledger view.

  --history appends the account's full chronological ledger
  (deposits, trades, dividends, GICs, FX — oldest first, with
  transaction IDs). For filtered views use 'dit tx list
  --account NAME' (--kind/--ticker/--since/--until/--limit).

  EXAMPLES
    dit account show TFSA
    dit account show TFSA --history
    dit account show 4F2A --history`,
	"account add": `USAGE: dit account add --currency CCY [--name NAME] [--institution NAME]
         [--number MASKED] [--taxable|--non-taxable]
         [--opened YYYY-MM-DD] [--closed YYYY-MM-DD] [--notes TEXT]

  --currency is required (it defines how the account reports its
  totals). Accounts are taxable unless --non-taxable is given.
  --closed is accepted for importing already-closed accounts.`,
	"account edit": `USAGE: dit account edit <account> [--name NAME] [--institution NAME]
         [--number MASKED] [--currency CCY] [--taxable|--non-taxable]
         [--opened YYYY-MM-DD] [--closed YYYY-MM-DD] [--notes TEXT]

  Only the supplied options change; history is never rewritten.`,
	"account close": `USAGE: dit account close <account> [--date YYYY-MM-DD]

  Marks the account closed (default: today). Its history remains
  visible; closed accounts are excluded from current totals.`,
	"account delete": `USAGE: dit account delete <account> [--force] [--yes]

  Removes the account. If it has transactions, --force is
  required (they are deleted too — the ledger is the source of
  truth). Without --yes an interactive confirmation is demanded;
  non-interactive runs must pass --yes.`,
	"ticker": `USAGE:
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
    dit ticker list`,
}
