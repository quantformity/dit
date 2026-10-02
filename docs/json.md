# Machine-readable output (`--json`) — schema contract

`dit --json` exists so **programs — scripts, AI agents, dashboards —
can read `dit` without parsing tables.** It is the same derived data
the human tables show, serialized under a stable contract. Anything
that would be `—` or "unknown" for a human becomes `null`; nothing is
ever invented to fill a field.

This file is the contract. Its executable counterparts are
`Tests/DitCoreTests/JSONOutputTests.swift` and the
"Machine output" section of `scripts/scenario-e2e.sh`: if a schema
changes, those change with it and the version bumps — never silently.

## The envelope

Success and failure share stdout so a caller has exactly one parse
path. Output is exactly ONE compact JSON document — no prose headers,
no tables — even on errors.

```json
{"ok":true,"schema":"summary/1","data":{ … }}
```

```json
{"ok":false,"kind":"runtime","error":"Cannot find portfolio at /path/to/store"}
```

```json
{"ok":false,"kind":"usage","error":"--json is not supported for 'tx list' — use plain output"}
```

- Exit codes are unchanged by `--json`: **0** success, **1** runtime
  error, **2** usage error. `kind` is `"runtime"` or `"usage"`
  respectively, so a caller can also branch on the document alone.
- `schema` is a versioned document type (`"summary/1"`, `"quote/1"`,
  …). Breaking changes bump the version; new optional keys are
  additive and documented here.
- Commands with no JSON schema **refuse** `--json` (usage error, exit
  2) rather than emit a table pretending to be data.
- Keys are serialized alphabetically (`.sortedKeys`) for byte-stable
  output; parse by key, never by position or order.

## Supported commands

| Command | Document |
|---|---|
| `dit [--offline] --json summary` | `summary/1` |
| `dit --json accounts` | `accounts/1` |
| `dit --json account show NAME [--history]` | `account/1` |
| `dit --json quote SYM… [--as-of DATE \| --from DATE --to DATE]` | `quote/1` (live / store / series) |
| `dit --json quote CCY/CCY/CCY[/…] [--as-of DATE]` | `quote/1` (`"mode":"matrix"`) |
| `dit --json pnl [window/filter options]` | `pnl/1` |
| `dit --json tx pnl [--account A] [--ticker SYM]` | `tx-pnl/1` |
| `dit --json market coverage [window/filter options]` | `coverage/1` |

Everything else refuses. `--json` takes no value (`--json=1` is a
usage error). The flag is position-independent (before or after the
command).

**Machine consumers**: `dit-chart` (same package) pipes these documents
into charts — `dit --json | dit-chart [--ascii]` for terminal bars
(`summary/1` only), or `dit --json | dit-chart --html page.html` for
one interactive page (`summary/1` plus `quote/1` time series).
Anything else is refused with exit 1, and
renders `null` amounts as dashes, never zeros — the
conventions in this file are exactly what it depends on.

## Global value conventions

| Kind | Encoding | Example |
|---|---|---|
| Money | decimal **string**, 2 places | `"value": "278182.80"` |
| Ratios (pnlPct, dayPct) | decimal string, 4 places, FRACTION | `"dayPct": "-0.0214"` |
| Share quantities | decimal string, up to 4 places, trimmed | `"shares": "96.7"` |
| FX rates | decimal string, 6 places | `"1.418700"` |
| Day | `YYYY-MM-DD` (UTC) | `"date": "2026-09-28"` |
| Timestamp | ISO-8601 UTC seconds | `"asOf": "2026-09-29T16:43:56Z"` |
| Unknown / not applicable | `null` | `"dayChange": null` |

Rules that hold across every document:

1. **Financial quantities are strings, never JSON numbers.** Doubles
   would break the package's exact-`Decimal` discipline and invite
   float math on money. Parse with `Decimal`/`BigDecimal`/decimal
   libraries; floats only for throwaway display.
2. **`null` means "no data", not zero.** A `null` day change means no
   previous close existed for the pair — a `0.00` there would be a
   lie. A real zero is the string `"0.00"`.
3. **Currency is a field, never formatting.** No grouping separators,
   no symbols; every amount has an explicit or surrounding currency.
4. **Provenance is data.** Prices carry `via`/`basis`/`source` fields.
   `via: null` means an OBSERVED price (fetched or imported); a
   non-null `via` names the model that produced the number. Never
   treat a derived number as a quote.
5. **Native and display-currency figures are separate fields.**
   `value`/`pnl`/`dayChange` are NATIVE-currency amounts;
   `*Display` siblings are the display-currency conversions (null when
   no conversion rate exists — never a native amount smuggled into a
   converted column). Percentages (`pnlPct`, `dayPct`) are
   NATIVE-currency ratios: FX drift must not masquerade as trading
   gain, so don't convert them.

## `summary/1`

`dit --json summary` — portfolio-wide valuation.

```json
{"ok":true,"schema":"summary/1","data":{
  "accounts":[{"cash":"0.00","dayChange":"-6440.20","gic":"0.00",
               "id":"ADF0D1C1-1818-4285-8AC5-ADF424609146","name":"HSBC",
               "positions":"342285.00","reportingCurrency":"USD",
               "total":"342285.00","unrealizedPnl":"180728.00"}],
  "degraded":false,
  "displayCurrency":"CAD",
  "generatedAt":"2026-09-29T16:43:56Z",
  "holdings":[ …see below… ],
  "offline":false,
  "store":"/path/to/store",
  "totals":{"byCurrency":{
              "CAD":{"cash":"67478.98","dayChange":"-406.60","gic":"5000.00",
                     "positions":"154522.35","total":"227001.33"},
              "USD":{"cash":"2343.52","dayChange":"-6073.51","gic":"0.00",
                     "positions":"583436.54","total":"585780.05"}},
            "cash":"70805.60","dayChange":"-9027.95","dividends":"0.00",
            "gic":"5000.00","positions":"982710.51","realizedPnl":"6629.06",
            "totalValue":"1058516.11","unrealizedPnl":"407519.10"},
  "untrackedShorts":[],
  "warnings":[]
}}
```

A holding row (shown with its quote; keys alphabetical):

```json
{"accounts":["HSBC"],"avgCost":"153.65","ccy":"USD",
 "dayChange":"-6073.19","dayChangeDisplay":"-8620.90","dayPct":"-0.0214",
 "name":"Apple Inc.","pnl":"149116.80","pnlDisplay":"211671.30","pnlPct":"1.1554",
 "quote":{"asOf":"2026-09-29T16:43:56Z",
          "previousClose":{"date":"2026-09-28","price":"338.40","via":null},
          "price":"331.17","source":"yahoo"},
 "shares":"840","symbol":"AAPL","value":"278182.80","valueDisplay":"394880.48"}
```

Semantics a caller can rely on:

- **`quote` present ⟺ the holding was priced from a market quote.**
  Its absence means the row is valued at cost (offline mode, unknown
  ticker). Inside it, `previousClose` is ALWAYS present — `null` when
  no earlier daily close exists — so provenance lookup never branches
  on key existence.
- `quote.previousClose` is the baseline behind `dayChange`/`dayPct`:
  the last stored close strictly BEFORE the quote's own day, however
  old. `via: null` = observed; `"derived via TSLA ÷ 16.2645"` = a
  `market backfill` model value — an approximation, labelled.
- `dayChange`/`dayPct` are `null` (never `0.00`) when the baseline or
  the quote is missing. The pair is only used when it describes the
  price actually displayed.
- `pnlPct`/`dayPct` are ratios (1.1554 = +115.54%) over the NATIVE
  cost basis; `null` when cost basis is zero/negative or shares ≤ 0.
- **Top-level `totals` are DISPLAY-currency** sums converted once at
  the total; `totals.byCurrency` holds the exact native components.
  Do not expect the components to add to the total by hand unless
  there is one currency — conversion happens at the total, by design.
- `accounts[].positions` is derived `total − cash − gic` when all
  three exist; any missing part makes the combined fields `null`.
- `untrackedShorts`: symbol-level short positions that cannot be
  confirmed per account (known data-import limitation), as objects
  `{account, ccy, shares, symbol}`.
- `warnings`: ledger-level honest caveats (overdrafts etc.) — surface
  them.
- `offline: true` means NO pricing happened at all: holdings carry no
  `quote`, and value/percentage fields are `null` or cost-basis
  figures. It is a request mode, not an error.
- `degraded: true` means the market store was unreadable and skipped
  — day-change data unavailable, never guessed.

## `accounts/1` — `dit --json accounts`

Registry listing only — no balances (that is `account/1`).

```json
{"ok":true,"schema":"accounts/1","data":{"accounts":[
  {"currency":"CAD","id":"E0C1800A-…","institution":null,"name":"CAD TSFA",
   "number":null,"status":"open","taxable":false},
  {"currency":"USD","id":"043CBF1A-…","name":"USD Margin","status":"open",
   "taxable":true,"…":"…"} ]}}
```

- `status` is `"open"` or `"closed YYYY-MM-DD"`.
- `opened` (a `YYYY-MM-DD` string) appears only when the opening date
  is known.
- A portfolio with no accounts yields `"accounts": []` — an honest
  "nothing recorded yet", not an error. A MISSING store is a runtime
  error envelope instead.

## `account/1` — `dit --json account show NAME [--history]`

Offline by construction: no network, no quotes — positions are COST
data. Do not read this document as a valuation.

```json
{"ok":true,"schema":"account/1","data":{
  "account":{"currency":"USD","id":"…36 chars…","name":"HSBC",
             "status":"open","taxable":true},
  "balances":{"cashByCurrency":{"USD":"-487.32"},
              "dayChangeByCurrency":{},
              "dividendsByCurrency":{"USD":"126.10"},
              "gicByCurrency":{},
              "realizedPnlByCurrency":{"USD":"6629.06"},
              "unrealizedPnlByCurrency":{"USD":"180728.00"}},
  "history":[
    {"currency":"USD","date":"2024-12-31",
     "detail":"deposit 161557 USD",
     "id":"893B51DC-F23F-4572-97D9-DACAF8A68943","kind":"deposit"},
    {"currency":"USD","date":"2025-01-01",
     "detail":"buy 840 AAPL @ 153.65",
     "id":"7BCAF1E1-B4DF-47E5-A543-C1ADD2BCA2F9","kind":"stockPurchase"}],
  "positions":[{"avgCost":"153.65","ccy":"USD","costBasis":"129066.00",
                "shares":"840","symbol":"AAPL"}],
  "untrackedShorts":[]
}}
```

- `history` appears ONLY with `--history`; `[]` means no recorded
  activity. The table form truncates ids to 8 characters — machine
  output never does: `id` is always the FULL 36-character transaction
  UUID.
- `kind` is a stable machine token (`deposit`, `stockPurchase`,
  `stockSale`, `dividend`, `gicPurchase`, …); `detail` is the
  human-readable rendering of the entry — display it, don't parse it.
- `positions[].costBasis` is COST (what you paid), explicitly not a
  market value; `shares` can be negative in the untracked-short case.
- Negative `cashByCurrency` values are recorded overdrafts — real
  state, not errors.

## `quote/1` — `dit --json quote SYM… [--as-of DATE] [--from DATE] [--to DATE]`

Three modes: live (default), store (`--as-of`), series (`--from`
and/or `--to`).

**Live mode** (default; fetches — `--offline` refuses):

```json
{"ok":true,"schema":"quote/1","data":{"mode":"live","quotes":[
  {"asOf":"2026-09-29T16:43:56Z","basis":"live","ccy":"USD",
   "price":"331.17","source":"yahoo","symbol":"AAPL"},
  {"asOf":null,"basis":"none","ccy":null,"price":null,
   "source":null,"symbol":"GHOST"} ]}}
```

**Store mode** (`--as-of DATE`; reads the market store, no network,
works with `--offline`):

```json
{"ok":true,"schema":"quote/1","data":{
  "asOf":"2026-09-21","mode":"store",
  "store":"/path/to/market",
  "quotes":[
    {"basis":"derived","ccy":"CAD","date":"2026-09-21","lagDays":0,
     "price":"32.38","symbol":"TSLA.NE","via":"derived via TSLA ÷ 16.2645"},
    {"basis":"observed","ccy":"USD","date":"2026-09-21","lagDays":0,
     "price":"375.30","symbol":"TSLA","via":null},
    {"basis":"none","ccy":null,"date":null,"price":null,
     "symbol":"GHOST","via":null} ]}}
```

- `basis` vocabulary — `live`: fetched right now; `observed`: a real
  close stored earlier (fetched or imported, `via: null`); `derived`:
  MODEL output from `dit market backfill` (underlying × FX ÷ a
  calibrated ratio — an approximation while the peg holds, `via` names
  the recipe); `none`: no data exists, `price: null`.
- FX pairs (`USD/CAD` etc.) in live mode carry the rate as a
  6-place decimal string (money prices use 2 places — a rate rounded
  to cents is a different number), `ccy` = quote currency, price =
  quote per 1 base.
- In store mode the top-level `asOf` is the REQUESTED day; each
  quote's `date` is when its price was OBSERVED, and `lagDays` says
  how stale it is. A close found earlier than the requested day is
  reported with its actual date — never silently presented as the
  requested day. `lagDays` is absent for `basis: "none"`.
- Unknown symbols are data (`basis: "none"`, `price: null`). If EVERY
  requested symbol is missing, you instead get an error envelope
  (kind `runtime`, exit 1) — total silence is not success.

**Series mode** (`--from`/`--to`; also store-read, works offline):

```json
{"ok":true,"schema":"quote/1","data":{
  "count":3,"from":"2026-09-23","mode":"series",
  "quotes":[
    {"basis":"observed","ccy":"USD","date":"2026-09-23","price":"380.12",
     "symbol":"TSLA","via":null},
    {"basis":"derived","ccy":"CAD","date":"2026-09-23","price":"32.7002",
     "symbol":"TSLA.NE","via":"derived via TSLA ÷ 16.396"},
    {"basis":"none","ccy":null,"date":null,"price":null,
     "symbol":"GHOST","via":null} ],
  "store":"/path/to/market","to":"2026-09-26"}}
```

- `quotes` is a flat list of dated points (per symbol, oldest day
  first). `count` counts real points only — a `basis: "none"` marker
  row is a marker, not a point.
- `from`/`to` echo the request; `null` means that end was open
  (`--from` alone runs to today; `--to` alone starts at the earliest
  stored day). Bounds are INCLUSIVE.
- A symbol with no point in the range appears once as
  `"basis": "none"`; a range empty for EVERY symbol is an error
  envelope (exit 1).

**Matrix mode** (3+ currency chain, single day — `--from`/`--to`
refused with exit 2). Example (`--as-of`, store-read):

```json
{"ok":true,"schema":"quote/1","data":{
  "asOf":"2026-09-28","count":6,"currencies":["USD","CAD","HKD"],
  "mode":"matrix","pairCount":6,"query":"USD/CAD/HKD",
  "rates":[
    {"base":"USD","basis":"observed","date":"2026-09-28","quote":"CAD",
     "rate":"1.418300"},
    {"base":"CAD","basis":"reciprocal","date":"2026-09-28","quote":"USD",
     "rate":"0.705069"},
    {"base":"CAD","basis":"derived","quote":"HKD","rate":"5.527744",
     "via":"triangulated via USD"},
    {"base":"HKD","basis":"reciprocal","date":"2026-09-28","quote":"USD",
     "rate":"0.127551"} ],
  "store":"/path/to/market"}}
```

(excerpt — a 3-currency chain has 6 rate entries; the two triangulated
CAD↔HKD rows are elided. A `"basis": "none"` entry, `"rate": null`,
appears when neither a direct pair nor both USD legs are known)

- `rates` carries every DIRECTIONAL pair (n×(n−1) entries, no
  diagonal); `pairCount` = entries, `count` = entries that actually
  have a rate. Rates are 6-place strings, quote-ccy per 1 base.
- `basis`: `observed` (direct quote/series, has `date` in store mode)
  → `reciprocal` (exact inversion of the observed reverse pair — same
  measurement, other direction) → `derived` (triangulated through two
  USD legs, carries `"via": "triangulated via USD"`, no date: it is
  a model number, not a quote) → `none` (`"rate": null`, no
  invention).
- `asOf`: requested day (store) or fetch stamp (live); `null` for
  plain `--offline` ("latest stored"). Unknown codes inside the chain
  and mixing the chain with other requests are usage errors (exit 2,
  error envelope under `--json`); a chain where NOT one rate is known
  is a runtime error (exit 1).

## `pnl/1` — `dit --json pnl [WINDOW & FILTER OPTIONS]`

Windowed historical P&L. One document, two honest halves: `realized`
(ledger fact, always exact) and `positionChange` (mark-to-mark drift,
only when a price pair exists). Amounts are fixed 2-decimal strings;
an **unmeasurable** value is `null`, never `"0.00"` and never a
partially-known sum.

```json
{"ok":true,"schema":"pnl/1","data":{
  "window":{"label":"custom","start":"2026-07-01","end":"2026-07-31","fromLedgerStart":false},
  "scope":{"accounts":"all","tickers":"all","currencies":"all","reportingCurrency":"CAD","perAccount":false},
  "positions":[{"symbol":"WIDE","kind":"position","accounts":["P&L One"],"currency":"USD",
                "realized":"22.00","positionChange":"5.00","total":"27.00","basis":"observed",
                "reported":{"realized":"30.80","positionChange":"7.00","total":"37.80"}}],
  "currencyTotals":[{"currency":"USD","realized":"36.00","positionChange":"5.00","total":"41.00",
                     "incompletePositions":0,"reported":"57.40"}],
  "combined":{"currency":"CAD","value":"57.40","at":"2026-07-31","rates":"USD→CAD 1.4 at 2026-07-31"},
  "activityCount":3,"notes":[]}}
```

The same ledger with NO usable daily history — the gap stays visible
(and with it, every CAD conversion, so `reported` is all-null):

```json
{"ok":true,"schema":"pnl/1","data":{
  "positions":[{"symbol":"WIDE","kind":"position","accounts":["P&L One"],"currency":"USD",
                "realized":"22.00","positionChange":null,"total":null,"basis":null,
                "reported":{"realized":null,"positionChange":null,"total":null}}],
  "currencyTotals":[{"currency":"USD","realized":"22.00","positionChange":null,"total":null,
                     "incompletePositions":1,"reported":null}],
  "combined":null,
  "notes":["no usable daily history for: WIDE — …"]}}
```

Contract details:

- `window.fromLedgerStart` is `true` for the default/`--to` forms
  (window opens at the first trade, where holdings sit at cost).
- `positionChange`/`total` `null` = no price pair for that position
  across the window; `"0.00"` = measured and actually zero. `total`
  is only present when BOTH halves are known (`total` is not
  `realized + 0` pretending to be a full answer).
- `basis`: `"observed"` (real stored closes), `"derived"` (backfilled
  proxy history — an approximation), `null` (no price data at all).
  Never guess from a number alone; check this field.
- `currencyTotals` are **native and exact**: a total is `null` when
  any contributing position is incomplete, and incomplete positions
  are counted in `incompletePositions` (they drop out of the total).
- `reported` (on rows, totals, and series points) is the SAME
  numbers converted to the reporting currency at the DATED FX the
  engine actually used. It appears only where a conversion is
  involved (single-currency documents stay byte-identical) and is
  `null` per part when that part could not be honestly converted —
  never a latest-rate fallback. Read either view, never mix them:
  native fields are ledger facts; `reported` is display arithmetic.
- `combined` is the reporting-currency sum, `null` unless every
  currency converted honestly. `at` names the as-of date, `rates`
  quotes the dated pair rates actually applied (`null` when nothing
  was converted).
- `scope`/`window` echo what was actually applied — filters never
  widen silently, and an empty result is `{"positions":[],
  "currencyTotals":[]}` with exit 0, not an error.
- `kind`: `"cash"` = P&L with no market instrument (GIC redemption),
  `"position"` = keyed by a ticker (a dividend-only line has
  `positionChange:"0.00"` — no position, nothing to mark).

With `--time-series`, `data` additionally carries `"series"`:

```json
"series":{"granularity":"monthly","reconciles":true,
  "collapsedEmpty":18,"collapsedUnmeasurable":0,
  "points":[{"label":"2026-07","start":"2026-07-01","end":"2026-07-31",
              "currencyTotals":[{"currency":"USD","realized":"36.00",
                "positionChange":"5.00","total":"41.00","incompletePositions":0}],
              "reportedTotal":"57.40"}]}
```

- `points` are CONTIGUOUS slices of the window (empty periods are
  collapsed and counted in `collapsedEmpty`); the totals use the
  same native-exact rules as `currencyTotals`. `reportedTotal`
  (mixed-currency documents only) converts the WHOLE period at its
  own end-date FX — `reconciles` stays a NATIVE-amount identity
  because cross-currency sums are display, not arithmetic.
- `reconciles` is the integrity flag: `true` means the slices sum to
  the window total (every period measurable); `false` means at least
  one gap lives in the series — do NOT sum the points into a total.
- `collapsedUnmeasurable` counts periods whose drift was NOT
  computable (no price pair) — a data gap, distinct from
  `collapsedEmpty` (a measured zero). Both are reported, never
  hidden.

## `coverage/1` — `dit --json market coverage [options]`

The market-data audit (see cli.md “Coverage”). Facts, never
valuations — there are no amounts in this document at all.

```json
{"data":
 {
  "auditDate": "2026-10-01",
  "complete": false,
  "fx": [
   {"approx": true, "boundariesMissing": 0, "boundariesTotal": 5,
    "chain": "derived via USD (HKD→USD→CAD)", "from": "HKD",
    "lastClose": "2026-10-01", "staleDays": 0, "to": "CAD",
    "usableNow": true},
   {"boundariesMissing": 5, "boundariesTotal": 5, "chain": "none",
    "from": "JPY", "to": "CAD", "usableNow": false}
  ],
  "notes": [],
  "prices": [
   {"accounts": ["Cov USD"], "currency": "USD", "derived": false,
    "lastClose": "2026-09-29", "points": 112, "staleDays": 2,
    "status": "ok", "symbol": "FAST"},
   {"accounts": ["Cov USD"], "currency": "USD", "derived": false,
    "lastClose": "2026-09-29",
    "longestGap": {"days": 14, "from": "2026-07-19", "to": "2026-08-01"},
    "points": 98, "staleDays": 2, "status": "gaps", "symbol": "GAPPY"}
  ],
  "reporting": "CAD",
  "scope": "all accounts",
  "seriesSlicing": "monthly",
  "window": {"from": "2026-06-01", "to": "2026-10-01"}
 },
 "ok": true,
 "schema": "coverage/1"}
```

- `prices` is one entry per (held symbol, recorded currency) at the
  audit date; `accounts` names the holders. `status` is the FIRST
  failing fact: `no-data` (no series, or no close at/before the audit
  date), `wrong-currency` (series exists but can never be read for
  that position), `stale` (usable but last close > 7 days early),
  `gaps` (holes ≥ 10 days), else `ok`. Shorter missing runs are
  weekend/holiday dust and stay unlisted — by design.
- `fx` is one entry per foreign currency the scope uses. `chain`
  names how the rate would compose today (`… direct`, `inverted …`,
  `derived via USD …`, or `"none"`); `usableNow` means the FX clock
  WOULD answer at the audit date (a chain of too-old legs answers
  nothing → `false` with a `chain` label — the refill remedy, not the
  import one). `boundariesMissing/Total` counts the period ends
  (granularity echoed in `seriesSlicing`) where NO rate would answer —
  each one is a `--time-series` period whose converted column dashes.
  `approx: true` marks a derived chain (same honesty tier as `via`).
- `complete` is the machine verdict (everything covered); `--strict`
  makes it flip the exit code (0 → 1) but never the document shape.
- Keys sort alphabetically like every document; the two stream rules
  above apply. `dit-chart` refuses `coverage/1` (no chart defined).

## `tx-pnl/1` — `dit --json tx pnl [--account A] [--ticker SYM]`

Transaction-level P&L, lifetime, FIFO lot attribution, native
currencies. The same ledger facts `dit pnl` aggregates, sliced per
transaction; the ledger's own accounting stays average cost.

```json
{"ok":true,"schema":"tx-pnl/1","data":{
  "asOf":"2026-10-02","policy":"fifo-lots","scope":"all accounts",
  "booked":[{"account":"P&L One","currency":"USD","date":"2026-07-10",
    "detail":"5 sh @ 8 − cost 25.00","id":"4C54C9E2-…","incomplete":false,
    "kind":"sell","pnl":"15.00","symbol":"WIDE"}],
  "open":[{"account":"P&L One","bought":"10","cost":"25.00",
    "currency":"USD","date":"2026-06-10","held":"5",
    "id":"B0B1C2D3-…","mark":"8","markDay":"2026-07-31",
    "markKind":"stored","symbol":"WIDE","unrealized":"15.00"}],
  "currencyTotals":[{"booked":"22.00","currency":"USD",
    "open":"15.00","total":"37.00"}],
  "notes":[]}}
```

- `booked` rows are chronological; `kind` is `sell`, `dividend`, or
  `gic-redemption`. All amounts are NATIVE (this view never converts)
  and `pnl` already nets fees. `incomplete: true` marks an untracked
  short — its currency total is then withheld (`"total": null`).
- `open` rows are PER BUY (FIFO lots), chronological by purchase
  date: `bought`/`held` show remaining shares of that buy, `cost` is
  the remaining cost basis of the HELD shares. `markKind: null` with
  `"unrealized": null` means NO usable close existed for that symbol:
  a dash, not a zero — and it withholds the whole currency total
  (whole-or-nothing, like `pnl/1`).
- `policy: "fifo-lots"` is ATTRIBUTION, not accounting — the ledger
  and `pnl/1` keep average cost. Per-event slices may differ between
  the two views; lifetime totals agree within regrouping dust.
- Summing `currencyTotals` per currency reconciles with a full-history
  `pnl/1` run over the same scope (within regrouping dust), EXCEPT
  when an unmeasurable quiet position exists: this view then refuses
  the total while `pnl/1` footnotes its omission. Stricter here,
  never looser.
- A missing portfolio emits the `"empty": true` envelope with the
  store path (same shape as the other schemas).

## Scripting notes

```bash
# one parse path; check .ok before .data
dit --json summary | jq -r '.data.holdings[] | [.symbol,.ccy,.pnl,.pnlPct] | @tsv'

# exit codes still work alongside the envelope
out=$(dit --json quote GHOST --as-of 2026-09-21); [ $? -eq 0 ] && jq . <<<"$out"
```

Two habits keep agent pipelines honest: treat any `null` as "no
information" (never coerce to 0), and treat non-null `via` as
"approximation — label it if you show it". Those two rules are the
reason the formats look the way they do.
