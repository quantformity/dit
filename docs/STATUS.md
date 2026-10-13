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

See [PORT.md](PORT.md) for port notes and remaining behavioral distinctions.
