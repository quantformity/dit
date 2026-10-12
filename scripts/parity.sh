#!/usr/bin/env bash
# dit — parity harness: run the same command through the Swift binary and the
# Go port against the SAME store and compare the bytes.
#
# This is the acceptance instrument for the port. It is not "does the Go code
# run" — it is "does the Go code answer the same question the same way". A
# command counts as ported only when it shows here, which is why the Go side
# refuses unported commands instead of approximating them.
#
# Usage: scripts/parity.sh [COMMAND ...]
#        scripts/parity.sh              # runs the default list
# Exit:  0 when every compared command matches byte for byte.
set -u

SWIFT="${SWIFT:-dit}"                       # the reference binary
GO="${GO:-$(dirname "$0")/../.build/ditgo}" # the port under test
FIXTURE="$(cd "$(dirname "$0")/.." && pwd)/testdata/fixtures/richstore"
WORK="$(mktemp -d /tmp/dit-parity.XXXXXX)"

# Copy the fixture so a command that writes cannot disturb the checked-in one.
cp -R "$FIXTURE/store" "$WORK/store"
cp -R "$FIXTURE/market" "$WORK/market"
export DIT_BACKEND=file
export DIT_STORE_URL="$WORK/store"
export DIT_MARKET_URL="$WORK/market"

if [ "$#" -gt 0 ]; then
  COMMANDS=("$@")
else
  COMMANDS=(
    "store path"
    "accounts"
  )
fi

PASS=0
FAIL=0
for command in "${COMMANDS[@]}"; do
  expected="$("$SWIFT" $command 2>&1)"
  actual="$("$GO" $command 2>&1)"
  if [ "$expected" = "$actual" ]; then
    printf 'ok   — dit %s\n' "$command"
    PASS=$((PASS + 1))
  else
    printf 'FAIL — dit %s\n' "$command"
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | head -12
    FAIL=$((FAIL + 1))
  fi
done

echo
echo "Parity: $PASS matched, $FAIL differed"
[ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK"
[ "$FAIL" -eq 0 ]