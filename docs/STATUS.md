# Measured status

The Go `dit` CLI is implemented and tested against the Swift reference. Current
verification (2026-10-12):

```sh
go test ./...
go build -o .build/ditgo ./cmd/dit
scripts/twin-run.sh
MARKETWRITE=1 scripts/twin-run.sh
PTY=1 scripts/twin-run.sh
```

Results from recent runs:

| Instrument | Result |
|---|---|
| `go test ./...` | All packages pass |
| Deterministic twin probes | 208/208 identical; a live summary can vary when the provider updates between runs |
| Market-write twin probes | 226–227/228 identical; remaining differences are live-market drift |
| PTY twin probes | 207–208/208 identical; any difference is live-market drift |
| Scenario e2e against the Go binary | 407/407 pass |

The live probes call a changing market-data source sequentially, so their
prices and timestamps are not expected to be byte-identical. The offline
scenario suite is deterministic.

See [PORT.md](PORT.md) for the port map, parity notes, and known intentional
behavioral difference concerning stale stored closes after a failed quote.
