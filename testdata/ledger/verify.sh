#!/usr/bin/env bash
# Run after the parent merges txListSpecs into commandSpecs. The fixture was
# recorded by Swift; no entry commands or network are needed for this check.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GO="${1:-$ROOT/.build/ditgo}"
SWIFT="${SWIFT_DIT:-/opt/homebrew/bin/dit}"
WORK="$(mktemp -d "$ROOT/.build/ledger-check.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/store" "$WORK/market"
cp "$ROOT/testdata/ledger/portfolio.json" "$WORK/store/portfolio.dat"
export DIT_BACKEND=file DIT_STORE_URL="$WORK/store" DIT_MARKET_URL="$WORK/market" NO_COLOR=1
"$GO" tx list > "$WORK/actual"
diff -u "$ROOT/testdata/ledger/statement.txt" "$WORK/actual"
for expected in "$ROOT"/testdata/ledger/show-*.txt; do
 id="${expected##*/show-}"; id="${id%.txt}"
 "$GO" tx show "$id" > "$WORK/actual"
 diff -u "$expected" "$WORK/actual"
done
compare() {
 "$SWIFT" "$@" > "$WORK/expected"
 "$GO" "$@" > "$WORK/actual"
 diff -u "$WORK/expected" "$WORK/actual"
}
compare tx list --account TFSA
compare tx list --account Mercury
compare tx list --kind buy
compare tx list --kind gic_redemption
compare tx list --ticker ' shop.to '
compare tx list --since 2028-01-01
compare tx list --until 2026-01-02
compare tx list --limit 3
compare tx list --since 2030-01-01
compare tx list --account TFSA --kind sell --limit 1
compare tx ls --limit 2
# A read, including an unsuccessful one, must not change the ledger document.
"$GO" tx show NOT_AN_ID > "$WORK/actual" 2>/dev/null && exit 1
cmp "$ROOT/testdata/ledger/portfolio.json" "$WORK/store/portfolio.dat"
echo 'Ledger fixture: all byte comparisons passed.'
