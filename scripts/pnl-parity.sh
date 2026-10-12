#!/usr/bin/env bash
# The parent owns table.go. Until pnlSpecs is wired there, build an instrumented
# binary using a temporary, build-tagged adapter (no owned file is edited).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
mkdir -p .build
if [ "${1:-}" = --baseline ]; then
  go build -o .build/ditgo-pnl-baseline ./cmd/dit
  export GO="$ROOT/.build/ditgo-pnl-baseline"
else
  ADAPTER=internal/cli/zz_pnl_parity.go
  if ! grep -q 'mergeLayers(.*pnlSpecs' internal/cli/table.go; then
    [ ! -e "$ADAPTER" ] || { echo "adapter already exists: $ADAPTER" >&2; exit 1; }
    trap 'rm -f "$ADAPTER"' EXIT
    printf '//go:build pnlparity\n\npackage cli\n\nfunc init() { marketSpecs["pnl"] = pnlSpecs["pnl"] }\n' > "$ADAPTER"
  fi
  go build -tags pnlparity -o .build/ditgo-pnl ./cmd/dit
  export GO="$ROOT/.build/ditgo-pnl"
fi
export CHECK_READ_ONLY=1
# The normal fixture's pnl probes are also part of twin-run's default set.
python3 - <<'PY'
import pathlib, re, subprocess
probes = re.findall(r'^    "(pnl[^\"]*)"', pathlib.Path('scripts/twin-run.sh').read_text(), re.M)
raise SystemExit(subprocess.call(['scripts/twin-run.sh', *probes]))
PY
PNL_FIXTURE=1 scripts/twin-run.sh \
 'pnl --from 2024-06-15 --to 2024-06-18' \
 'pnl --from 2024-06-15 --to 2024-06-18 --json' \
 'pnl --from 2024-06-15 --to 2024-06-18 --ccy USD,HKD --tickers WIDE,PROXY,ROUND,HKINC --json' \
 'pnl --from 2024-06-15 --to 2024-06-18 --ccy USD,HKD --tickers WIDE,PROXY,ROUND,HKINC' \
 'pnl --time-series --daily --from 2024-06-15 --to 2024-06-18 --tickers WIDE,PROXY,ROUND,HKINC' \
 'pnl --time-series --daily --from 2024-06-15 --to 2024-06-18 --tickers WIDE,PROXY,ROUND,HKINC --json' \
 'pnl --from 2024-06-15 --to 2024-06-25 --tickers WIDE,HKINC --json' \
 'pnl --from 2024-06-15 --to 2024-06-26 --tickers WIDE,HKINC --json' \
 'pnl --from 2024-06-15 --to 2024-06-18 --tickers PROXY --reporting-ccy USD' \
 'pnl --from 2024-06-15 --to 2024-06-18 --tickers WRONG,GAP --json' \
 'pnl --from 2024-06-15 --to 2024-06-18 --tickers HKINC --reporting-ccy USD --json' \
 'pnl --from 2024-06-15 --to 2024-06-18 --tickers JPINC --json' \
 'pnl --from 2024-06-15 --to 2024-06-18 --account Margin,TFSA' \
 'pnl --from 2024-06-15 --to 2024-06-18 --tickers SHORT --json'
