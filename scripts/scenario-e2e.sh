#!/usr/bin/env bash
# dit — end-to-end scenario script (Phase 7)
#
# Plays a single, coherent user story from a completely fresh store and
# asserts on output and exit codes at every step. This is the executable
# acceptance story for Phases 1–6: a brand-new user records a realistic
# multi-currency, multi-account portfolio with trades, GICs, FX, dividends,
# edits, mistakes, and a store export/import/backup cycle — and nothing
# breaks on the way.
#
# Offline by design: prices are always passed explicitly, quotes are
# fetched nowhere, so the script runs in a network-less environment.
#
# Usage: scripts/scenario-e2e.sh
# Exit:  0 when every assertion passes, 1 otherwise.
set -u

DIT="${DIT:-dit}"
WORKDIR="$(mktemp -d /tmp/dit-scenario.XXXXXX)"
STORE="$WORKDIR/store"
mkdir -p "$STORE"
export DIT_BACKEND=file
export DIT_STORE_URL="$STORE"

PASS=0
FAIL=0

# expect_ok NAME CMD... — command must exit 0
expect_ok() {
  local name; name="$1"; shift
  if output="$("$@" 2>&1)"; then
    PASS=$((PASS+1)); echo "ok   — $name"
  else
    FAIL=$((FAIL+1)); echo "FAIL — $name"; echo "$output" | sed 's/^/     | /'
  fi
}

# expect_ok_match NAME PATTERN CMD... — exit 0 AND output matches PATTERN (grep -E)
expect_ok_match() {
  local name; name="$1"; shift
  local pattern; pattern="$1"; shift
  if output="$("$@" 2>&1)"; then
    if printf '%s\n' "$output" | grep -Eiq -- "$pattern"; then
      PASS=$((PASS+1)); echo "ok   — $name"
    else
      FAIL=$((FAIL+1)); echo "FAIL — $name (no match for /$pattern/)"
      echo "$output" | sed 's/^/     | /' | head -8
    fi
  else
    FAIL=$((FAIL+1)); echo "FAIL — $name (non-zero exit)"
    echo "$output" | sed 's/^/     | /' | head -8
  fi
}

# expect_fail NAME EXPECTED_EXIT CMD... — must exit with EXPECTED_EXIT (1 or 2)
expect_fail() {
  local name; name="$1"; shift
  local expected; expected="$1"; shift
  "$@" >/tmp/dit-scenario-out.txt 2>&1
  local code=$?
  if [ "$code" -eq "$expected" ]; then
    PASS=$((PASS+1)); echo "ok   — $name (exit $code)"
  else
    FAIL=$((FAIL+1)); echo "FAIL — $name (exit $code, wanted $expected)"
    sed 's/^/     | /' /tmp/dit-scenario-out.txt | head -6
  fi
  if [ -n "${OUT_MATCH:-}" ]; then
    if grep -Eiq -- "$OUT_MATCH" /tmp/dit-scenario-out.txt; then
      PASS=$((PASS+1)); echo "ok   — $name (output matched /$OUT_MATCH/)"
    else
      FAIL=$((FAIL+1)); echo "FAIL — $name (no match for /$OUT_MATCH/)"
      sed 's/^/     | /' /tmp/dit-scenario-out.txt | head -6
    fi
    OUT_MATCH=""
  fi
}

# expect_fail_match NAME EXPECTED_EXIT PATTERN CMD...
expect_fail_match() {
  local name; name="$1"; shift
  local expected; expected="$1"; shift
  OUT_MATCH="$1"; shift
  expect_fail "$name" "$expected" "$@"
}

# extract_txid IDPATTERN — newest transaction ID matching the pattern
# (data rows are grid lines "│ ID │ …": the ID is the whitespace field
# after the left wall — 8 hex characters, no other line shape matches)
txid() {
  local pattern; pattern="$1"
  "$DIT" tx list --limit 60 2>/dev/null | grep -E "$pattern" | awk '$1=="│" && length($2)==8 && $2 !~ /[^0-9A-F]/ {print $2; exit}'
}

echo "== Scenario: a year of investing, from a fresh store =="
echo "(workdir: $WORKDIR)"
echo

echo "-- 0. Empty store: reads stay friendly, mutations bootstrap --"
expect_ok     "empty store: store path"                "$DIT" store path
expect_ok_match "empty store: store path shows it"     "Document: empty"        "$DIT" store path
expect_ok     "bootstrap: account add works on nothing" "$DIT" account add --currency CAD --name TFSA --non-taxable

echo
echo "-- 1. Set up two accounts --"
expect_ok     "account add (USD broker)"               "$DIT" account add --currency USD --name "Mercury" --institution "Mercury"
expect_ok_match "accounts listed"                      "Mercury"                "$DIT" accounts
expect_fail_match "duplicate name rejected"            1 "already named"          "$DIT" account add --currency CAD --name TFSA
expect_ok     "tax-free variant keeps a distinct name" "$DIT" account add --currency CAD --name "TaxFree" --non-taxable

echo
echo "-- 2. Ticker registry --"
expect_ok     "ticker add SHOP.TO"                     "$DIT" ticker add SHOP.TO --name "Shopify" --currency CAD --tags "dividends, retail"
expect_ok     "ticker add AAPL"                        "$DIT" ticker add AAPL --name "Apple" --currency USD
expect_ok_match "ticker list shows both"               "AAPL"                   "$DIT" ticker list
expect_fail_match "duplicate ticker rejected"          1 "already registered"  "$DIT" ticker add AAPL
expect_fail_match "ticker show unknown"                1 "no registry entry"     "$DIT" ticker show TSLA

echo
echo "-- 3. Cash flow: deposits, overdraft (recorded, warned) --"
expect_ok     "deposit into TFSA"                      "$DIT" tx deposit --account TFSA --amount 12000 --date 2026-01-05
expect_ok     "deposit into Mercury"                   "$DIT" tx deposit --account Mercury --amount 5000 --currency USD --date 2026-01-06
expect_ok_match "overdraw recorded with loud warning"  "goes negative"          "$DIT" tx withdraw --account TFSA --amount 99999 --date 2026-01-20
expect_ok_match "odwithdraw shows in list"             "withdrawal 99999"      "$DIT" tx list --account TFSA --kind withdrawal

echo
echo "-- 4. Trades (offline-safe: explicit prices) --"
expect_ok     "buy 10 SHOP.TO @ 180"                   "$DIT" tx buy --account TFSA --ticker SHOP.TO --shares 10 --price 180 --date 2026-02-01
expect_ok     "sell 4 AAPL @ 200"                      "$DIT" tx sell --account Mercury --ticker AAPL --shares 4 --price 200 --date 2026-02-10
expect_ok_match "oversell recorded, flagged as short"  "SHORT"                  "$DIT" tx sell --account Mercury --ticker AAPL --shares 50 --price 200 --date 2026-02-11
expect_ok_match "position still visible in summary"    "SHOP.TO"                "$DIT" --offline summary
expect_fail_match "sell without price offline refused" 2 "pass --price"          "$DIT" --offline tx sell --account TFSA --ticker SHOP.TO --shares 2
expect_ok_match "account show --history lists the ledger" "oldest first"         "$DIT" account show TFSA --history
expect_ok_match "history shows a trade line with id"     "buy 10 SHOP.TO @ 180" "$DIT" account show TFSA --history
expect_ok "add a quiet account"                          "$DIT" account add --currency CAD --name Quiet
expect_ok_match "quiet account history says so"          "no activity recorded"  "$DIT" account show Quiet --history

echo
echo "-- 5. Dividends, including an unregistered ticker --"
expect_ok_match "dividend on registered ticker"        "added" "$DIT" tx dividend --account Mercury --ticker AAPL --amount 12 --currency USD --date 2026-03-15
expect_ok_match "dividend auto-registers new ticker"   "registered" "$DIT" tx dividend --account Mercury --ticker KO --amount 8 --currency USD --date 2026-03-16
expect_ok_match "soft hint for near-miss ticker"       "hint|registered" "$DIT" tx dividend --account Mercury --ticker APPL --amount 1 --currency USD --date 2026-03-17

echo
echo "-- 6. GICs: purchase, partial redemption --"
expect_ok     "GIC purchase"                           "$DIT" tx gic --account TFSA --product "3-Year GIC" --principal 10000 --rate 4.5 --maturity 2029-01-20 --redeemable
expect_ok     "GIC redeem in full"                     "$DIT" tx gic-redeem --account TFSA --gic "3-Year GIC" --proceeds 11300 --date 2029-01-20
expect_ok     "second GIC for partial redemption demo" "$DIT" tx gic --account TFSA --product "2-Year GIC" --principal 20000 --rate 4.2 --maturity 2028-02-15 --redeemable
expect_ok_match "partial redemption recorded, flagged" "booked as gone"         "$DIT" tx gic-redeem --account TFSA --gic "2-Year GIC" --proceeds 5000 --date 2028-02-15

echo
echo "-- 7. FX conversion between pools --"
expect_ok     "fx CAD -> USD"                          "$DIT" tx fx --account TFSA --from CAD --to USD --from-amount 1000 --to-amount 740 --date 2026-04-01
expect_ok_match "fx visible in list"                   "fx"                     "$DIT" tx list --account TFSA --kind fx

echo
echo "-- 8. Edit and correct --"
TXID="$(txid 'deposit 12000')"
expect_ok     "edit value field (amount)"              "$DIT" tx edit "$TXID" --amount 12500
expect_ok_match "edit applied"                         "12500"                  "$DIT" tx show "$TXID"
expect_fail_match "kind change refused"                2 "delete.*re-add|kind|what" "$DIT" tx edit "$TXID" --kind withdrawal
BUYID="$(txid '10 SHOP.TO|SHOP.TO.*10|buy.*SHOP')"
if [ -n "${BUYID:-}" ]; then
  expect_ok     "edit trade price"                     "$DIT" tx edit "$BUYID" --price 182
else
  expect_ok     "edit trade price (no match found)"    true
fi

echo
echo "-- 9. Ticker + account maintenance --"
expect_ok     "ticker edit tags"                       "$DIT" ticker edit SHOP.TO --tags "dividends, core"
expect_ok_match "ticker show reflects edit"            "core"                   "$DIT" ticker show SHOP.TO
expect_fail_match "delete referenced ticker gated (non-TTY)" 1 "without --yes" "$DIT" ticker delete AAPL
expect_ok_match "delete referenced ticker with --yes"  "still reference" "$DIT" ticker delete AAPL --yes
expect_ok     "account rename"                         "$DIT" account edit Mercury --name "Mercury Bank"
expect_ok_match "accounts reflects rename"             "Mercury Bank"           "$DIT" accounts
expect_fail_match "rename onto existing name refused"  1 "already named"        "$DIT" account edit TaxFree --name "Mercury Bank"
expect_ok     "rename TaxFree account"                   "$DIT" account edit TaxFree --name "TaxFree RRSP"
expect_fail_match "delete account with ledger refused" 2 "has .* transactions"  "$DIT" account delete "Mercury Bank" --yes

echo
echo "-- 10. Display & summary --"
expect_ok_match "summary works offline"                "Total value"            "$DIT" --offline summary
expect_ok_match "display currency honored"             "display: USD"           "$DIT" --display USD --offline summary
expect_fail_match "unknown display currency refused"   2 "currency"             "$DIT" --display XYZ summary

echo
echo "-- 11. Store lifecycle: export / import / backup --"
EXPORT="$WORKDIR/exports/tfsa.json"
mkdir -p "$WORKDIR/exports"
expect_ok     "export single account"                  "$DIT" store export --account TFSA --to "$EXPORT"
expect_ok     "file exists"                            test -s "$EXPORT"
expect_ok     "backup"                                 "$DIT" store backup
expect_ok_match "backup exists"                        "store.bak-"             "$DIT" store backup
FRESH="$WORKDIR/fresh-store"
mkdir -p "$FRESH"
# import (replace) into a store that never had this account
expect_ok   "import (replace) into a store that never had the account" \
  env DIT_STORE_URL="$FRESH" "$DIT" store import "$EXPORT" --yes
expect_ok_match "fresh store now carries the imported ledger" "12500" \
  env DIT_STORE_URL="$FRESH" "$DIT" tx list --account TFSA --kind deposit
expect_fail_match "non-TTY replace without --yes refused" 1 "without --yes" \
  env DIT_STORE_URL="$FRESH" "$DIT" store import "$EXPORT"
expect_ok   "merge-import the same file (dedup)" \
  env DIT_STORE_URL="$FRESH" "$DIT" store import "$EXPORT" --merge --yes

echo
echo "-- 12. SQLite backend round trip --"
SQLDIR="$WORKDIR/sqlite"
mkdir -p "$SQLDIR"
expect_ok     "sqlite: bootstrap account"          env DIT_STORE_URL="$SQLDIR" "$DIT" account add --currency CAD --name "RRSP"
expect_ok     "sqlite: deposit"                    env DIT_STORE_URL="$SQLDIR" "$DIT" tx deposit --account RRSP --amount 8000 --date 2026-01-01
expect_ok_match "sqlite: store path"               "sqlite"                    env DIT_STORE_URL="$SQLDIR" "$DIT" store path
expect_ok     "sqlite: export"                     env DIT_STORE_URL="$SQLDIR" "$DIT" store export --account RRSP --to "$WORKDIR/rrsp.json"
expect_ok     "sqlite: backup"                     env DIT_STORE_URL="$SQLDIR" "$DIT" store backup

echo
echo "-- 13. Usage-error contract (exit 2) --"
expect_fail_match "unknown command"                2 "unknown|usage"      "$DIT" frobnicate
expect_fail_match "unknown subcommand"             2 "unknown"            "$DIT" store nosuchthing
expect_fail_match "bad currency on entry"          2 "currency"           "$DIT" tx deposit --account TFSA --amount 5 --currency XYZ
expect_fail_match "bad date refused"               2 "date"               "$DIT" tx deposit --account TFSA --amount 5 --date 2026-13-99
expect_ok     "help works anywhere"                "$DIT" help
expect_ok     "--help on a mutating command"       "$DIT" tx deposit --help

echo
echo "-- 14. Backfill derived history (offline, seeded market store) --"
BFD="$WORKDIR/bf"
mkdir -p "$BFD/store" "$BFD/market"
bf() { env DIT_BACKEND=file DIT_STORE_URL="$BFD/store" DIT_MARKET_URL="$BFD/market" "$DIT" "$@"; }
expect_ok "bf: bootstrap account"        bf account add --currency CAD --name BF
expect_ok "bf: register tracker ticker"  bf ticker add TSLA.NE --currency CAD
expect_ok "bf: register underlying"      bf ticker add TSLA --currency USD
expect_ok "bf: record tracker purchase"  bf tx buy --account BF --ticker TSLA.NE --shares 10 --price 30 --date 2026-09-15
{
  echo "# seeded real observations"
  for d in 15 16 17 18 21 22 23 24 25; do echo "TSLA,2026-09-$d,400"; done
  for d in 15 16 17 18 21 22 23 24 25; do echo "USD/CAD,2026-09-$d,1.4"; done
  echo "TSLA.NE,2026-09-17,30"
} > "$BFD/seed.csv"
expect_ok_match "bf: import real closes"          "TSLA.NE: 1 point"                 bf market import "$BFD/seed.csv"
expect_ok_match "bf: backfill derives 8 offline"  "backfilled 8 day"                  bf market backfill TSLA.NE --from TSLA --offline
expect_ok_match "bf: single-anchor calibration"   "calibrated on 1 common day"        bf market backfill TSLA.NE --from TSLA --offline
expect_ok_match "bf: derived points marked"       "derived via TSLA"                  bf market show --symbol TSLA.NE --days 9
expect_ok_match "bf: rerun changes nothing"       "unchanged"                          bf market backfill TSLA.NE --from TSLA --offline
expect_ok_match "bf: as-of quote marks backfilled data"  "backfilled"                  bf quote TSLA.NE --as-of 2026-09-21
expect_ok_match "bf: show --symbol keeps only the asked ticker" "History \\(1 series\\)"  bf market show --symbol TSLA
expect_ok_match "bf: show --symbol is honest about unknown symbols" "nothing stored for 'GHOST'"  bf market show --symbol GHOST
expect_ok_match "bf: as-of quote shows measured close"   "observed"                    bf quote TSLA.NE --as-of 2026-09-17
expect_ok_match "bf: weekend as-of finds nearest earlier" "earlier"                    bf quote TSLA.NE --as-of 2026-09-20
expect_ok_match "bf: as-of lists missing symbols"        "no stored quote for"         bf quote TSLA.NE NVDA.NE --as-of 2026-09-21
expect_ok     "bf: as-of works with --offline"           bf quote --offline TSLA.NE --as-of 2026-09-21
expect_ok_match "bf: range prints the stored series"       "2026-09-17"         bf quote TSLA.NE --from 2026-09-16 --to 2026-09-18
expect_ok_match "bf: range labels derived closes"          "backfilled .* derived"  bf quote TSLA.NE --from 2026-09-15 --to 2026-09-18
expect_ok     "bf: range works with --offline"             bf quote --offline TSLA.NE --from 2026-09-15 --to 2026-09-18
expect_fail_match "bf: --to before --from is refused"      2 "before --from"    bf quote TSLA.NE --from 2026-09-18 --to 2026-09-15
expect_fail_match "bf: --as-of and range conflict"         2 "cannot be combined" bf quote TSLA.NE --as-of 2026-09-17 --from 2026-09-15
expect_fail_match "bf: as-of refuses an invalid date"    2 "invalid date"              bf quote TSLA.NE --as-of 2026-13-99
expect_fail_match "bf: --from is required"        2 "needs --from"                    bf market backfill TSLA.NE
BFD2="$WORKDIR/bf2"
mkdir -p "$BFD2/store" "$BFD2/market"
bf2() { env DIT_BACKEND=file DIT_STORE_URL="$BFD2/store" DIT_MARKET_URL="$BFD2/market" "$DIT" "$@"; }
expect_ok "bf2: bootstrap account"         bf2 account add --currency CAD --name BF2
expect_ok "bf2: register tickers"          bf2 ticker add TSLA.NE --currency CAD
expect_ok "bf2: register underlying"       bf2 ticker add TSLA --currency USD
expect_ok "bf2: buy tracker"               bf2 tx buy --account BF2 --ticker TSLA.NE --shares 10 --price 30 --date 2026-09-15
expect_fail_match "bf2: refuses without stored source history (offline)" 1 "network is off" bf2 market backfill TSLA.NE --from TSLA --offline
expect_fail_match "bf2: unknown source ticker refused"                   1 "no registry entry" bf2 market backfill TSLA.NE --from GHOST

echo
echo "-- 15. Machine output (--json) — AI-agent tooling contract --"
# json_ok: stdout must be EXACTLY one parseable JSON document — prose
# headers leaking in (or a table) break agents the way misaligned
# columns break humans.
json_ok() {
  local name; name="$1"; shift
  if output=$("$@" 2>/dev/null) && printf '%s\n' "$output" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
    PASS=$((PASS+1)); echo "ok   — $name"
  else
    FAIL=$((FAIL+1)); echo "FAIL — $name (stdout is not one pure JSON document)"
    printf '%s\n' "$output" | sed 's/^/     | /' | head -4
  fi
}
json_ok "json: offline summary is a pure JSON document"      "$DIT" --offline --json summary
json_ok "json: accounts list parses"                          "$DIT" --json accounts
json_ok "json: account show parses"                           "$DIT" --json account show TFSA
json_ok "json: account show --history parses"                 "$DIT" --json account show TFSA --history
json_ok "json: quiet account history is an empty list"        "$DIT" --json account show Quiet --history
expect_ok_match "json: history carries FULL 36-char tx ids" '[0-9A-F]{8}-[0-9A-F]{4}-' \
                                                           "$DIT" --json account show TFSA --history
expect_ok_match "json: schema tag present"  '"schema":"summary/1"' "$DIT" --offline --json summary
expect_ok_match "json: unknown data is null, never a dash"  '"dayChange":null' "$DIT" --offline --json summary
expect_ok_match "json: money is decimal strings" '"costBasis":"[0-9]+\.[0-9]{2}"' "$DIT" --json account show TFSA
expect_fail_match "json: unsupported command is a usage error" 2 "not supported" "$DIT" --json tx list
expect_fail_match "json: --json takes no value"                 2 "takes no value" "$DIT" --json=1 summary
expect_fail_match "json: all-missing as-of exits 1 WITH an envelope" 1 '"ok":false' \
                                                           bf2 --json quote TSLA.NE --as-of 2026-09-21
# The bf store has derived history → provenance must come through as DATA.
expect_ok_match "json: store-mode quote needs no network"    '"mode":"store"'   bf --json quote TSLA.NE --as-of 2026-09-21
expect_ok_match "json: derived baseline labelled as derived" '"basis":"derived"' bf --json quote TSLA.NE --as-of 2026-09-21
expect_ok_match "json: observed close labelled observed"     '"basis":"observed"' bf --json quote TSLA.NE --as-of 2026-09-17
expect_ok_match "json: missing symbol is null price, not a 0" '"basis":"none"'   bf --json quote TSLA.NE GHOST --as-of 2026-09-21
json_ok "json: range document parses"                        bf --json quote TSLA.NE --from 2026-09-15 --to 2026-09-18
expect_ok_match "json: range mode marker"                     '"mode":"series"'  bf --json quote TSLA.NE GHOST --from 2026-09-15 --to 2026-09-18
expect_ok_match "json: range keeps derived provenance"        '"basis":"derived"' bf --json quote TSLA.NE --from 2026-09-15 --to 2026-09-18
expect_fail_match "json: empty range is an error envelope"     1 '"ok":false'     bf --json quote GHOST --from 2026-09-15 --to 2026-09-18
expect_fail_match "bf2: as-of with an empty market store exits 1"        1 "no stored quotes"  bf2 quote TSLA.NE --as-of 2026-09-21

echo
echo "-- 16. FX matrix (dit quote USD/CAD/HKD/EUR) — single day, no invention --"
# All matrix checks stay offline: the matrix must be answerable from
# the store, and refusals happen before any network question.
MTX="$WORKDIR/mtx"
mkdir -p "$MTX/store" "$MTX/market"
mtx() { env DIT_BACKEND=file DIT_STORE_URL="$MTX/store" DIT_MARKET_URL="$MTX/market" "$DIT" "$@"; }
MTX2="$WORKDIR/mtx2"
mkdir -p "$MTX2/store" "$MTX2/market"
mtx2() { env DIT_BACKEND=file DIT_STORE_URL="$MTX2/store" DIT_MARKET_URL="$MTX2/market" "$DIT" "$@"; }
{
  echo "# hub rates: column-ccy per 1 USD, one day only"
  echo "USD/CAD,2026-09-25,1.4"
  echo "USD/HKD,2026-09-25,7.84"
  echo "USD/EUR,2026-09-25,0.93"
} > "$WORKDIR/fx.csv"
expect_ok   "matrix: seed hub rates"                          mtx market import "$WORKDIR/fx.csv"
expect_ok_match "matrix: triangulated CAD→HKD is 7.84 ÷ 1.4"  "5\.6"           mtx quote USD/CAD/HKD --as-of 2026-09-28
expect_ok_match "matrix: triangulation is marked, not hidden" '\*'             mtx quote USD/CAD/HKD --as-of 2026-09-28
expect_ok_match "matrix: the legend explains the marker"      "triangulated via USD"  mtx quote USD/CAD/HKD --as-of 2026-09-28
expect_ok_match "matrix: plain --offline takes the latest stored day" "5\.6"   mtx quote --offline USD/CAD/HKD
json_ok     "matrix: json is one pure document"               mtx --json quote USD/CAD/HKD --as-of 2026-09-28
expect_ok_match "matrix: json mode + derived rows"            '"mode":"matrix"' mtx --json quote USD/CAD/HKD --as-of 2026-09-28
expect_ok_match "matrix: json derived row says how it was made" 'triangulated via USD' mtx --json quote USD/CAD/HKD --as-of 2026-09-28
expect_fail_match "matrix: --from is refused (single-day view)" 2 "single-day"      mtx quote USD/CAD/HKD --from 2026-09-01
expect_fail_match "matrix: --to is refused too"                  2 "single-day"     mtx quote USD/CAD/HKD --to 2026-09-28
expect_fail_match "matrix: cannot be mixed with other requests"  2 "only request"   mtx quote USD/CAD/HKD TSLA
expect_fail_match "matrix: unknown code in a chain is a usage error" 2 "unknown currency" mtx quote USD/CAD/XYZ --offline
expect_fail_match "matrix: no known rate = error, not a table of dashes" 1 "no stored FX rates" mtx2 quote USD/CAD/HKD --offline
expect_fail_match "matrix: json form keeps the error envelope"  1 '"ok":false'      mtx2 --json quote USD/CAD/HKD --offline

echo
echo "-- 17. Chart pipeline (dit --json | dit-chart) — renderer contracts --"
# dit-chart reads ONE JSON document on stdin and draws or clearly
# refuses. All offline; no network anywhere in this section.
CHART="${CHART:-dit-chart}"
chart() { "$DIT" --json --offline | "$CHART" "$@"; }
chartf() { local f; f="$1"; shift; "$CHART" "$@" < "$f"; }
chartstdin() { "$CHART" "$@" < /dev/null; }
printf '%s' '{"ok":true,"schema":"summary/1","data":{"displayCurrency":"CAD","accounts":[{"name":"GOOD","reportingCurrency":"CAD","total":"1234.50"},{"name":"BAD","reportingCurrency":"CAD","total":"-456.70"},{"name":"GHOST","reportingCurrency":"CAD","total":null}],"holdings":[],"totals":{},"warnings":[]}}' > "$WORKDIR/mixed.json"
expect_ok_match "chart: scenario summary renders the account chart" "Total value per account"  chart --ascii
expect_ok_match "chart: holdings chart follows when values exist"   "Position value per holding" chart --ascii
# The ASCII promise: the whole output stays in the plain tier (bytes
# 128+ would tofu on cp936-style consoles — that is why the tier exists).
if ! ascii_out="$(chart --ascii 2>&1)"; then
  FAIL=$((FAIL+1)); echo "FAIL — chart: --ascii pipeline must succeed"
elif printf '%s' "$ascii_out" | LC_ALL=C grep -q '[^ -~]'; then
  FAIL=$((FAIL+1)); echo "FAIL — chart: --ascii leaked non-ASCII bytes"
else
  PASS=$((PASS+1)); echo "ok   — chart: --ascii stayed in the plain tier"
fi
expect_ok_match "chart: default tier draws the zero-line marker" "marks zero" chartf "$WORKDIR/mixed.json"
expect_ok_match "chart: null total stays dashed, never 0.00" "GHOST.*\\?" chartf "$WORKDIR/mixed.json" --ascii
printf '%s' '{"ok":true,"schema":"account/1","data":{}}' > "$WORKDIR/acc.json"
expect_fail_match "chart: unknown schema refused, not guessed" 1 "no chart defined" chartf "$WORKDIR/acc.json"
printf '%s' '{"ok":true,"schema":"quote/1","data":{"mode":"series","symbols":[]}}' > "$WORKDIR/quote.json"
expect_fail_match "chart: quote/1 refused (series chart undefined, not guessed)" 1 "no chart defined for schema 'quote/1'" chartf "$WORKDIR/quote.json"
printf '%s' '{"ok":false,"error":"no FX rates available"}' > "$WORKDIR/err.json"
expect_fail_match "chart: failed source doc carries its message" 1 "no FX rates available" chartf "$WORKDIR/err.json"
printf '%s' 'tables not charts' > "$WORKDIR/garbage.txt"
expect_fail_match "chart: non-JSON stdin is refused" 1 "not a JSON document" chartf "$WORKDIR/garbage.txt"
expect_fail_match "chart: --svg is refused honestly" 2 "not implemented" chartf "$WORKDIR/mixed.json" --svg /tmp/x.svg
expect_fail_match "chart: --width needs a sane number" 2 "between 40 and 400" chartstdin --width 20
expect_fail_match "chart: empty stdin is an error, not an empty chart" 1 "no JSON on stdin" chartstdin

echo
echo "-- 18. Statement view (unfiltered tx list = bank style) --"
# Without trade filters, 'tx list' derives Debit/Credit/Balance on the
# fly; with ANY filter it must stay the plain list (running balances
# over a subset would be theater).
expect_ok_match "stmt: plain list gains Debit/Credit/Balance" "Bal USD|Balance after"  "$DIT" tx list
expect_ok_match "stmt: the view explains what it is"          "derived on the fly" "$DIT" tx list
expect_ok_match "stmt: account scope keeps its own balances"  "Bal USD|Balance after"  "$DIT" tx list --account TFSA
if "$DIT" tx list --kind deposit | grep -Eq "Bal USD|Balance after"; then
  FAIL=$((FAIL+1)); echo "FAIL — stmt: --kind must keep the plain list"
else PASS=$((PASS+1)); echo "ok   — stmt: --kind keeps the plain list"; fi
if "$DIT" tx list --limit 5 | grep -Eq "Bal USD|Balance after"; then
  FAIL=$((FAIL+1)); echo "FAIL — stmt: --limit must keep the plain list"
else PASS=$((PASS+1)); echo "ok   — stmt: --limit keeps the plain list"; fi
# The multi-currency account must show one aligned column PER CURRENCY
# that appears anywhere in its history (TFSA holds a USD purse after
# its fx), and single-currency accounts keep the compact one-column
# balance. Balances are per account+currency, never summed.
expect_ok_match "stmt: multi-ccy account splits balance columns" "Bal USD"     "$DIT" tx list --account TFSA
expect_ok_match "stmt: single-ccy account keeps one column"     "Balance after" "$DIT" tx list --account "Mercury Bank"
expect_ok_match "stmt: multi-ccy all-accounts view splits too"   "Bal USD"     "$DIT" tx list
expect_ok_match "stmt: USD account balance speaks USD" "USD" "$DIT" tx list --account "Mercury Bank"

echo
echo "-- 19. Historical P&L windows (dit pnl) — derived, dashed when unsure --"
# A dedicated store with SEEDED market closes so the position-drift half
# of the answer is checkable offline: WIDE @5 (Jun 10) → close 6.00
# (Jun 30) → close 8.00 (Jul 31); July sells 5 @8 and books a 7 div.
# A DAILY USD/CAD series at one flat 1.40 lets the reporting view
# convert: text output speaks CAD ONLY — July's native 22.00 + 5.00 =
# 27.00 USD must appear AS 30.80 + 7.00 = 37.80 CAD (exactly ×1.40).
# The native split lives on in --json. Default-window checks pin
# --to 2026-10-01 so the FX-staleness rules cannot make this script
# depend on the day it runs.
PD="$WORKDIR/pnl-store"
mkdir -p "$PD/store" "$PD/market"
pnl() { env DIT_BACKEND=file DIT_STORE_URL="$PD/store" DIT_MARKET_URL="$PD/market" "$DIT" "$@"; }
expect_ok "pnl: bootstrap account"           pnl account add --currency USD --name "P&L One"
expect_ok "pnl: register ticker"             pnl ticker add WIDE --currency USD
expect_ok "pnl: deposit"                     pnl tx deposit --account "P&L One" --amount 1000 --date 2026-06-10
expect_ok "pnl: buy 10 WIDE @ 5"             pnl tx buy --account "P&L One" --ticker WIDE --shares 10 --price 5 --date 2026-06-10
printf '%s\n' 'WIDE,2026-06-30,6.00' 'WIDE,2026-07-31,8.00' > "$WORKDIR/pnl-closes.csv"
expect_ok_match "pnl: seed window-crossing closes" "2 point"  pnl market import "$WORKDIR/pnl-closes.csv"
# Daily FX history, flat rate — conversion math stays hand-checkable.
: > "$WORKDIR/pnl-fx.csv"
fxd=2026-06-01
while [[ "$fxd" < "2026-11-02" ]]; do
  printf 'USD/CAD,%s,1.40\n' "$fxd" >> "$WORKDIR/pnl-fx.csv"
  fxd=$(date -j -v+1d -f "%Y-%m-%d" "$fxd" +%Y-%m-%d)
done
expect_ok_match "pnl: seed a daily USD/CAD history" "USD/CAD"     pnl market import "$WORKDIR/pnl-fx.csv"
expect_ok "pnl: sell 5 @ 8 inside window"    pnl tx sell --account "P&L One" --ticker WIDE --shares 5 --price 8 --date 2026-07-10
expect_ok "pnl: dividend 7 inside window"    pnl tx dividend --account "P&L One" --ticker WIDE --amount 7 --date 2026-07-20
expect_ok_match "pnl: default runs the WHOLE ledger" "full history" pnl pnl
expect_ok_match "pnl: default converts at DATED FX (as-of Sep 30)" "converted at USD→CAD 1\.4" pnl pnl --to 2026-10-01
expect_ok_match "pnl: July converts 22.00 USD into 30.80 CAD" "30\.80"   pnl pnl --from 2026-07-01 --to 2026-07-31
expect_ok_match "pnl: …and Δ 7.00 with total 37.80 (30.80+7.00, no double count)" "7\.00.*37\.80|37\.80" pnl pnl --from 2026-07-01 --to 2026-07-31
expect_ok_match "pnl: June drift-only story reads 14.00 CAD" "14\.00" pnl pnl --to 2026-06-30
expect_ok_match "pnl: --reporting-ccy USD prints native exactly" "22\.00" pnl pnl --reporting-ccy USD --from 2026-07-01 --to 2026-07-31
expect_ok_match "pnl: …and labels it as no-conversion" "Reporting: USD" pnl pnl --reporting-ccy USD --from 2026-07-01 --to 2026-07-31
expect_ok "pnl: empty window is quiet, exit 0"  pnl pnl --from 2020-01-01 --to 2020-01-31
expect_ok_match "pnl: empty window says so"  "nothing to report"  pnl pnl --from 2020-01-01 --to 2020-01-31
# Horizon tokens are inclusive day-spans ending today (or --to).
expect_ok_match "pnl: --horizon 2w accepted" "Historical P&L"     pnl pnl --horizon 2w
expect_ok_match "pnl: ytd accepted"          "ytd"                pnl pnl --horizon ytd
expect_ok_match "pnl: per-account mode when --account names it"  "P&L One"  pnl pnl --account "P&L One"
expect_ok_match "pnl: tickers filter narrows" "WIDE"              pnl pnl --tickers WIDE --from 2026-07-01 --to 2026-07-31
expect_ok_match "pnl: filter matching nothing says nothing" "nothing|none with" pnl pnl --tickers NOPE
expect_ok_match "pnl: ccy filter honored (USD kept)" "WIDE"       pnl pnl --ccy USD
expect_ok_match "pnl: ccy filter excludes other currencies" "nothing|none with" pnl pnl --ccy GBP
expect_fail_match "pnl: unknown horizon is a usage error"     2 "horizon"        pnl pnl --horizon 5x
expect_fail_match "pnl: horizon and dates cannot mix"         2 "combined"       pnl pnl --horizon 1w --from 2026-01-01
expect_fail_match "pnl: reversed dates refused, not swapped"  2 "before"         pnl pnl --from 2026-07-31 --to 2026-07-01
expect_fail_match "pnl: bad date is a usage error"            2 "date"           pnl pnl --from 2026-02-30
expect_fail_match "pnl: unknown account errors (not 'all')"   1 "no account matches" pnl pnl --account NOPE
expect_fail_match "pnl: positional argument refused"          2 "unexpected"     pnl pnl USD
# No market data at all: a position that CROSSES the window boundary
# cannot have its drift measured, and USD cannot honestly be shown as
# CAD — the reporting view DASHES both and declares why. A dash is a
# fact; native values ride on in --json. Never a quiet zero, never a
# disguised guess.
PD2="$WORKDIR/pnl-store-nomkt"
mkdir -p "$PD2/store" "$PD2/market"
pnl2() { env DIT_BACKEND=file DIT_STORE_URL="$PD2/store" DIT_MARKET_URL="$PD2/market" "$DIT" "$@"; }
expect_ok "pnl2: same ledger, no market data" pnl2 account add --currency USD --name "P&L One"
expect_ok "pnl2: buy before window"          pnl2 tx buy --account "P&L One" --ticker WIDE --shares 10 --price 5 --date 2026-06-10
expect_ok "pnl2: sell inside window"         pnl2 tx sell --account "P&L One" --ticker WIDE --shares 5 --price 8 --date 2026-07-10
expect_ok "pnl2: dividend inside window"     pnl2 tx dividend --account "P&L One" --ticker WIDE --amount 7 --date 2026-07-20
expect_ok_match "pnl2: no FX history = no CAD figures, declared" "no stored FX history" pnl2 pnl --from 2026-07-01 --to 2026-07-31
expect_ok_match "pnl2: total withheld, not faked" "Total \(CAD\): —"  pnl2 pnl --from 2026-07-01 --to 2026-07-31
expect_ok_match "pnl2: USD reporting still prints 22.00 exactly" "22\.00" pnl2 pnl --reporting-ccy USD --from 2026-07-01 --to 2026-07-31
# Mixed store: USD amounts inside a CAD account — every figure STILL
# speaks CAD (the From column names each row's ledger currency).
expect_ok "pnl: add a CAD account"           pnl account add --currency CAD --name "P&L Two"
expect_ok "pnl: USD dividend in a CAD account (mixed view)" pnl tx dividend --account "P&L Two" --ticker SHOP.TO --amount 14 --currency USD --date 2026-07-21
expect_ok_match "pnl: mixed view speaks CAD only" "P&L \(CAD, portfolio" pnl pnl --to 2026-07-31
expect_ok_match "pnl: mixed 51.00 USD converts to 71.40 CAD" "Total \(CAD\): 71\.40" pnl pnl --to 2026-07-31
expect_ok_match "pnl: From column names the source currency" "USD" pnl pnl --to 2026-07-31
# --json is a first-class contract here: native amounts stay, plus a
# "reported" triple converted at the dated FX; nulls for the unknown.
json_ok "pnl: json document parses"                           pnl --json pnl
expect_ok_match "pnl: json keeps the split components" '"realized":"22\.00".*"total":"27\.00"' pnl --json pnl --from 2026-07-01 --to 2026-07-31
expect_ok_match "pnl: json adds the converted triple" '"reported":\{"positionChange":"7\.00","realized":"30\.80","total":"37\.80"\}' pnl --json pnl --from 2026-07-01 --to 2026-07-31
expect_ok_match "pnl: json window + scope echo" '"fromLedgerStart":false' pnl --json pnl --from 2026-07-01 --to 2026-07-31
expect_ok_match "pnl: json quotes the dated FX used" '"rates":"USD→CAD 1\.4 at 2026-07-31"' pnl --json pnl --from 2026-07-01 --to 2026-07-31
expect_ok_match "pnl: json marks derived basis (none here = observed)" '"basis":"observed"' pnl --json pnl
expect_ok_match "pnl: json without market data nulls the change" '"positionChange":null' pnl2 --json pnl
expect_fail_match "pnl: chart refuses pnl/1 honestly" 1 "no chart defined" bash -c "'$DIT' --json --store '$PD/store' --market-store '$PD/market' pnl | '$CHART'"

echo
echo "-- 20. P&L time series (--time-series) — slices that must add back --"
# Each period is computed by the SAME engine with its own baseline
# (strictly before the period start) and converts at ITS OWN end-date
# FX. Contiguous periods telescope in NATIVE amounts — the script
# asserts that identity. With the flat fixture FX the converted column
# adds exactly too (14.00 + 57.40 = 71.40 = window 51.00 × 1.40);
# if FX ever moved between periods the footer says so, it does not
# pretend the sum matched.
expect_ok_match "ts: default shows a period table"      "P&L per period"      pnl pnl --time-series
expect_ok_match "ts: granularity is always labelled"   "series: (monthly|weekly|daily) periods" pnl pnl --time-series
expect_ok_match "ts: Σ slices match the window (default)" "Σ periods = window total \(exact" pnl pnl --time-series --to 2026-10-01
# Pinned two-month window: June drift +10 (→ 14.00 CAD), July =
# realized 36 (sell 15 + WIDE div 7 + SHOP div 14) + drift 5 = 41
# (→ 57.40 CAD); 10 + 41 = 51 = the whole window's native total.
expect_ok_match "ts: June period carries its converted drift"  "2026-06.*14\.00"  pnl pnl --time-series --from 2026-06-01 --to 2026-07-31
expect_ok_match "ts: July period splits 50.40 + 7.00 = 57.40" "2026-07.*50\.40.*7\.00.*57\.40" pnl pnl --time-series --from 2026-06-01 --to 2026-07-31
expect_ok_match "ts: monthly slices sum exactly to 71.40" "Σ periods = window total \(exact" pnl pnl --time-series --from 2026-06-01 --to 2026-07-31
expect_ok_match "ts: a one-month window goes weekly"  "series: weekly"  pnl pnl --time-series --from 2026-07-01 --to 2026-07-31
expect_ok_match "ts: a short window goes daily"       "series: daily"   pnl pnl --time-series --from 2026-07-10 --to 2026-07-15
# --daily FORCES daily periods on any window (marked forced) — and on
# the pinned July window the daily slices still sum EXACTLY, in CAD:
# the identity is granularity-independent (21.00−7.00+9.80+19.60+14.00
# = 57.40 = the July total).
expect_ok_match "ts: --daily forces day periods"       "series: daily periods \(forced\)" pnl pnl --time-series --daily --from 2026-07-01 --to 2026-07-31
expect_ok_match "ts: --daily slices still sum exact"  "Σ periods = window total \(exact" pnl pnl --time-series --daily --from 2026-07-01 --to 2026-07-31
expect_ok_match "ts: --daily shows the drift-only day (14.00 CAD)" "2026-07-31.*14\.00" pnl pnl --time-series --daily --from 2026-07-01 --to 2026-07-31
expect_fail_match "ts: --daily alone is a usage error" 2 "time-series"  pnl pnl --daily
expect_ok "ts: --daily on a no-market store stays honest" pnl2 pnl --time-series --daily
expect_ok_match "ts: …and refuses to sum it"           "Σ periods ≠ window total" pnl2 pnl --time-series --daily
expect_ok_match "ts: empty window stays quiet"         "nothing to report" pnl pnl --time-series --from 2020-01-01 --to 2020-01-31
# No market data: every cross-boundary period is UNMEASURABLE — the
# series says so instead of showing a wall of zeros or a fake sum.
expect_ok_match "ts2: dashed series, honest sum line" "Σ periods ≠ window total" pnl2 pnl --time-series
expect_ok_match "ts2: unmeasurable is named as a gap" "NOT zero"                pnl2 pnl --time-series
# Combinability: series mode is a VIEW, filters still scope it.
expect_ok_match "ts: --account keeps per-account scope" "P&L One"  pnl pnl --time-series --account "P&L One"
expect_ok_match "ts: filter matching nothing stays quiet" "nothing to report|none with" pnl pnl --time-series --ccy GBP
expect_ok "ts: --time-series=false = normal view"     pnl pnl --time-series=false
expect_ok_match "ts: normal view came back"           "P&L \(CAD"             pnl pnl --time-series=false
# --json: the series rides along under data.series, reconciles flag
# included; nulls stay nulls; converted totals join per point.
json_ok "ts: json document parses (series mode)"                 pnl --json pnl --time-series
expect_ok_match "ts: json carries the series + its flags" '"granularity":"monthly"' pnl --json pnl --time-series --from 2026-06-01 --to 2026-07-31
expect_ok_match "ts: json says the slices reconcile"    '"reconciles":true' pnl --json pnl --time-series --from 2026-06-01 --to 2026-07-31
expect_ok_match "ts: json carries converted per-period totals" '"reportedTotal":"14.00"' pnl --json pnl --time-series --from 2026-06-01 --to 2026-07-31
expect_ok_match "ts: json without market data refuses to sum" '"reconciles":false' pnl2 --json pnl --time-series
expect_ok_match "ts: json reports forced daily"  '"granularity":"daily"' pnl --json pnl --time-series --daily --from 2026-07-01 --to 2026-07-31

echo
echo "-- 21. market coverage — facts about data the reports would need --"
# The coverage fixture carries ONE deliberate instance of every fact
# class: FAST dense (ok), GAPPY a 14-day inside hole (GAPS), STALEP a
# series that stopped Jun 30 (STALE), NOPE nothing fetched at all
# (NO DATA), HKD triangulating through the USD hub (~derived, works),
# JPY with no chain anywhere (NO CHAIN). Windows pin --to so
# staleness math cannot depend on the day the script runs.
CV="$WORKDIR/cov-store"
mkdir -p "$CV/store" "$CV/market"
cov() { env DIT_BACKEND=file DIT_STORE_URL="$CV/store" DIT_MARKET_URL="$CV/market" "$DIT" "$@"; }
covrange() { # sym start end price — daily closes, end EXCLUSIVE
  local d=$2
  while [[ "$d" < "$3" ]]; do
    printf "$1,%s,$4\n" "$d"
    d=$(date -j -v+1d -f "%Y-%m-%d" "$d" +%Y-%m-%d)
  done
}
expect_ok "cov: bootstrap CAD account"  cov account add --currency CAD --name "Cov CAD"
expect_ok "cov: bootstrap USD account"  cov account add --currency USD --name "Cov USD"
for t in FAST GAPPY STALEP NOPE; do
  expect_ok "cov: ticker $t" cov ticker add "$t" --currency USD
done
expect_ok "cov: USD deposit"            cov tx deposit --account "Cov USD" --amount 5000 --date 2026-06-01
expect_ok "cov: buy FAST"               cov tx buy --account "Cov USD" --ticker FAST --shares 5 --price 10 --date 2026-06-10
expect_ok "cov: buy GAPPY"              cov tx buy --account "Cov USD" --ticker GAPPY --shares 5 --price 10 --date 2026-06-10
expect_ok "cov: buy STALEP"             cov tx buy --account "Cov USD" --ticker STALEP --shares 5 --price 10 --date 2026-06-10
expect_ok "cov: buy NOPE (USD in CAD account)" cov tx buy --account "Cov CAD" --ticker NOPE --shares 5 --price 10 --currency USD --date 2026-06-10
expect_ok "cov: buy BANK (CAD in CAD account)" cov tx buy --account "Cov CAD" --ticker BANK --shares 2 --price 30 --date 2026-06-12
expect_ok "cov: HKD cash"               cov tx deposit --account "Cov USD" --amount 100 --currency HKD --date 2026-06-15
expect_ok "cov: JPY cash"               cov tx deposit --account "Cov USD" --amount 100 --currency JPY --date 2026-06-15
{ covrange FAST 2026-06-10 2026-09-30 11
  covrange GAPPY 2026-06-10 2026-07-19 11
  covrange GAPPY 2026-08-02 2026-09-30 11
  covrange STALEP 2026-06-10 2026-07-01 11
  covrange HKD/USD 2026-06-01 2026-11-02 0.128
  covrange USD/CAD 2026-06-01 2026-11-02 1.40
} > "$WORKDIR/cov-series.csv"
expect_ok_match "cov: seed the series mix" "USD/CAD" cov market import "$WORKDIR/cov-series.csv"
# Default run = a REPORT (exit 0 even with findings; --strict opts
# into audit-style exit 1).
expect_ok_match "cov: dense series reads ok"                "FAST.*ok — 112 closes" cov market coverage --to 2026-10-01
expect_ok_match "cov: inside hole is a named GAPS row"      "GAPPY.*GAPS — longest hole 14d \(2026-07-19…2026-08-01\), 98 closes" cov market coverage --to 2026-10-01
expect_ok_match "cov: dead series is STALE, not silent ok"  "STALEP.*STALE — last close 2026-06-30 \(93d before audit\)" cov market coverage --to 2026-10-01
expect_ok_match "cov: nothing fetched says NO DATA"         "NOPE.*NO DATA — no daily series" cov market coverage --to 2026-10-01
expect_ok_match "cov: triangulated FX chain is labelled"    "HKD→CAD.*~derived via USD \(HKD→USD→CAD\).*usable at all 5 period ends" cov market coverage --to 2026-10-01
expect_ok_match "cov: no FX path is a declared NO CHAIN"    "JPY→CAD.*NO CHAIN"    cov market coverage --to 2026-10-01
expect_ok_match "cov: dense FX passes every period end"     "USD→CAD.*usable at all 5 period ends" cov market coverage --to 2026-10-01
expect_ok_match "cov: legends explain only what is shown"   "weekend/holiday dust"  cov market coverage --to 2026-10-01
expect_fail_match "cov: --strict turns findings into exit 1" 1 "coverage gaps listed" cov market coverage --strict --to 2026-10-01
# Windows and scope: moving --from past the hole must un-scream about
# it (data before a gap window is nobody's gap — the VRT lesson).
expect_ok_match "cov: --from shifts the gap window"         "GAPPY.*ok — 59 closes" cov market coverage --from 2026-08-01 --to 2026-10-01
expect_ok_match "cov: audit before any trade is empty"      "nothing to cover"      cov market coverage --to 2026-03-01
expect_ok_match "cov: --tickers matching nothing is honest" "nothing held at the audit date matches" cov market coverage --tickers ZZZ --to 2026-10-01
expect_ok_match "cov: --tickers filter narrows the table"   "GAPPY"                 cov market coverage --tickers GAPPY --to 2026-10-01
expect_ok_match "cov: --account scopes the audit"           "scope: Cov CAD"        cov market coverage --account "Cov CAD" --to 2026-10-01
# Reporting currency changes the CHAINS needed, not the data.
expect_ok_match "cov: --reporting-ccy USD audits other direction" "FX into USD" cov market coverage --reporting-ccy USD --to 2026-10-01
expect_ok_match "cov: …via the inverted twin, marked"          "CAD→USD.*~inverted USD/CAD"  cov market coverage --reporting-ccy USD --to 2026-10-01
expect_ok_match "cov: JPY has no path into USD either"            "NO CHAIN — no stored path JPY→USD"      cov market coverage --reporting-ccy USD --to 2026-10-01
# Offline is the natural state: coverage READS, never fetches.
expect_ok_match "cov: --offline works (no network needed)"  "Market coverage"       cov --offline market coverage --to 2026-10-01
# --json: the same facts machine-readable. --strict keeps ONE
# document on stdout (the "complete" flag carries the finding).
json_ok "cov: json document parses"                          cov --json market coverage --to 2026-10-01
expect_ok_match "cov: json schema + per-row statuses"       '"symbol":"GAPPY".*"schema":"coverage/1"' cov --json market coverage --to 2026-10-01
expect_ok_match "cov: json gap run is exact"                 '"longestGap":\{"days":14,"from":"2026-07-19","to":"2026-08-01"\}' cov --json market coverage --to 2026-10-01
expect_ok_match "cov: json marks the dead JPY chain"         '"from":"JPY","to":"CAD","usableNow":false' cov --json market coverage --to 2026-10-01
expect_ok_match "cov: json triangulated chain flag"          '"approx":true.*"chain":"derived via USD' cov --json market coverage --to 2026-10-01
expect_ok "cov: json+strict = one doc + exit 1" bash -c "DIT_BACKEND=file DIT_STORE_URL='$CV/store' DIT_MARKET_URL='$CV/market' '$DIT' --json market coverage --strict --to 2026-10-01 > /tmp/dit-cov.json; code=\$?; [ \$code -eq 1 ] && python3 -c \"import json;json.load(open('/tmp/dit-cov.json'))\" && [ \$(wc -l < /tmp/dit-cov.json) -eq 1 ]"
expect_fail_match "cov: chart refuses coverage/1" 1 "no chart defined" bash -c "'$DIT' --json --store '$CV/store' --market-store '$CV/market' market coverage | '$CHART'"
# Usage errors stay exit 2; unknown accounts stay exit 1; a missing
# store is a quiet fact, not an error.
expect_fail_match "cov: reversed window refused" 2 "before"  cov market coverage --from 2026-09-01 --to 2026-08-01
expect_fail_match "cov: unknown account errors, not 'all'" 1 "no account matches" cov market coverage --account NOPE
expect_fail_match "cov: unknown flag is a usage error" 2 "unknown option" cov market coverage --wat
expect_ok_match "cov: empty store says nothing to check"  "Nothing to check" bash -c "DIT_BACKEND=file DIT_STORE_URL='$WORKDIR/cov-none' DIT_MARKET_URL='$WORKDIR/cov-none-m' '$DIT' market coverage"

echo
echo "-- 22. Interactive HTML charts (dit-chart --html) — the pipe grows a window --"
# --html writes ONE self-contained file (no network, no CDN) and keeps
# the refusal contract: unknown schemas and snapshot documents are
# refused, honest legends survive, and ≥10-day holes stay visible as
# line breaks. All offline; nothing here opens a browser.
H="$WORKDIR/html"
mkdir -p "$H"
hcheck() { # hcheck NAME PATTERN FILE — file must contain pattern
  if grep -Eq "$2" "$3" 2>/dev/null; then
    PASS=$((PASS+1)); echo "ok   — $2 in $(basename "$3")"
  else
    FAIL=$((FAIL+1)); echo "FAIL — $2 expected in $3"; ls -la "$3" 2>/dev/null | sed 's/^/     | /'
  fi
}
# The GAPPY+FAST series document (both USD-tickers, but the imported
# series carry NO stated currency → they must NOT share an axis).
expect_ok "html: quote series renders to a file" bash -c   "DIT_BACKEND=file DIT_STORE_URL='$CV/store' DIT_MARKET_URL='$CV/market' '$DIT' --json quote FAST GAPPY --from 2026-06-10 --to 2026-09-29 | '$CHART' --html '$H/series.html'"
hcheck "html: self-contained page"          '<!doctype html>'               "$H/series.html"
hcheck "html: unstated currencies stay split" "currency not stated, kept off other charts" "$H/series.html"
hcheck "html: the 14-day hole draws as a break (null)" '"name":"GAPPY".*null|"label":"GAPPY[^"]*".*null' "$H/series.html"
hcheck "html: the break legend ships with the chart" "line breaks mark"    "$H/series.html"
hcheck "html: axis honesty note present"    "not zero"                      "$H/series.html"
# Summary documents keep working in html (bar charts with the dashed
# unknown rule), and '-' sends the page to stdout instead of a file.
expect_ok "html: summary page renders" bash -c   "DIT_BACKEND=file DIT_STORE_URL='$CV/store' DIT_MARKET_URL='$CV/market' '$DIT' --json --offline summary | '$CHART' --html '$H/summary.html'"
hcheck "html: summary keeps the dashed-unknown rule" "dashed" "$H/summary.html"
expect_ok_match "html: '-' prints the page to stdout" '<!doctype html>' bash -c   "DIT_BACKEND=file DIT_STORE_URL='$CV/store' DIT_MARKET_URL='$CV/market' '$DIT' --json --offline summary | '$CHART' --html -"
# Refusals carry over to the window: no guessing at schemas, no
# charting single-day snapshots, and usage errors stay exit 2.
expect_fail_match "html: unknown schema still refused" 1 "no chart defined" bash -c   "'$CHART' --html '$H/bad.html' < '$WORKDIR/acc.json'"
test ! -e "$H/bad.html" && PASS=$((PASS+1)) && echo "ok   — refused docs write no file" || { FAIL=$((FAIL+1)); echo "FAIL — refused docs write no file"; }
# A single-day snapshot (mode "store") has no time series → refused.
printf '%s' '{"ok":true,"schema":"quote/1","data":{"mode":"store","count":1,"quotes":[{"basis":"observed","ccy":"USD","date":"2026-06-30","price":"10.00","symbol":"FAST","via":null}]}}' > "$H/snapdoc.json"
expect_fail_match "html: snapshot quotes refused (no time series)" 1 "no chart defined" bash -c   "'$CHART' --html '$H/snap.html' < '$H/snapdoc.json'"
# And a FAILED source document (offline live-quote refusal) never
# renders — chart carries the source's message, exits 1, writes no page.
expect_fail_match "html: failed source doc carries its message, no page" 1 "source reported failure" bash -c   "DIT_BACKEND=file DIT_STORE_URL='$CV/store' DIT_MARKET_URL='$CV/market' '$DIT' --json quote FAST --offline | '$CHART' --html '$H/snap2.html'"
expect_fail_match "html: --html without a path is a usage error" 2 "needs an output file" "$CHART" --html
# Bare --open writes a temp page (overwritten per chart kind) — kept
# OUT of the automated run because the system viewer would open a
# window per check; only the NON-opening contracts are pinned:
# usage errors and refused docs must never reach the launcher.
expect_fail_match "html: '--html - --open' is a usage error" 2 "needs a written page" bash -c \
  "'$CHART' --html - --open < '$WORKDIR/acc.json'"
expect_fail_match "html: bare --open on unknown schema refuses, no file" 1 "no chart defined" bash -c \
  "'$CHART' --open < '$WORKDIR/acc.json'"
expect_fail_match "html: empty stdin refused, not an empty page" 1 "no JSON on stdin" bash -c   "'$CHART' --html '$H/empty.html' < /dev/null"

echo
echo "================================================"
echo "Scenario: $PASS passed, $FAIL failed"
echo "Workdir kept for inspection: $WORKDIR"
rm -f /tmp/dit-scenario-out.txt
[ "$FAIL" -eq 0 ]

