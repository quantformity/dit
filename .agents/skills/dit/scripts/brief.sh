#!/usr/bin/env bash
#
# brief.sh — one-shot, READ-ONLY portfolio briefing built on `dit --json`.
#
# Prints store facts, portfolio totals + top holdings, the market-data
# coverage audit (the holes a P&L report would dash on), and a windowed P&L.
# Never writes, never mutates the ledger or the market store.
#
# Usage:
#   brief.sh                     offline summary (no network)
#   brief.sh --live              allow live quote fetching for the summary
#   brief.sh --days 90           P&L window (default: the whole ledger)
#   brief.sh --store PATH        non-default portfolio store
#
# Exit: 0 briefing produced, 2 usage error / `dit` not on PATH.

set -uo pipefail

MODE=offline
DAYS=
STORE=
# NOTE: `shift` inside `for arg in "$@"` iterates the ORIGINAL list, so a
# value like `--days 90` would come back around as an unknown option.
while [ $# -gt 0 ]; do
  case "$1" in
    --live) MODE=live ;;
    --days) case "${2:-}" in (''|*[!0-9]*) echo "--days needs a number, got: ${2:-}" >&2; exit 2 ;; esac
            DAYS="$2"; shift ;;
    --store) [ -n "${2:-}" ] || { echo "--store needs a path" >&2; exit 2; }
             STORE="$2"; shift ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

command -v dit >/dev/null 2>&1 || {
  echo "x 'dit' is not on PATH — build it (swift build -c release, then scripts/build.sh) or point --store at the data and run from the repo." >&2
  exit 2
}

HERE=$(dirname "$0")
FORMAT="$HERE/format_json.py"
HAVE_PY=false
command -v python3 >/dev/null 2>&1 && [ -f "$FORMAT" ] && HAVE_PY=true

OFFLINE=()
[ "$MODE" = offline ] && OFFLINE=(--offline)
STORE_OPT=()
[ -n "$STORE" ] && STORE_OPT=(--store "$STORE")

# One parse path per block: capture the document AND its exit code, then
# judge both — empty or failed output must never read as "no positions".
run_json() {
  label="$1"; shift
  out=$(dit ${STORE_OPT[@]+"${STORE_OPT[@]}"} ${OFFLINE[@]+"${OFFLINE[@]}"} --json "$@" 2>&1); rc=$?
  echo "## $label  (exit $rc)"
  if [ $rc -ne 0 ]; then
    echo "_not available: $(printf '%s' "$out" | head -c 300)_"
  elif [ "$HAVE_PY" = true ]; then
    printf '%s\n' "$out" | python3 "$FORMAT"
  else
    printf '%s\n' "$out" | head -c 2000
  fi
  echo
}

echo "# Portfolio briefing — $(date '+%Y-%m-%d %H:%M %Z') — ${MODE} summary"
echo
echo "Store: $(dit ${STORE_OPT[@]+"${STORE_OPT[@]}"} store path 2>&1 | tr '\n' ' ')"
echo
run_json "Summary" summary
run_json "Market-data coverage (the holes a P&L would dash on)" market coverage
if [ -n "$DAYS" ]; then
  run_json "P&L — last ${DAYS}d" pnl --horizon "${DAYS}d"
else
  run_json "P&L — whole ledger" pnl
fi
echo "_Dashes are unknowns, not zeros. A DERIVED / backfilled figure is a model, not a quote._"
