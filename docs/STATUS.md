# Measured status

The Go `dit` CLI passed its unit tests and was compared against the Swift
reference before the comparison scripts were removed.

Current checks:

```sh
go test ./...
scripts/build.sh
```

Recorded results from the final comparison period (2026-10-12):

| Check | Result |
|---|---|
| `go test ./...` | All packages pass |
| Baseline command probes | 207–208/208 identical; occasional live-summary drift |
| Market-write probes | 226–227/228 identical; remaining differences were live-market drift |
| PTY probes | 207–208/208 identical; any difference was live-market drift |
| Scenario suite against Go | 407/407 pass |

The comparison scripts have been removed; these figures are historical. Live
prices and timestamps varied between sequential requests, while the offline
scenario suite was deterministic.

## Features added after the port

These are Go-side additions with no Swift counterpart (so the byte-for-byte
parity figures above do not cover them); each is covered by its own Go tests:

- As-of / historical reports: `summary --as-of`, `--time-series`, `--daily`,
  `account show --as-of`. Store-only; dashes FX it cannot source.
- `dit income [--year|--since|--to] [--account]` — dividends + GIC interest,
  per currency. `--year` means that calendar year (a future year is an empty
  window, not an error).
- `--display` override on `account show` (and a `main.go` fix: `DisplaySet` was
  never set, so the override had been inert).
- `--dry-run` on `import`, `store import`, `rollback`.
- `dit tx import` — bulk CSV, all-or-nothing, idempotent, offline.
- Changed-under-you guard on whole-store replaces (`DIT_ALLOW_CONCURRENT=1` to
  override).

**Not wanted:** a second quote provider. Market commands use Yahoo only, and
that is a decision, not a gap — an alternate provider would need a concrete
endpoint plus an offline way to exercise it, and an unverified endpoint was
rejected as worse than not shipping one.

See [PORT.md](PORT.md) for port notes and remaining behavioral distinctions.
