#!/usr/bin/env bash
# txpnl-recon.sh — e2e helper: the transaction-level P&L view and the
# window P&L engine must AGREE for the same scope (dual-engine check).
#
# Compares, per currency:
#   sum(tx-pnl/1 currencyTotals.total)  ==  sum(pnl/1 currencyTotals.total)
# within a half-cent of Decimal regrouping dust. Both views must also
# EITHER both produce a total or both withhold it (a dash matching a
# dash is agreement; a number against a dash is a split).
#
# Usage: txpnl-recon.sh <DIT> [store] [market]   (prints RECON_OK on success)
# With explicit paths, runs in file mode against them; without, the
# ambient store/market config is used as-is (works against a live
# sqlite store too — the dual-engine check is backend-agnostic).
set -u
DIT="$1"
if [ "$#" -ge 3 ]; then
  export DIT_BACKEND=file DIT_STORE_URL="$2" DIT_MARKET_URL="$3"
fi
T=$(mktemp); W=$(mktemp)
"$DIT" --json tx pnl > "$T" || { echo "tx pnl run failed"; exit 1; }
"$DIT" --json pnl     > "$W" || { echo "pnl run failed"; exit 1; }
python3 - "$T" "$W" <<'PY'
import json, sys
t = json.load(open(sys.argv[1]))["data"]
w = json.load(open(sys.argv[2]))["data"]
def totals(doc):
    return {c["currency"]: c["total"] for c in doc["currencyTotals"]}
tt, wt = totals(t), totals(w)
if set(tt) != set(wt):
    sys.exit(f"currency sets differ: {sorted(tt)} vs {sorted(wt)}")
for ccy in tt:
    a, b = tt[ccy], wt[ccy]
    if (a is None) != (b is None):
        sys.exit(f"{ccy}: one view prints a total ({a} vs {b}) while the other dashes")
    if a is not None and abs(float(a) - float(b)) >= 0.005:
        sys.exit(f"{ccy}: totals disagree: {a} vs {b}")
# Sanity: the pinned fixture has real P&L to reconcile, not just empties.
if not any(v is not None for v in tt.values()):
    sys.exit("both views withheld everything — nothing was actually reconciled")
print("RECON_OK")
PY