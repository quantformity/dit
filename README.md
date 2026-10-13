# dit (Go)

Go implementation of the `dit` personal portfolio CLI. It reads and writes the
same file and SQLite stores as the Swift reference.

The Go CLI was previously compared against the Swift reference across the
baseline command probes. Deterministic behavior matched; live quote results
could differ as market data changed. See [docs/PORT.md](docs/PORT.md) for the
recorded results.

## Build and test

Requirements: Go 1.27.2 or newer.

```sh
go test ./...
scripts/build.sh                 # increments version.txt, embeds build time, writes .build/dit
.build/dit --version             # dit X.Y.Z (YYYYMMDD.HHMMSS)
.build/dit help
```

The Swift comparison harnesses have been removed; build and test the Go CLI
with the commands above. `docs/PORT.md` retains the results of the last
comparison runs.

## Backups

`dit backup` writes paired timestamped portfolio and market documents plus
`metadata.json.YYYYMMDD.HHMMSS` under `~/.dit/backup`. Metadata records the
`dit` version, backup time, ledger/market counts, and offline cost-basis totals
by currency. `dit rollback --list` lists backups; `dit rollback TIMESTAMP`
restores one after confirmation (use `--yes` for non-interactive use), while
also backing up the current state first.

## Store configuration

On first run, `dit` creates `~/.dit/config.json` containing
`{"DIT_STORE_URL":"~/.dit/portfolio.dat","DIT_MARKET_URL":"~/.dit/market.dat"}`.
Both paths are configurable there, or with `dit config set`:

```sh
dit config set store '~/Sync/dit/portfolio.dat'
dit config set market '~/Sync/dit/market.dat'
```

The file backend stores the portfolio and market documents at
`~/.dit/portfolio.dat` and `~/.dit/market.dat`; the legacy Application Support
store is copied there on first initialization when present (the original files
are preserved). Flags override environment variables, which override the user
config.

## Layout

```
cmd/dit/              CLI entry point
internal/decimal/     exact base-10 arithmetic
internal/model/       portfolio and market models / wire compatibility
internal/store/       file and SQLite persistence
internal/config/      store location and backend resolution
internal/cli/         command implementations and rendering
internal/ledger/      transaction views and statements
internal/market/      market history, backfill, and coverage
internal/provider/    Yahoo and test providers
testdata/             fixtures and parity goldens
scripts/              parity, e2e, and test tools
docs/                 port status and command-lane notes
```

The separate `dit-chart` companion is not included in this Go project.
