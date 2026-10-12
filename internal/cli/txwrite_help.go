package cli

const txWriteHelp = `USAGE: dit tx <command> [options]

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
