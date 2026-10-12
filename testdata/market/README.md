# Swift oracle fixtures

Generated offline with `/opt/homebrew/bin/dit`, file backend, on 2026-10-09.
All show snapshots were generated with `TZ=UTC`. Only the scratch market
path in human stdout was replaced with `<MARKET>`; other bytes are unchanged.
The `.dat` files are actual Swift-written stores, not handcrafted JSON.

Coverage ledger: account `Oracle USD` (USD); deposit 5000 on 2026-06-01;
buy 5 shares each of FAST, GAPPY, NOPE at 10 on 2026-06-10; deposit 100
HKD and 100 JPY on 2026-06-15. Import `series.csv` with `dit market import`.

Snapshots: `market coverage --to 2026-10-01`, both human and global
`--json`, plus variants:

- from: `--from 2026-08-01 --to 2026-10-01`
- empty: `--to 2026-03-01`
- filter: `--tickers GAPPY --to 2026-10-01`
- unmatched: `--tickers ZZZ --to 2026-10-01`
- usd: `--reporting-ccy USD --to 2026-10-01`

Show snapshots: `market show --symbol GAPPY --days 3`, and
`market show --symbol GHOST`.

Derived fixture: account BF (CAD), tickers TSLA.NE (CAD) and TSLA (USD),
buy 10 TSLA.NE at 30 on 2026-09-15, import `derived-seed.csv`, then
`--offline market backfill TSLA.NE --from TSLA`. Snapshot:
`market show --symbol TSLA.NE --days 9` (UTC).

Tests consume these fixtures without running Swift or accessing the network.
