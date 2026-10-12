# Lane: provider/2 — live marks (continued, session 2)

Status: **delivered** — summary prices from live (or pinned) observations, says
where the numbers came from, degrades to cost loudly when it cannot, and never
touches the network under `go test` or `--offline`.

## What the summary does now

- **Live default.** For each open position the summary asks the provider for
  the last price and its stamp, marks the position at that price (converted via
  the hub FX rate when the currency differs), and computes **day change =
  latest mark vs the previous stored close** of the same ticker — which is
  exactly the oracle's model-comparison day change, now actually present.
- **Provenance and staleness.** Each priced holding carries its quote block:
  `price`, `asOf`, `source`, and the `previousClose` (date + price) the day
  change is measured against. A quote older than a minute gets the oracle's
  "market may be closed, prices may be stale" note; a dead network gets
  *what failed* in the notes and `degraded: true` — never a silent zero.
- **`--offline` unchanged**: cost basis, no FX, no day change, `offline: true`
  and the offline note. It is the safe default with no connectivity, and the
  only mode that is.
- **Pinned runs.** `DIT_PROVIDER_STUB=<file.json>` makes the summary a pure
  function of (ledger, market document, pin) — the twin-run and e2e harnesses
  pin this way, which removes the network from regression entirely. The pin
  answers what it knows (a missing symbol is a data answer, like Yahoo's
  NOT_FOUND) and fails what it does not (a missing rate, or a scripted
  `transportError`, is a connection answer that drives the degraded path,
  exactly like a dead wire).

## Observation surface (committed)

- `internal/provider/provider.go` — the boundary: `Provider{Quotes, Rate}`
  function values (a function value is the most direct Go expression of an
  interface, per the house style), `Error{Kind, Symbol, Message}`, `Cache`
  (newer-wins per symbol and per pair, bidirectional rates, hub-routed pairs,
  self-initializing maps) and the `normalizeSymbol` / `parseCurrency` helpers
  — Yahoo and the pin normalize identically, as they must.
- `internal/provider/yahoo.go` — the live fetch: browser-fingerprinted chart
  calls, per-request budget (5s default), concurrent batch, meta-shape
  parsing (`regularMarketPrice` / `regularMarketTime` — the shape Yahoo
  actually returns), and the error taxonomy below.
- `internal/provider/stub.go` (`LoadStub`) — the pin.
- `internal/valuation/valuation.go` — the `Mark` boundary:
  `Mark{Price, Baseline, Rate}` plus `storedMark` (today's stored close,
  refused when the series currency is unknown), `Live` (provider mark +
  previous stored close) and the cost basis as its own mark. `Compute` keeps
  its signature and delegates.
- `internal/cli/summary.go` — plan (positions + the non-hub currencies in
  play), fetch (notes on failure), value the ledger against the mark, and the
  note stack: fetch failures → staleness → offline → the unconverted-totals
  warning. `SummaryJSONLive` carries the quote blocks.

## Error taxonomy (the honest split)

Two kinds of "no number", and they are reported differently because they
mean different things:

- **A data answer** — the market said "no": an API refusal (429, NOT_FOUND),
  a chart without a price, a symbol the pin does not know. The symbol is left
  unquoted, the position marks at cost, and nothing is hidden — the JSON has
  no quote block for it, and the note says so.
- **A connection answer** — the wire said nothing: timeouts, resets, a pin
  that names a transport failure, and — the subtle one — a *mixed* batch
  where the result came back empty and at least one failure was on the wire.
  An empty result whose losses may include wire failures is not trustworthy:
  we cannot know whether a symbol is unanswerable or merely unreachable. That
  is reported as a fetch failure, because the difference is precisely
  "the position is worth its cost *because we could not price it*", and a
  user who knows that can act on it (retry, wait, look elsewhere) in a way
  they cannot on an unexplained cost number.

A batch that got at least one quote still succeeds: the rest stay unquoted.
That is the same distinction the oracle draws on the text side (per-symbol
warnings vs an erroring fetch), expressed for the Go side's structured
errors.

## Decisions and their reasons

- **Function values for the boundary**, not named interfaces. Two methods is
  the interface either way; the function value is the most direct thing Go
  offers, and the tests inject them as ordinary values — no mock framework,
  no socket, no fake TLS context. `go test` opens zero connections.
- **Previous close from the store, last price from the market** — not two
  market calls. It matches how the oracle computes day change in model
  mode (where it is the only option), it halves the requests, and it keeps
  "what happened to this stock" comparable across sessions on one
  time-anchored series.
- **A pin that cannot be read is a connection failure, not empty data** —
  `providerForCommand` turns the failure into a provider whose every call
  errors with why. The alternative (silently price nothing) would make a
  typo in a path look like a quiet market.
- **The pin's `transportError` field** stands in for a dead network in
  deterministic tests. Degradation is a first-class, testable path this way:
  same code path as the real outage, asserted byte-for-byte.

## Verification

- `go build ./... && go test ./...` — all packages pass, no network:
  Yahoo's parse paths, error taxonomy and batch semantics run against canned
  responses; the CLI summary tests run against pins, a scripted outage, and
  `--offline`.
- `scripts/provider-e2e.sh` — **PASS**: two pinned runs are identical apart
  from the clock line; the pin prices the holding (6 × 243.83 = 1.462.98),
  the quote block carries the pin and its previous stored close (93.10),
  the day change is measured against it (904.38), and the run is not
  degraded.
- `scripts/twin-run.sh` — **10/16, unregressed from baseline**: every probe
  that passed on the stored-mark summary (offline summary text included,
  which must be byte-identical) still passes. The six that differ remained
  differing (they differed before this lane as well): the summary's *live* numbers
  (the pin and the oracle's own fetch answer differently — expected; the
  structure now matches: quote blocks, note stack, degraded flag) and the
  text/JSON rendering gaps the other lanes track.

## What remains for `dit summary` to be the answer the user wants

1. **The Yahoo live path against the real network** — the parse paths are
   tested against canned responses in the shape Yahoo actually returns; a
   first real-market run should be watched once (429s, cookies, rate limits
   are behavioural, not structural).
2. **The pin's `asOf` is fixed text** — the e2e asserts values, not
   freshness, so it stays honest as the clock moves; a demo pin that stays
   "fresh" needs regeneration at demo time.
3. **Probes for the new structure** (quote block, `degraded`, the note
   stack) in `twin-run.sh` once a pinned oracle run is scriptable — the Go
   side already emits and tests exactly that shape.
