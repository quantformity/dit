# dit (Go)

Go implementation of the `dit` personal portfolio CLI. It reads and writes the
same file and SQLite stores as the Swift reference.

The twin harness covers 208 baseline probes. Deterministic behavior matches
the reference; probes that fetch live quotes may differ because market data
changes between invocations. See [docs/PORT.md](docs/PORT.md) for measured
results and parity details.

## Build and test

Requirements: Go 1.27.2 or newer.

```sh
go test ./...
go build -o .build/dit ./cmd/dit
.build/dit help
```

The parity harnesses (`scripts/twin-run.sh`, `scripts/parity.sh`) use the Swift
reference binary at `/opt/homebrew/bin/dit` by default. They are optional for
building and using the Go CLI. `MARKETWRITE=1` adds market-write probes;
those and the PTY run may include nondeterministic live quote differences.

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
