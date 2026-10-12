#!/usr/bin/env bash
# Run the Swift repo's 400-assertion scenario suite against the Go binary.
#
# This is the port's acceptance gate. The script was written to test the Swift
# CLI, and it honours a DIT= override, so the same assertions that prove the
# Swift tool also prove the Go one — no new test prose to write, and no way
# for the port to pass a test the original never had to answer.
#
# Usage: scripts/e2e-parity.sh [SUITE]
#   SUITE defaults to ../dit/scripts/scenario-e2e.sh
set -u
SUITE="${1:-$(dirname "$0")/../../dit/scripts/scenario-e2e.sh}"
GO="${GO:-$(dirname "$0")/../.build/ditgo}"
[ -f "$SUITE" ] || { echo "no suite at $SUITE"; exit 1; }
echo "== $SUITE against $GO =="
DIT="$GO" bash "$SUITE" 2>&1 | tail -40
