# `dit --json` contract

`--json` exists so programs and agents read `dit` without parsing tables.
Anything that would read `—` or "unknown" to a human is `null`; nothing is
ever invented to fill a field. Keys serialize alphabetically for byte-stable
output — parse by key, never by position.

## Envelope

```json
{"ok":true,"schema":"summary/1","data":{ … }}
{"ok":false,"kind":"runtime","error":"Cannot find portfolio at /path/to/store"}
{"ok":false,"kind":"usage","error":"--json is not supported for 'tx list' — …"}
```

Exactly one document on stdout, including on failure. Exit codes are
unchanged by `--json`: **0** ok, **1** runtime (`.kind":"runtime"`), **2**
usage (`.kind":"usage"`). Check the exit code *and* `.ok`.

## Supported commands

| Command | Schema |
|---|---|
| `dit [--offline] --json summary` | `summary/1` (with `--as-of D` adds `"asOf"`, `"mode":"as-of"`) |
| `dit --json summary --time-series [--daily]` | `networth/1` (`{"display":…,"series":[{date,total,cash,positions}]}`, values dashed→null where no historical FX) |
| `dit --json accounts` | `accounts/1` |
| `dit --json account show NAME [--history] [--as-of D]` | `account/1` (with `--as-of` adds `"asOf"`, `"mode":"as-of"`) |
| `dit --json income [--year\|--since\|--to] [--account A]` | `income/1` (`{"window",…, "income":[…], "totalsByCurrency":{…}}`) |
| `dit --json quote SYM… [--as-of D | --from D --to D]` | `quote/1` (`"mode":"live"|"store"|"series"`) |
| `dit --json quote CCY/CCY/CCY[/…]` | `quote/1` (`"mode":"matrix"`) |
| `dit --json pnl [window/filters]` | `pnl/1` |
| `dit --json market coverage [window/filters]` | `coverage/1` |

Not on `main`: `tx pnl` (`tx-pnl/1`) exists only on branch `feat/tx-pnl`.
The `main` binary rejects it with "unknown tx subcommand 'pnl'" — check
`dit help tx` before advising it. `tx import` has no `--json` (it is a write
command; use `--dry-run` to preview).

Everything else refuses with a usage error. `--json` takes no value
(`--json=1` is a usage error) and is position-independent.

## Value conventions

| Kind | Encoding | Example |
|---|---|---|
| Money | decimal **string**, 2 places | `"value": "100.00"` |
| Ratios (`pnlPct`, `dayPct`) | decimal string, 4 places, **fraction** | `"-0.0214"` = −2.14% |
| Shares | decimal string, up to 4 places | `"shares": "96.7"` (can be negative = short) |
| FX rates | decimal string, 6 places | `"1.418700"` |
| Day | `YYYY-MM-DD` (UTC) | `"date": "2026-09-28"` |
| Timestamp | ISO-8601 UTC seconds | `"asOf": "2026-09-29T16:43:56Z"` |
| Unknown / not applicable | `null` | `"dayChange": null` |

Cross-document rules:

1. Financial quantities are strings, never JSON numbers — parse with a decimal
   type; floats only for throwaway display.
2. `null` = no information, never 0. A real zero is `"0.00"`.
3. Currency is a field, never formatting. No grouping separators or symbols;
   every amount has an explicit or surrounding currency.
4. Provenance is data (`via`, `basis`, `source`). `via: null` = observed;
   non-null `via` names the model that produced the number — an approximation,
   label it or drop it.
5. Native amounts and their display-currency conversions are separate fields.
   Percentages are native-currency ratios and must not be FX-adjusted.

## `summary/1`

`data`: `accounts[]`, `holdings[]`, `totals`, `displayCurrency`,
`generatedAt`, `store`, `offline`, `degraded`, `untrackedShorts[]`, `warnings[]`.

Synthetic example (values are illustrative, not a real position):

```json
{"symbol":"FAST","ccy":"CAD","name":"Fast Demo Inc.","shares":"10",
 "avgCost":"8.00","value":"100.00","valueDisplay":"100.00",
 "pnl":"20.00","pnlDisplay":"20.00","pnlPct":"0.2500",
 "dayChange":"-2.00","dayChangeDisplay":"-2.00","dayPct":"-0.0196",
 "accounts":["Demo Broker"],
 "quote":{"asOf":"2026-09-29T16:43:56Z","price":"10.00","source":"yahoo",
          "previousClose":{"date":"2026-09-28","price":"10.20","via":null}}}
```

- `quote` present ⟺ priced from a market quote; absence = valued at cost
  (offline or unknown ticker). `previousClose` is always present inside it,
  `null` when no earlier close exists.
- `previousClose` is the baseline behind `dayChange`/`dayPct`: the last stored
  close strictly before the quote's own day, however old.
- `pnlPct`/`dayPct` are `null` when cost basis is ≤ 0 or shares ≤ 0.
- Top-level `totals` are display-currency sums converted at the total;
  `totals.byCurrency` holds exact native components — they will not add up by
  hand when currencies mix, by design.
- `accounts[].positions` = `total − cash − gic` when all three exist, else
  `null` on the combined fields.
- `untrackedShorts` entries are `{account, ccy, shares, symbol}`.
- `warnings` carry honest caveats (overdrafts etc.) — surface them.
- `offline: true` = no pricing happened; `degraded: true` = market store
  unreadable, day data unavailable. Neither is an error.

## `accounts/1`

`{"data":{"accounts":[{"name","id","currency","status","taxable","institution","number","opened"}]}}`

`status` is `"open"` or `"closed YYYY-MM-DD"`; `opened` appears only when
known. Empty portfolio yields `"accounts": []` — an honest "nothing recorded",
not an error. A missing store is a runtime error envelope instead.

## `account/1` — `account show NAME [--history]`

Offline by construction, and it reports **cost**, not market value.

```json
{"data":{"account":{"name","id","currency","status","taxable"},
  "balances":{"cashByCurrency":{"USD":"-487.32"},"gicByCurrency":{},
              "dividendsByCurrency":{"USD":"126.10"},
              "realizedPnlByCurrency":{"USD":"6629.06"},
              "unrealizedPnlByCurrency":{"USD":"180728.00"},
              "dayChangeByCurrency":{}},
  "history":[{"id":"893B51DC-…36 chars…","date","kind","detail","currency"}],
  "positions":[{"symbol","ccy","shares","avgCost","costBasis"}],
  "untrackedShorts":[]}}
```

- `history` appears only with `--history`. `kind` is a stable machine token
  (`deposit`, `stockPurchase`, `stockSale`, `dividend`, `gicPurchase`, …);
  `detail` is display text — show it, do not parse it.
- `id` is the full 36-char UUID (the table form truncates to 8).
- `positions[].costBasis` is what was paid, explicitly not a valuation.
- Negative `cashByCurrency` = recorded overdraft (real state, not an error).

## `quote/1`

Live mode: `{"mode":"live","quotes":[{"symbol","price","ccy","source","basis":"live","asOf"}]}`
— a symbol with no data returns `"basis":"none"`, `"price":null`, and the
document still exits 0 unless **every** symbol is missing (then runtime error).
`source` is `null` for misses; live FX pairs carry a 6-place rate string,
`ccy` = quote currency, price = quote per 1 base.

Store mode (`--as-of`): top-level `asOf` = the **requested** day, plus `store`;
each quote has `basis` (`observed` | `derived` | `none`), `date` = the day the
price was actually observed, `lagDays` = staleness (absent when `none`),
`via` (`null` or the recipe, e.g. `"derived via TSLA ÷ 16.2645"`). A close
found earlier than requested is reported with its real date, never silently
presented as the requested day.

Series mode (`--from`/`--to`): `{"mode":"series","count",from,to,store,quotes}` —
flat dated points, oldest first, bounds inclusive, `null` bound = open end.
`count` counts real points only; a symbol with no point appears once as
`"basis":"none"`, which is not counted.

Matrix mode (3+ currency chain): `{"mode":"matrix","query","currencies","pairCount","count",asOf,store,rates}` —
`rates` holds every directional pair (`n×(n−1)`, no diagonal) with
`base`/`quote`/`rate`/`basis`. `basis` vocabulary: `observed` → `reciprocal`
(exact inversion of an observed pair) → `derived` (`"via":"triangulated via USD"`,
a model number with no date) → `none` (`"rate": null`). Unknown codes in the
chain are usage errors; a chain with no known rate at all is a runtime error.

## `pnl/1`

```json
{"data":{
  "window":{"label","start","end","fromLedgerStart"},
  "scope":{"accounts","tickers","currencies","reportingCurrency","perAccount"},
  "positions":[{"symbol","kind","accounts","currency",
                "realized","positionChange","total","basis",
                "reported":{"realized","positionChange","total"}}],
  "currencyTotals":[{"currency","realized","positionChange","total","incompletePositions","reported"}],
  "combined":{"currency","value","at","rates"},
  "activityCount","notes"}}
```

- `positionChange`/`total` `null` = no usable price pair; `"0.00"` = measured
  zero. `total` is present only when **both** halves are known.
- `basis` `observed` | `derived` | `null` — never infer quality from the
  number alone, read this field.
- `currencyTotals` are native and exact: any incomplete position makes the
  total `null` and is counted in `incompletePositions` (it drops out).
- `reported` = the same figures converted at the dated FX actually used;
  `null` per part when honestly unconvertible. Native = ledger fact,
  `reported` = display arithmetic; read one, never mix.
- `combined` is `null` unless every currency converted honestly.
- `window.fromLedgerStart` is true for the default and `--to` forms.
- Empty result = `"positions":[], "currencyTotals":[]` with exit 0.
- `kind`: `"cash"` (no market instrument, e.g. GIC redemption) or `"position"`.
- With `--time-series`, `data.series` carries `{granularity, reconciles,
  collapsedEmpty, collapsedUnmeasurable, points[]}`. `reconciles: false` means
  a gap lives in the series — **do not sum the points into a total**.
  `collapsedEmpty` = measured zeros; `collapsedUnmeasurable` = data gaps.

## `coverage/1` — `market coverage`

Facts, no amounts.

```json
{"data":{"auditDate","complete","reporting","scope","seriesSlicing",
  "window":{"from","to"},
  "prices":[{"symbol","currency","accounts","points","staleDays","derived",
             "lastClose","status","longestGap":{"days","from","to"}}],
  "fx":[{"from","to","chain","usableNow","approx","lastClose","staleDays",
         "boundariesTotal","boundariesMissing"}],
  "notes":[]}}
```

- `prices` = one row per (held symbol, recorded currency) — a ticker held in
  USD and CAD needs two series. `status` is the first failing fact: `no-data`,
  `wrong-currency` (series can never be read for that position), `stale`
  (last close > 7 days early), `gaps` (holes ≥ 10 days), else `ok`. Shorter
  holes are weekend/holiday dust by design.
- `fx` = one row per foreign currency in scope. `chain` names how the rate
  would compose (`direct`, `inverted …`, `derived via USD …`, `"none"`);
  `usableNow: false` means the FX clock would answer nothing, so conversion
  dashes. `boundariesMissing/Total` counts the `--time-series` period ends
  whose converted column would dash.
- `complete` is the machine verdict; `--strict` only moves the exit code.

## `tx-pnl/1` — `tx pnl` (branch `feat/tx-pnl`, not `main`)

Per-transaction P&L, attributed with **FIFO lots** while the ledger's own
accounting is average cost — per-transaction slices may differ from `dit pnl`
windows, lifetime totals reconcile. Offline.

```json
{"data":{"asOf","policy":"fifo-lots","scope",
  "booked":[{"id","date","kind","symbol","account","currency","pnl","detail","incomplete"}],
  "open":[{"id","date","symbol","account","currency","bought","held","cost",
           "mark","markDay","markKind","unrealized"}],
  "currencyTotals":[{"currency","booked","open","total"}],
  "notes":["no usable daily history for: VRT.TO — …"]}}
```

`markKind` tells where a mark came from (`stored` vs live); a dashed
unrealized P&L in the text view is `null`/withheld here — totals covering it
are withheld too (`"total": null`), never partly summed.

## Scripting patterns

```bash
# one parse path, envelope checked
out=$(dit --json summary); rc=$?
if [ $rc -ne 0 ]; then echo "dit failed (rc=$rc): $(echo "$out" | jq -r '.error // "no envelope"')"; fi
echo "$out" | jq -r 'select(.ok) | .data.holdings[] | [.symbol,.ccy,.pnl,.pnlPct] | @tsv'

# optional: requires the separate dit-chart companion to be installed
# refusal is exit 1, not a silent empty file
dit --json | dit-chart --ascii > snapshot.txt
```

Two habits keep agent pipelines honest: treat `null` as "no information"
(never coerce to 0), and treat non-null `via`/`derived` as an approximation
that must be labelled if shown. The whole format exists to support exactly
those two rules.
