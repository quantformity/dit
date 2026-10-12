package cli

const updateUsage = `USAGE: dit [command] [options]

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
  --store PATH, --market-store PATH, -h/--help. Flags override
  environment variables. Exit codes: 0 success, 1 runtime
  error, 2 usage error.`
