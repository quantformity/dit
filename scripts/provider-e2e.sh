#!/usr/bin/env bash
# Provider e2e: the summary pinned to a market answer.
#
#   bash scripts/provider-e2e.sh
#
# The same pin file, run twice, must give the same summary — apart from the
# clock line. A pinned summary is a pure function of (ledger, market
# document, pin, display currency), which is what makes twin-runs and
# regression checks honest: the network is not in the equation.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -x .build/ditgo ]; then
  go build -o .build/ditgo ./cmd/dit
fi

STORE="$(pwd)/testdata/fixtures/richstore/store"
MARKET="$(pwd)/testdata/fixtures/richstore/market"
PIN="$(pwd)/testdata/pin.example.json"

run() {
  DIT_BACKEND=file DIT_STORE_URL="$STORE" DIT_MARKET_URL="$MARKET" DIT_PROVIDER_STUB="$PIN" \
    .build/ditgo summary --json --display CAD
}

strip_clock() {
  python3 -c '
import json, sys
d = json.load(sys.stdin)
d.pop("generatedAt", None)
d["data"].pop("generatedAt", None)
print(json.dumps(d, sort_keys=True, indent=2))
'
}

first=$(run)
second=$(run)

fail() {
  echo "provider-e2e: FAIL: $*" >&2
  exit 1
}

a=$(printf '%s' "$first" | strip_clock)
b=$(printf '%s' "$second" | strip_clock)
[ "$a" = "$b" ] || fail "two runs with the same pin differ (not deterministic)"

check() {
  # $1 = label; $2 = python expression against `d` that must be true.
  expr="$2"
  if ! printf '%s' "$first" | python3 -c "
import json, sys
d = json.load(sys.stdin)['data']
holdings = d['holdings']
shop = next(h for h in holdings if h['symbol'] == 'SHOP.TO')
if not ($expr):
    sys.exit(1)
"; then
    fail "$1"
  fi
}

check "the pin must be what prices the holding" 'shop["value"] == "1462.98"'
check "the quote block must carry the pin" 'shop["quote"]["price"] == "243.83"'
check "the day change must be against the stored previous close" 'shop["dayChange"] == "904.38"'
check "a healthy run is not degraded" "d['degraded'] == False and d['offline'] == False"

echo "provider-e2e: PASS (deterministic under pin; value = 6 x 243.83; day change vs stored 93.10)"
