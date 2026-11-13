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
scripts/build.sh                 # build with the version in version.txt (unchanged), writes .build/dit
scripts/build.sh --inc-version   # for publishing: bump the revision, then build
.build/dit --version             # dit X.Y.Z (YYYYMMDD.HHMMSS)
.build/dit help
```

`--inc-version` is for builds that go out the door (a GitHub release);
everyday builds stamp the current version and leave `version.txt` alone.

The Swift comparison harnesses have been removed; build and test the Go CLI
with the commands above. `docs/PORT.md` retains the results of the last
comparison runs.

## Reporting and data tools

Beyond the live summary, `dit` offers past-dated and bulk tools:

- **As-of reports.** `dit summary --as-of DATE` (or `account show NAME --as-of
  DATE`) replays the ledger to a past day: later transactions are excluded and
  positions are priced from the last *stored* close on or before that day, never
  a live quote. `--time-series` (add `--daily` for a day-by-day walk, or bound
  with `--as-of-from`/`--as-of-to`) prints a net-worth series — unbounded it
  shows the last twelve month-ends, an explicit window is reported in full.
  Where no FX rate exists for a past day the converted total is dashed rather
  than invented.
- **Income statement.** `dit income [--year YYYY | --since D --to D] [--account
  A]` lists dividends and GIC interest (cash income) in the window — `--year`
  means that calendar year, not that year up to today — per currency and never
  blended across currencies. Trading/realized P&L is `dit pnl`.
- **Display currency.** `account show` reports in the account's own currency by
  default; an explicit `--display CCY` overrides that.
- **Dry runs.** `import`, `store import`, `rollback`, and `tx import` accept
  `--dry-run`: they validate and report what they *would* change, then write
  nothing.
- **Bulk transaction import.** `dit tx import FILE` loads deposits, withdrawals,
  buys, sells and dividends from CSV. It is all-or-nothing (one malformed row
  aborts the whole import with the store untouched) and idempotent (rows that
  match an existing transaction are skipped; `--allow-duplicates` to override).
- **Changed-under-you guard.** Before a whole-store replace (`import`, `store
  import`, `rollback`, `tx import`) `dit` re-checks the stored bytes against
  what it first read and refuses if they changed (a background sync, or a second
  `dit`), so it never silently clobbers data that arrived mid-command. Set
  `DIT_ALLOW_CONCURRENT=1` to force the replace anyway. This is detection, not a
  lock: it cannot make a synced folder safe to write from two machines in the
  same instant; the automatic pre-replace backup is the recovery path for that.

There is **no second quote provider**, by decision rather than as a gap: the
market commands use Yahoo (alone with the offline test stub). An alternate
provider would need a concrete endpoint plus a way to exercise it offline; one
unverified endpoint was judged worse than none.

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

## Network

`dit` can publish its local stores over the network, and commands can run
against a remote machine's stores:

- **Serving.** `dit serve [PORT]` (default 8348; `--host ADDR` to restrict
  the bind; Ctrl-C to stop) exposes the local stores over HTTP. Serving is
  **mutable by default**: connected commands can read AND change the
  portfolio. Add `--immutable` to serve read-only — reads work, every write
  is refused. Without `--token`, anyone who can reach the port has access;
  `--token TOKEN` (or `--token=` to generate and print one) requires
  authentication. The banner prints the address and the exact
  `dit connect` line for clients.
- **Connecting.** `dit connect HOST:PORT [--token TOKEN]` remembers a remote
  as the active target: subsequent commands (`summary`, `tx`, `pnl`, …) run
  against that machine's stores, and every result is prefixed with a
  `━━━ 🌐 REMOTE host:port · mutable ━━━` tag (on stderr in `--json` mode).
  If the remote is `--immutable`, the connection is recorded read-only and
  write commands fail fast with a clear error. `dit disconnect` clears the
  target and returns to the local stores. The target, token and read-only
  state are saved in `~/.dit/config.json`; `DIT_REMOTE_URL` /
  `DIT_REMOTE_TOKEN` / `DIT_REMOTE_READONLY` override it. Connecting is a
  pointer, not a mirror: nothing is copied or changed by connecting.
- **Cloning.** `dit clone [HOST:PORT] [--yes] [--force]` pulls the remote's
  whole portfolio (ledger + market data) into the local stores, exactly like
  `dit import`: the current local stores are backed up first
  (`--force` skips the backup) and the replacement is confirmed (`--yes`
  skips it). Cloning writes only the local stores — the remote is never
  touched — and works against an `--immutable` serve.

- **Reports for remote UIs.** `POST /api/v1/run` with a body of
  `{"args": ["command", …]}` runs one documented command in-process on the
  served documents and returns its output — dit's own `--json` envelope for
  commands that have a schema (`summary`, `accounts`, `account show`,
  `quote`, `pnl`, `income`, `market coverage`), rendered text for the rest.
  The command is allowlisted: the portfolio is never written through the
  endpoint, and the market-write commands (`update`, `market latest`,
  `market backfill`) only on a mutable server. The exit code maps to the
  HTTP status (200/400/500); on a non-zero exit the engine's stderr travels
  in the `X-Error` header. This is what lets a GUI on another machine —
  the iPhone client in Pythonista's documents — render real dit reports:
  the engine runs where the data lives, the client stays a renderer.
  `GET /api/v1/info` advertises the capability in its `run` field.

While a connection is active, writes go to the REMOTE stores under the same
rules as local ones: the changed-under-you guard re-checks the remote
document before a whole-store replace, and the pre-replace backup snapshots
the remote documents into the local `~/.dit/backup` directory. `dit serve`
always publishes the local stores of the machine running it — it never goes
through a saved connection.

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
