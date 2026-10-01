#!/usr/bin/env bash
#
# import-investments.sh — generated from investments.db (2026-09-28)
#   source: ~/Library/Mobile Documents/.../financial/investments.db
#   generated read-only from the /tmp/investments.db copy; this script
#   contains literal `dit` commands only (no DB access at run time).
#
# WHAT IT DOES
#   1. Creates the 9 accounts from the `accounts` table
#      (tax-free inferred from name: TSFA/RRSP/RESP).
#   2. Seeds the ticker registry with company names from `market_data`.
#   3. Replays the ledger:
#        positions(category='Equity')  -> dit tx buy   (each lot = one buy)
#        positions(category='Cash')    -> dit tx deposit (positive) /
#                                         dit tx withdraw (negative)
#        positions(category='GIC')     -> dit tx gic
#        positions(category='Dividend')-> dit tx deposit  (payer ticker is
#                                         not stored in the source)
#        sell_transactions             -> dit tx sell   (proceeds booked in
#                                         the stock's currency, as in source)
#      Events are replayed per account chronologically; on the same date
#      deposits run before buys so cash pools stay as high as possible.
#
# EXPECTED WARNINGS (loud on purpose — all entries still record, exit 0):
#   * Many rows carry the source app's placeholder date 2025-01-01 and the
#     source never recorded 2025 opening CASH deposits, so some accounts may
#     warn 'cash goes negative'. Those warnings mark where the snapshot has
#     no cash history — add explicit opening deposits if you want them gone.
#   * The two RBLX sells in 'CAD TSFA' reference RBLX that account never
#     bought in the source; dit records them and flags the account as
#     SHORT RBLX (untracked short) until something covers it.
#   * 'CAD Business Cash' has two identical 20000 CAD deposits on
#     2026-04-17 in the source; both are kept (duplicate kept faithfully —
#     comment one out if it was a source-data bug).
#   * tx gic records the run date (no --date flag); a post-step right after
#     the GIC re-dates it to the source's 2025-01-01.
#
# TARGET STORE — change if you don't want to import into the default store:
#   DIT_STORE_URL="$HOME/scratch/dit-import" bash scripts/import-investments.sh
#   (that's exactly how this script was verified green before shipping)
# Default store: `…/Application Support/dit`, falling back to the
# pre-rename `…/DirectInvestTracker` folder — mirroring what dit itself
# resolves, because this script may run against older dit builds.
if [ -z "${DIT_STORE_URL:-}" ]; then
  if [ -d "$HOME/Library/Application Support/dit" ]; then
    export DIT_STORE_URL="$HOME/Library/Application Support/dit"
  else
    export DIT_STORE_URL="$HOME/Library/Application Support/DirectInvestTracker"
  fi
fi
DIT="${DIT:-dit}"
#
# NOT IDEMPOTENT: account/ticker names already in the target store make the
# matching `account add`/`ticker add` lines fail (exit 1) and `set -e` stops the
# run. Run it into a store that does not already contain these 9 account names
# (a fresh store is the intended target). To re-run from scratch, point
# DIT_STORE_URL at a brand-new directory.

set -euo pipefail
command -v "$DIT" >/dev/null || { echo "need the 'dit' binary on PATH" >&2; exit 2; }

echo "== importing into store: $DIT_STORE_URL"

# --- accounts ---
$DIT account add --currency CAD --name "CAD TSFA" --non-taxable  # typo in source name kept as-is
$DIT account add --currency USD --name "USD Margin" --taxable
$DIT account add --currency USD --name "USD RRSP" --non-taxable
$DIT account add --currency CAD --name "CAD RRSP" --non-taxable
$DIT account add --currency CAD --name "CAD Business Cash" --taxable
$DIT account add --currency CAD --name "CAD RESP" --non-taxable
$DIT account add --currency USD --name "HSBC" --taxable
$DIT account add --currency CAD --name "CAD Margin" --taxable
$DIT account add --currency USD --name "USD Business Cash" --taxable

# --- ticker registry (names from market_data) ---
$DIT ticker add AAPL --name "Apple Inc." --currency USD
$DIT ticker add EWJ --name "iShares MSCI Japan ETF" --currency USD
$DIT ticker add EWT --name "iShares MSCI Taiwan ETF" --currency USD
$DIT ticker add GOOG --name "Alphabet Inc." --currency USD
$DIT ticker add GOOG.NE --name "Alphabet Inc." --currency CAD
$DIT ticker add IAU --name "iShares Gold Trust" --currency USD
$DIT ticker add MSFT --name "Microsoft Corporation" --currency USD
$DIT ticker add MSFT.TO --name "Microsoft Corporation" --currency CAD
$DIT ticker add NVDA --name "NVIDIA Corporation" --currency USD
$DIT ticker add NVDA.NE --name "NVIDIA Corporation" --currency CAD
$DIT ticker add PHYS.TO --name "Sprott Physical Gold Trust" --currency CAD
$DIT ticker add PLTR --name "Palantir Technologies Inc." --currency USD
$DIT ticker add RBLX --name "Roblox Corporation" --currency USD
$DIT ticker add TEM --name "Tempus AI, Inc." --currency USD
$DIT ticker add TSLA --name "Tesla, Inc." --currency USD
$DIT ticker add TSLA.NE --name "Tesla, Inc." --currency CAD
$DIT ticker add TSM --name "Taiwan Semiconductor Manufacturing Company Limited" --currency USD
$DIT ticker add VRT --name "Vertiv Holdings Co" --currency USD

# --- CAD TSFA ---
$DIT tx buy --account "CAD TSFA" --ticker NVDA.NE --shares 200 --price 42.7674 --date 2025-01-01 --currency CAD
$DIT tx buy --account "CAD TSFA" --ticker MSFT.TO --shares 150 --price 28.5066 --date 2025-01-01 --currency CAD
$DIT tx buy --account "CAD TSFA" --ticker TSLA.NE --shares 200 --price 32.9749 --date 2025-01-01 --currency CAD
$DIT tx deposit --account "CAD TSFA" --amount 4030.43 --date 2026-04-08 --currency CAD
$DIT tx buy --account "CAD TSFA" --ticker MSFT.TO --shares 75 --price 26.89 --date 2026-04-08 --currency CAD
$DIT tx buy --account "CAD TSFA" --ticker NVDA.NE --shares 50 --price 43.33 --date 2026-04-14 --currency CAD
$DIT tx withdraw --account "CAD TSFA" --amount 9.99 --date 2026-04-14 --currency CAD
$DIT tx withdraw --account "CAD TSFA" --amount 2166.5 --date 2026-04-14 --currency CAD
$DIT tx buy --account "CAD TSFA" --ticker MSFT.TO --shares 60 --price 30 --date 2026-04-17 --currency CAD
$DIT tx withdraw --account "CAD TSFA" --amount 9.99 --date 2026-04-17 --currency CAD
$DIT tx withdraw --account "CAD TSFA" --amount 1800 --date 2026-04-17 --currency CAD
$DIT tx deposit --account "CAD TSFA" --amount 0.39 --date 2026-04-20 --currency CAD
$DIT tx deposit --account "CAD TSFA" --amount 6325.963575 --date 2026-05-01 --currency CAD
# source sell_transactions id=1; proceeds booked in USD (account is CAD)
$DIT tx sell --account "CAD TSFA" --ticker RBLX --shares 50 --price 46.7 --date 2026-05-01 --currency USD
# source sell_transactions id=2; proceeds booked in USD (account is CAD)
$DIT tx sell --account "CAD TSFA" --ticker RBLX --shares 46.7 --price 50 --date 2026-05-01 --currency USD
$DIT tx withdraw --account "CAD TSFA" --amount 100 --date 2026-05-01 --currency CAD
$DIT tx buy --account "CAD TSFA" --ticker TSLA.NE --shares 100 --price 30.601 --date 2026-09-03 --currency CAD
$DIT tx withdraw --account "CAD TSFA" --amount 3051 --date 2026-09-03 --currency CAD
# source row is category=Dividend (CASH 17.9964) but stores no paying ticker; recorded as a deposit
$DIT tx deposit --account "CAD TSFA" --amount 17.9964 --date 2026-09-15 --currency CAD

# --- USD Margin ---
$DIT tx deposit --account "USD Margin" --amount 383.71 --date 2025-01-01 --currency USD
$DIT tx buy --account "USD Margin" --ticker NVDA --shares 100 --price 150.7525 --date 2025-01-01 --currency USD
$DIT tx buy --account "USD Margin" --ticker RBLX --shares 20 --price 68.3545 --date 2025-01-01 --currency USD
$DIT tx buy --account "USD Margin" --ticker EWJ --shares 100 --price 71.8149 --date 2025-01-01 --currency USD
$DIT tx buy --account "USD Margin" --ticker IAU --shares 472 --price 42.9391 --date 2025-01-01 --currency USD
$DIT tx buy --account "USD Margin" --ticker TSLA --shares 10 --price 427.999 --date 2025-01-01 --currency USD
$DIT tx deposit --account "USD Margin" --amount 0.85 --date 2026-04-01 --currency USD

# --- USD RRSP ---
$DIT tx deposit --account "USD RRSP" --amount 733.35 --date 2025-01-01 --currency USD
$DIT tx buy --account "USD RRSP" --ticker IAU --shares 100 --price 62.6405 --date 2025-01-01 --currency USD
$DIT tx buy --account "USD RRSP" --ticker PLTR --shares 50 --price 93.9248 --date 2025-01-01 --currency USD
$DIT tx buy --account "USD RRSP" --ticker TSM --shares 20 --price 302.999 --date 2025-01-01 --currency USD
$DIT tx deposit --account "USD RRSP" --amount 27.41 --date 2026-04-20 --currency USD

# --- CAD RRSP ---
$DIT tx deposit --account "CAD RRSP" --amount 36868.96 --date 2025-01-01 --currency CAD
$DIT tx buy --account "CAD RRSP" --ticker NVDA.NE --shares 500 --price 42.5179 --date 2025-01-01 --currency CAD
$DIT tx buy --account "CAD RRSP" --ticker TSLA.NE --shares 400 --price 39.2299 --date 2025-01-01 --currency CAD
$DIT tx buy --account "CAD RRSP" --ticker PHYS.TO --shares 100 --price 34.5699 --date 2025-01-01 --currency CAD
$DIT tx buy --account "CAD RRSP" --ticker MSFT.TO --shares 100 --price 30.5799 --date 2025-01-01 --currency CAD
$DIT tx buy --account "CAD RRSP" --ticker RBLX --shares 35 --price 63.9 --date 2025-01-01 --currency USD
$DIT tx buy --account "CAD RRSP" --ticker MSFT.TO --shares 100 --price 26.4999 --date 2026-04-10 --currency CAD
$DIT tx withdraw --account "CAD RRSP" --amount 2649.99 --date 2026-04-10 --currency CAD
$DIT tx deposit --account "CAD RRSP" --amount 7.52 --date 2026-04-20 --currency CAD
$DIT tx buy --account "CAD RRSP" --ticker VRT --shares 5 --price 322.04 --date 2026-04-27 --currency USD
$DIT tx withdraw --account "CAD RRSP" --amount 2200.82136 --date 2026-04-27 --currency CAD
$DIT tx withdraw --account "CAD RRSP" --amount 38.45 --date 2026-04-27 --currency CAD
$DIT tx buy --account "CAD RRSP" --ticker TSLA.NE --shares 200 --price 30.61 --date 2026-09-03 --currency CAD
$DIT tx withdraw --account "CAD RRSP" --amount 8471.0114 --date 2026-09-03 --currency CAD

# --- CAD Business Cash ---
$DIT tx deposit --account "CAD Business Cash" --amount 236.91 --date 2025-01-01 --currency CAD
$DIT tx buy --account "CAD Business Cash" --ticker TSM --shares 15 --price 215.6036 --date 2025-01-01 --currency USD
$DIT tx buy --account "CAD Business Cash" --ticker TSLA --shares 35 --price 180.22 --date 2025-01-01 --currency USD
$DIT tx buy --account "CAD Business Cash" --ticker NVDA.NE --shares 400 --price 39.815 --date 2025-01-01 --currency CAD
$DIT tx buy --account "CAD Business Cash" --ticker TSLA.NE --shares 200 --price 32.0174 --date 2025-01-01 --currency CAD
$DIT tx buy --account "CAD Business Cash" --ticker GOOG.NE --shares 45 --price 51.422 --date 2025-01-01 --currency CAD
$DIT tx deposit --account "CAD Business Cash" --amount 20000 --date 2026-04-17 --currency CAD
# duplicate in source (position id 8) — kept faithfully; comment out if it was a data bug
$DIT tx deposit --account "CAD Business Cash" --amount 20000 --date 2026-04-17 --currency CAD
$DIT tx deposit --account "CAD Business Cash" --amount 859.4 --date 2026-04-20 --currency CAD
$DIT tx buy --account "CAD Business Cash" --ticker TSLA.NE --shares 100 --price 31.14 --date 2026-09-23 --currency CAD
$DIT tx withdraw --account "CAD Business Cash" --amount 3123.99 --date 2026-09-23 --currency CAD

# --- CAD RESP ---
$DIT tx deposit --account "CAD RESP" --amount 11.57 --date 2025-01-01 --currency CAD
# maturity 2026-12-31 read from the product name 'GIC 4.45 Dec26'; rate = source yield_rate (0.0445)
$DIT tx gic --account "CAD RESP" --product "GIC 4.45 Dec26" --principal 5000 --rate 4.45 --maturity 2026-12-31 --currency CAD
# tx gic has no --date flag (it records the run date); align it to the source date:
# (filter by kind so the row is findable, then take the 8-hex ID field
#  after the grid's left wall — shape-checked, format-proof)
GIC_ID=$($DIT tx list --account "CAD RESP" --kind gicPurchase --limit 20 2>/dev/null | awk '$1=="│" && length($2)==8 && $2 !~ /[^0-9A-F]/ {print $2; exit}')
[ -n "$GIC_ID" ] && dit tx edit "$GIC_ID" --date 2025-01-01
$DIT tx buy --account "CAD RESP" --ticker MSFT.TO --shares 75 --price 29.9632 --date 2025-01-01 --currency CAD
$DIT tx buy --account "CAD RESP" --ticker GOOG.NE --shares 100 --price 34.0788 --date 2025-01-01 --currency CAD
$DIT tx buy --account "CAD RESP" --ticker TSLA.NE --shares 100 --price 22.0762 --date 2025-01-01 --currency CAD
$DIT tx buy --account "CAD RESP" --ticker PHYS.TO --shares 50 --price 32.6198 --date 2025-01-01 --currency CAD
$DIT tx buy --account "CAD RESP" --ticker NVDA.NE --shares 110 --price 36.0553 --date 2025-01-01 --currency CAD
$DIT tx deposit --account "CAD RESP" --amount 43.11 --date 2026-04-20 --currency CAD

# --- HSBC ---
$DIT tx buy --account "HSBC" --ticker AAPL --shares 840 --price 153.65 --date 2025-01-01 --currency USD
$DIT tx buy --account "HSBC" --ticker MSFT --shares 60 --price 301.15 --date 2025-01-01 --currency USD
$DIT tx buy --account "HSBC" --ticker GOOG --shares 100 --price 144.22 --date 2025-01-01 --currency USD

# --- CAD Margin ---
$DIT tx deposit --account "CAD Margin" --amount 67.74 --date 2025-01-01 --currency CAD
$DIT tx buy --account "CAD Margin" --ticker NVDA --shares 20 --price 109.7967 --date 2025-01-01 --currency USD
$DIT tx buy --account "CAD Margin" --ticker GOOG.NE --shares 300 --price 28.4 --date 2025-01-01 --currency CAD
$DIT tx deposit --account "CAD Margin" --amount 17.74 --date 2026-04-20 --currency CAD

# --- USD Business Cash ---
$DIT tx deposit --account "USD Business Cash" --amount 918.03 --date 2025-01-01 --currency USD
$DIT tx buy --account "USD Business Cash" --ticker IAU --shares 400 --price 63.5311 --date 2025-01-01 --currency USD
$DIT tx buy --account "USD Business Cash" --ticker EWT --shares 100 --price 45.4569 --date 2025-01-01 --currency USD
$DIT tx buy --account "USD Business Cash" --ticker TSLA --shares 30 --price 349.0195 --date 2025-01-01 --currency USD
$DIT tx buy --account "USD Business Cash" --ticker NVDA --shares 50 --price 137.029 --date 2025-01-01 --currency USD
$DIT tx buy --account "USD Business Cash" --ticker TEM --shares 100 --price 58.34 --date 2025-01-01 --currency USD
$DIT tx buy --account "USD Business Cash" --ticker TSM --shares 70 --price 152.6397 --date 2025-01-01 --currency USD
$DIT tx buy --account "USD Business Cash" --ticker EWJ --shares 100 --price 71.8178 --date 2025-01-01 --currency USD
$DIT tx deposit --account "USD Business Cash" --amount 96.34 --date 2026-04-20 --currency USD

# --- verify ---
echo "== accounts =="
$DIT accounts
echo "== summary (offline; positions at cost) =="
$DIT --offline summary

