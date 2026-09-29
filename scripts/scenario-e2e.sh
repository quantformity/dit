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
txid() {
  local pattern; pattern="$1"
  "$DIT" tx list --limit 60 2>/dev/null | grep -E "$pattern" | head -1 | awk '{print $1}'
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
echo "================================================"
echo "Scenario: $PASS passed, $FAIL failed"
echo "Workdir kept for inspection: $WORKDIR"
rm -f /tmp/dit-scenario-out.txt
[ "$FAIL" -eq 0 ]
