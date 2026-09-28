#!/usr/bin/env bash
#
# add-opening-deposits.sh — generated 2026-09-28
#
# Reconciles the imported cash pools with the real brokerage balances.
#
# Why: investments.db is a holdings snapshot; it never recorded the 2025
# opening funding, so every pool that spent money came out short. This
# adds one opening entry per pool so each pool ends exactly at the real
# balance you reported:
#   CAD Margin 109.36 CAD | USD Margin 448.40 USD | CAD TSFA 3,252.60 CAD
#   CAD RRSP 25,920.64 CAD | USD RRSP 775.60 USD | CAD Business Cash
#   38,010.06 CAD | USD Business Cash 1,119.52 USD | CAD RESP 186.32 CAD
#   HSBC 0 USD (confirmed)
#
# Deposits are dated 2024-12-31 ("funded just before the snapshot") —
# change to real funding dates if you know them.
#
# ASSUMPTIONS — review before running:
#  1. "USD TSFA: 0 USD" is treated as a SEPARATE empty account (your
#     correction): created below with no transactions, no cash entries.
#  2. The two 2026-05-01 RBLX sells in 'CAD TSFA' left 4,670.00 USD in the
#     ledger's USD pool. Your real balances show no USD cash at TSFA, so
#     the script books it as an fx conversion to CAD (source's own
#     2026-05-01 rate 1.3575 -> 6,339.525 CAD), which is what the CAD TSFA
#     deposit below is sized around. If the money actually LEFT the account
#     instead, replace the fx line with:
#       $DIT tx withdraw --account "CAD TSFA" --amount 4670 --currency USD --date 2026-05-01
#     and change the CAD TSFA deposit to 28483.100025 (no fx inflow).
#  3. The USD pools inside CAD RRSP / CAD Business Cash / CAD Margin are
#     assumed 0 (USD-listed buys in CAD accounts paid out of CAD via the
#     broker's auto-conversion). If your broker shows real USD sub-balances
#     there, raise the matching deposits.
#
# Not idempotent — each pool gets exactly one opening entry.

set -uo pipefail
command -v dit >/dev/null || { echo "need 'dit' on PATH" >&2; exit 2; }

echo "== adding USD TSFA (empty account) and opening cash entries =="

# your real account that never had transactions (nothing to import):
dit account add --currency USD --name "USD TSFA" --non-taxable

# --- opening deposits: one per pool, sized so pool lands exactly on the
# --- reported balance; comment shows pool balance before -> after
dit tx deposit --account "CAD Margin"         --amount 8543.88      --date 2024-12-31 --currency CAD  # -8,434.52 -> 109.36
dit tx deposit --account "CAD Margin"         --amount 2195.93      --date 2024-12-31 --currency USD  # -2,195.93 -> 0 (assumption 3)
dit tx deposit --account "USD Margin"          --amount 48234.9152  --date 2024-12-31 --currency USD  # -47,786.5152 -> 448.40
dit tx deposit --account "CAD TSFA"            --amount 22143.575025 --date 2024-12-31 --currency CAD  # -25,230.500025 -> 3,252.60 (after the fx inflow below)
dit tx deposit --account "CAD RRSP"            --amount 54642.31276 --date 2024-12-31 --currency CAD  # -28,721.67276 -> 25,920.64
dit tx deposit --account "CAD RRSP"            --amount 3846.7      --date 2024-12-31 --currency USD  # -3,846.70 -> 0 (assumption 3)
dit tx deposit --account "USD RRSP"            --amount 17035.11    --date 2024-12-31 --currency USD  # -16,259.51 -> 775.60
dit tx deposit --account "CAD Business Cash"   --amount 27795.21    --date 2024-12-31 --currency CAD  # 10,214.85 -> 38,010.06
dit tx deposit --account "CAD Business Cash"   --amount 9541.754    --date 2024-12-31 --currency USD  # -9,541.754 -> 0 (assumption 3)
dit tx deposit --account "USD Business Cash"   --amount 71085.874   --date 2024-12-31 --currency USD  # -69,966.354 -> 1,119.52
dit tx deposit --account "CAD RESP"            --amount 18591.453   --date 2024-12-31 --currency CAD  # -18,405.133 -> 186.32
dit tx deposit --account "HSBC"                --amount 161557      --date 2024-12-31 --currency USD  # -161,557 -> 0 (confirmed)

# CAD TSFA USD pool: the two 2026-05-01 RBLX sale proceeds, converted to
# CAD at the source's 2026-05-01 USD/CAD rate (assumption 2)
dit tx fx --account "CAD TSFA" --from USD --to CAD --from-amount 4670 --to-amount 6339.525 --date 2026-05-01

# --- verify
echo "== accounts =="
dit accounts
echo "== summary =="
dit summary