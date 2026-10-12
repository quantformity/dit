#!/usr/bin/env bash
# twin-run — the port's fidelity instrument.
#
# A command counts as ported only when it answers identically to the Swift
# original AND leaves the same data behind. Each probe runs one command through
# BOTH binaries, each with its own copy of an identical store, and compares
# stdout, stderr, exit code, the resulting stores, and any files the command
# wrote.
#
# Why a fresh copy per probe: some commands write. Sharing one store — or one
# output directory — lets an earlier command change what a later one sees, and
# the comparison would then measure ordering instead of behaviour.
#
# Why one seed, copied: the Swift tool mints fresh UUIDs per run and leaves
# dictionary key order to a per-process hash seed, so seeding twice produces
# byte-different files holding the same facts. Copying one seed gives both
# binaries literally the same bytes, including data neither of them wrote.
#
# Probe tokens:
#   @SELF@  expands to that side's own output directory, so a probe that writes
#           files does not collide with the other side, and both see one shape.
#   $SRC    a pre-built input file, shared read-only by both sides.
#
# Usage: scripts/twin-run.sh [PROBE ...]      (no args = the default probe set)
# Env:   SWIFT=/path/to/dit  GO=/path/to/ditgo
set -u

SWIFT="${SWIFT:-/opt/homebrew/bin/dit}"
# Absolute, because probes run with cwd inside the scratch directory.
GO="${GO:-$(cd "$(dirname "$0")/.." && pwd)/.build/ditgo}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/dit-twin.XXXXXX)"
SEED="$WORK/seed"

seed_tool() {
  local store="$1" market="$2"
  shift 2
  DIT_BACKEND=file DIT_STORE_URL="$store" DIT_MARKET_URL="$market" "$SWIFT" "$@" >/dev/null 2>&1
}

if [ ! -f "$ROOT/testdata/twin-seed.csv" ]; then
  mkdir -p "$ROOT/testdata"
  printf 'SHOP.TO,2024-06-14,95.10\nSHOP.TO,2024-06-17,96.40\nSHOP.TO,2024-06-18,94.20\nUSD/CAD,2024-06-17,1.3578\n' > "$ROOT/testdata/twin-seed.csv"
fi

mkdir -p "$SEED/store" "$SEED/market"
seed_tool "$SEED/store" "$SEED/market" account add --currency CAD --name "TFSA"
seed_tool "$SEED/store" "$SEED/market" account add --currency USD --name "Margin" --institution Mercury
seed_tool "$SEED/store" "$SEED/market" tx deposit --account TFSA --amount 25000 --date 2024-01-04
seed_tool "$SEED/store" "$SEED/market" tx withdraw --account TFSA --amount 1200.50 --date 2024-02-08
seed_tool "$SEED/store" "$SEED/market" tx buy --account TFSA --ticker SHOP.TO --shares 10 --price 88.25 --date 2024-03-01 --fee 1.99
seed_tool "$SEED/store" "$SEED/market" tx sell --account TFSA --ticker SHOP.TO --shares 4 --price 102.40 --date 2024-06-15 --fee 1.99
seed_tool "$SEED/store" "$SEED/market" tx dividend --account TFSA --ticker SHOP.TO --amount 12.34 --date 2024-07-01
seed_tool "$SEED/store" "$SEED/market" tx gic --account Margin --product "5y GIC" --principal 5000 --rate 4.7 --compounding annual --maturity 2029-01-02
seed_tool "$SEED/store" "$SEED/market" tx gic-redeem --account Margin --gic "5y GIC" --proceeds 5210.75 --date 2024-08-01
seed_tool "$SEED/store" "$SEED/market" tx fx --account Margin --from USD --to CAD --from-amount 1000 --to-amount 1357.80 --date 2024-04-02
seed_tool "$SEED/store" "$SEED/market" market import "$ROOT/testdata/twin-seed.csv"
# Deterministic market-write seed: Swift-generated proxy data and full
# watermarks let both sides exercise incremental history without live Yahoo.
if [ "${MARKETWRITE:-0}" = 1 ]; then
  seed_tool "$SEED/store" "$SEED/market" ticker add PROXY --currency CAD
  seed_tool "$SEED/store" "$SEED/market" tx buy --account TFSA --ticker PROXY --shares 1 --price 9.51 --date 2024-06-14
  seed_tool "$SEED/store" "$SEED/market" tx sell --account TFSA --ticker PROXY --shares 1 --price 9.42 --date 2024-06-18
  printf 'PROXY,2024-06-14,9.51\n' > "$WORK/anchor.csv"
  seed_tool "$SEED/store" "$SEED/market" market import "$WORK/anchor.csv"
  seed_tool "$SEED/store" "$SEED/market" market backfill PROXY --from SHOP.TO --offline
  python3 - "$SEED/market/market.dat" <<'SEEDPY'
import json,sys,datetime
p=sys.argv[1]
d=json.load(open(p))
today=datetime.datetime.now(datetime.timezone.utc).replace(hour=0,minute=0,second=0,microsecond=0)
watermark=int(today.timestamp())-978307200
for ser in d['series'].values(): ser['coveredThrough']=watermark
with open(p,'w') as f: json.dump(d,f)
SEEDPY
fi
seed_tool "$SEED/store" "$SEED/market" account add --currency CAD --name Empty --opened 2024-01-01
seed_tool "$SEED/store" "$SEED/market" ticker add SHOP.TO --name Shopify --currency CAD --tags core,dividend --notes seeded
seed_tool "$SEED/store" "$SEED/market" ticker add UNREF

if [ -z "$(ls -A "$SEED/store" 2>/dev/null)" ]; then
  echo "seeding produced no store: nothing to compare"
  rm -rf "$WORK"; exit 1
fi

# Input files some probes consume.
SRC="$WORK/src"; mkdir -p "$SRC"
seed_tool "$SEED/store" "$SEED/market" store export --to "$SRC/dump.json"
seed_tool "$SEED/store" "$SEED/market" export --to "$SRC/bundle.json"
printf '{"schema":"bundle/1","portfolio":{},"market":{}}\n' > "$SRC/empty-bundle.json"
printf '{"schema":"bundle/1","createdAt":1,"portfolio":{},"market":{"series":{"ZZZ":{"currency":"USD","points":[{"day":802742400,"price":"not-a-number"}],"symbol":"ZZZ"}}}}\n' > "$SRC/bad-bundle.json"
printf 'not json at all\n' > "$SRC/junk.json"
if [ "${MARKETWRITE:-0}" = 1 ]; then
  printf '# observations\n\nSymbol,Date,Price\nPROXY,2024-06-17,9.64\nPROXY,2024-06-17,999\nUSD/CAD,2024-06-19,1.36\nBAD!,2024-01-01,1\nX,2024-13-01,1\nX,2024-01-01,0\nX,2024-01-01,10,observed\nX,2024-02-31,2\n' > "$SRC/market-mixed.csv"
  printf 'SYMBOL,DATE,PRICE\nX,2024-01-01,0\n' > "$SRC/market-invalid.csv"
  printf '\377\n' > "$SRC/market-nonutf.csv"
fi

# Transaction references for probes that edit/delete a specific seeded row.
# Resolved from the Swift-seeded store so both binaries address the same ID.
tx_ref() {
  python3 - "$SEED/store/portfolio.dat" "$1" <<'PY'
import json, sys
p = json.load(open(sys.argv[1]))
print(next(t['id'][:8] for t in p['transactions'] if sys.argv[2] in t['kind']))
PY
}
DEPOSIT_REF=$(tx_ref deposit); BUY_REF=$(tx_ref stockPurchase)
GIC_REF=$(tx_ref gicPurchase); FX_REF=$(tx_ref fxConversion)
REDEEM_REF=$(tx_ref gicRedemption)

if [ "$#" -gt 0 ]; then
  PROBES=("$@")
else
  PROBES=(
    "accounts"
    "accounts --json"
    "account list --json"
    "quote"
    "quote --json"
    "quote shop.to TOB USD/CAD"
    "quote shop.to TOB USD/CAD --json"
    "quote DITNOTAREALSYMBOL987654"
    "quote DITNOTAREALSYMBOL987654 --json"
    "quote SHOP.TO --offline"
    "quote SHOP.TO AAPL --offline --json"
    "quote SHOP.TO --as-of 2024-06-17"
    "quote ROUND --as-of 2024-06-17 --json"
    "quote ROUND --as-of 2024-06-18"
    "quote shop.to TOB USD/CAD --as-of 2024-06-19"
    "quote shop.to TOB USD/CAD --as-of 2024-06-19 --json"
    "quote SHOP.TO --as-of 2024-06-16 --offline"
    "quote TOB --as-of 2024-06-17"
    "quote TOB --as-of 2024-06-17 --json"
    "quote SHOP.TO TOB --from 2024-06-14 --to 2024-06-18"
    "quote SHOP.TO TOB --from 2024-06-14 --to 2024-06-18 --json"
    "quote SHOP.TO --from 2024-06-17 --offline --json"
    "quote SHOP.TO --to 2024-06-17"
    "quote TOB --from 2024-06-17 --to 2024-06-18"
    "quote TOB --from 2024-06-17 --to 2024-06-18 --json"
    "quote SHOP.TO --as-of invalid"
    "quote SHOP.TO --from 2024-06-18 --to 2024-06-17"
    "quote SHOP.TO --as-of 2024-06-17 --from 2024-06-17"
    "quote USD/CAD/HKD/EUR --as-of 2024-06-17 --offline"
    "quote USD/CAD/HKD/EUR --as-of 2024-06-17 --offline --json"
    "quote USD/CAD/HKD/EUR/JPY --as-of 2024-06-17 --offline --json"
    "quote cad/hkd/eur --as-of 2024-06-17 --offline"
    "quote USD/CAD/HKD --offline"
    "quote CHF/GBP/JPY --as-of 2024-06-17 --offline --json"
    "quote USD/CAD/HKD SHOP.TO"
    "quote USD/CAD/HKD --from 2024-06-17"
    "quote USD/CAD/CAD --offline"
    "quote USD/ZZZ/HKD --offline --json"
    "summary"
    "summary --offline"
    "tx list"
    "tx list --kind sell"
    "tx list --ticker SHOP.TO"
    "tx list --limit 3"
    "tx list --since 2024-06-01"
    "tx"
    "market coverage"
    "market coverage --json"
    "market show SHOP.TO"
    "market show --symbol SHOP.TO"
    "market show KO"
    "account list"
    "store path"
    "store export --to @SELF@/dump.json"
    "store export --account TFSA --to @SELF@/scoped.json"
    "store backup --to @SELF@/backup"
    "store import $SRC/dump.json"
    "store import $SRC/junk.json"
    "export --to @SELF@/bundle.json"
    "export --portfolio-only --to @SELF@/half.json"
    "import $SRC/bundle.json"
    "import $SRC/bundle.json --merge"
    "import $SRC/bad-bundle.json"
    "import $SRC/empty-bundle.json"
    "import $SRC/junk.json"
    "pnl"
    "pnl --json"
    "pnl --to 2024-08-01"
    "pnl --to 2024-08-01 --json"
    "pnl --from 2024-06-15 --to 2024-06-18"
    "pnl --from 2024-06-15 --to 2024-06-18 --json"
    "pnl --from 2024-07-01 --to 2024-07-31 --json"
    "pnl --to 2024-08-01 --reporting-ccy USD"
    "pnl --to 2024-08-01 --reporting-ccy USD --json"
    "pnl --account TFSA,TFSA --to 2024-08-01"
    "pnl --account TFSA,Margin --to 2024-08-01 --json"
    "pnl --tickers MISSING --ccy USD --to 2024-08-01 --json"
    "pnl --time-series --to 2024-08-01"
    "pnl --time-series --to 2024-08-01 --json"
    "pnl --time-series --from 2024-06-01 --to 2024-06-30"
    "pnl --time-series --from 2024-06-15 --to 2024-06-18 --json"
    "pnl --time-series --daily --from 2024-06-15 --to 2024-06-18"
    "pnl --offline --to 2024-08-01 --json"
    "pnl --daily --json"
    "pnl --horizon 0d --json"
    "pnl --horizon 5d --json"
    "pnl --horizon 1m --time-series --json"
    "pnl --horizon YTD --json"
    "pnl --horizon 001D --json"
    "pnl --daily"
    "pnl --horizon 1y --from 2024-01-01 --json"
    "pnl --from 2024-07-31 --to 2024-07-01 --json"
    "pnl --from 2024-02-30 --json"
    "pnl --account MISSING --json"
    "pnl --ccy XYZ --json"
    "pnl --granularity monthly --json"
    "pnl extra --json"
    "tx deposit --account TFSA --amount 123.45 --date 2024-01-01"
    "tx withdraw --account TFSA --amount 99999 --date 2024-01-01"
    "tx buy --account TFSA --ticker ABC --shares 2.5 --price 10 --fee 1 --date 2024-01-01"
    "tx buy --account TFSA --ticker SHOP.TO --shares 1000 --price 100 --date 2024-01-01"
    "tx sell --account TFSA --ticker SHOP.TO --shares 100 --price 5 --date 2024-01-01"
    "tx sell --account TFSA --ticker XYZ --shares 2 --price 5 --date 2024-01-01"
    "tx dividend --account TFSA --ticker ABC --amount 2 --date 2024-01-01"
    "tx gic --account TFSA --product Bond --principal 100 --rate 4.1 --maturity 2028-01-01 --compounding semi-annual --redeemable"
    "tx gic-redeem --account Margin --gic @GIC@ --proceeds 5100 --date 2024-08-01"
    "tx gic-redeem --account Margin --gic @GIC@ --proceeds 4000 --date 2024-08-01"
    "tx fx --account TFSA --from CAD --to USD --from-amount 100 --to-amount 70 --fee 1 --date 2024-01-01"
    "tx edit @DEPOSIT@ --amount 30000"
    "tx edit @BUY@ --shares 20 --price 90 --fee 0 --date 2024-03-02"
    "tx edit @GIC@ --principal 6000 --rate 5 --compounding monthly --maturity 2030-01-01 --product NewBond"
    "tx edit @FX@ --from-amount 2000 --to-amount 2800"
    "tx edit @REDEEM@ --proceeds 5500"
    "tx delete @DEPOSIT@ --yes"
    "tx delete @BUY@ --yes"
    "tx delete @GIC@ --yes"
    "tx delete @FX@ --yes"
    "tx delete @DEPOSIT@"
    "tx edit @DEPOSIT@ --shares 1"
    "tx edit @DEPOSIT@ --amount 25000"
    "tx edit @BUY@ --shares 0"
    "tx edit @GIC@ --principal -1"
    "tx edit @REDEEM@ --proceeds -1"
    "tx edit @FX@ --to-amount 0"
    "tx deposit --account Missing --amount 1"
    "tx deposit --account TFS --amount 1"
    "tx deposit --account TFSA --amount bad"
    "tx deposit --account TFSA --amount 0"
    "tx deposit --account TFSA --amount 1 --fee -1"
    "tx deposit --account TFSA --amount 1 --date 2024-02-30"
    "tx deposit --account TFSA --amount 1 --date 2099-01-01"
    "tx deposit --account TFSA --amount 1 --currency bad"
    "tx deposit --account TFSA --amount 1 --unknown 2"
    "tx buy --account TFSA --ticker X --shares 0 --price 1"
    "tx buy --account TFSA --ticker X --shares 1 --price -1"
    "tx buy --account TFSA --ticker X --shares 1 --offline"
    "tx dividend --account TFSA --ticker X --amount 0"
    "tx gic --account TFSA --product Bond --principal 100 --rate 1001 --maturity 2028-01-01"
    "tx gic --account TFSA --product Bond --principal 100 --rate 4 --maturity 2028-01-01 --date 2024-01-01"
    "tx gic-redeem --account TFSA --gic absent --proceeds 1"
    "tx fx --account TFSA --from CAD --to CAD --from-amount 1 --to-amount 1"
    "tx fx --account TFSA --from CAD --to USD --from-amount 0 --to-amount 1"
    "tx fx --account TFSA --from CAD --to USD --from-amount 1"
    "account add --currency CAD --name New"
    "account add --currency CAD"
    "account add --currency GBp --name New --non-taxable --institution Bank --notes note --number 123 --opened 2024-01-01"
    "account add --currency CAD --name TFSA"
    "account add --currency XXX"
    "account add --currency CAD --taxable --non-taxable"
    "account add --currency CAD --opened bad"
    "account add --currency CAD --opened 2025-01-01 --closed 2024-01-01 --name New"
    "account add --currency CAD --no-taxable"
    "account add --currency CAD --note nope"
    "account add stray --currency CAD"
    "account add"
    "account edit TFSA --institution Bank --number 123 --notes changed"
    "account edit TFSA --currency USD"
    "account edit TFSA --name Margin"
    "account edit TFSA --non-taxable --opened 2024-01-01 --closed 2025-01-01"
    "account edit TFSA --opened 2025-01-01 --closed 2024-01-01"
    "account edit TFSA --opened 2024-02-30"
    "account edit TFSA --taxable=false"
    "account edit TFSA --name TFSA"
    "account edit TFSA"
    "account edit Missing --name New"
    "account edit"
    "account close TFSA --date 2025-01-01"
    "account close TFSA"
    "account close Empty --date 2023-01-01"
    "account close TFSA --date bad"
    "account close TFSA --force"
    "account close"
    "account delete TFSA --yes"
    "account delete TFSA --force"
    "account delete TFSA --force --yes"
    "account delete Empty"
    "account delete Empty --yes"
    "account delete"
    "account show TFSA"
    "account show TFSA --history"
    "account show TFSA --history --json"
    "account show Margin"
    "account show Margin --json"
    "account show Empty --history"
    "account show Missing"
    "account show"
    "ticker list"
    "ticker"
    "ticker show shop.to"
    "ticker show Missing"
    "ticker show"
    "ticker add NEW --currency USD --name New --tags core,dividend --notes note"
    "ticker add NEW"
    "ticker add SHOP.TO"
    "ticker add NEW --currency XXX"
    "ticker add NEW --source yahoo"
    "ticker add"
    "ticker edit shop.to --name Shop --currency USD --tags growth --notes note"
    "ticker edit shop.to --tags="
    "ticker edit shop.to --tags core,dividend"
    "ticker edit shop.to"
    "ticker edit MISSING --name Missing"
    "ticker edit"
    "ticker delete SHOP.TO"
    "ticker delete SHOP.TO --yes"
    "ticker delete UNREF"
    "ticker delete MISSING --yes"
    "ticker delete"
  )
fi

if [ "${MARKETWRITE:-}" = 1 ] && [ "$#" -eq 0 ]; then
  PROBES+=(
    "market history"
    "market history --all --rebuild"
    "market history --from 2024-01-01"
    "market history --offline"
    "market latest --offline"
    "update --offline"
    "update stray"
    "market backfill PROXY --from SHOP.TO --offline"
    "market backfill PROXY --from SHOP.TO --ratio 11 --offline"
    "market backfill PROXY --from SHOP.TO --ratio 11 --dry-run --offline"
    "market backfill PROXY --from PROXY --offline"
    "market backfill UNKNOWN --from SHOP.TO --offline"
    "market backfill PROXY --from UNKNOWN --offline"
    "market backfill PROXY --from SHOP.TO --ratio 0 --offline"
    "market import $SRC/market-mixed.csv"
    "market import $SRC/market-mixed.csv --dry-run"
    "market import $SRC/market-invalid.csv"
    "market import $SRC/market-nonutf.csv"
    "market import $SRC/absent.csv"
    "market import"
  )
fi

PASS=0; FAIL=0
for probe in "${PROBES[@]}"; do
  PA="$WORK/a"; PB="$WORK/b"
  rm -rf "$PA" "$PB"; mkdir -p "$PA/out" "$PB/out"
  cp -R "$SEED/store" "$PA/store"; cp -R "$SEED/market" "$PA/market"
  cp -R "$SEED/store" "$PB/store"; cp -R "$SEED/market" "$PB/market"

  # @SELF@ is per-side on purpose: both binaries must be able to succeed at the
  # same write, or the probe only proves that both can fail.
  probeA=${probe//@SELF@/"$PA/out"}
  probeB=${probe//@SELF@/"$PB/out"}
  # Shared seed refs: the same transaction IDs on both sides.
  probeA=${probe//@DEPOSIT@/$DEPOSIT_REF}; probeA=${probe//@BUY@/$BUY_REF}; probeA=${probe//@GIC@/$GIC_REF}; probeA=${probe//@FX@/$FX_REF}; probeA=${probe//@REDEEM@/$REDEEM_REF}
  probeB=${probe//@DEPOSIT@/$DEPOSIT_REF}; probeB=${probe//@BUY@/$BUY_REF}; probeB=${probe//@GIC@/$GIC_REF}; probeB=${probe//@FX@/$FX_REF}; probeB=${probe//@REDEEM@/$REDEEM_REF}

  if [ "${PTY:-0}" = 1 ]; then
    # Under a pty the reference DOES bold its table headers; run both sides
    # through the same terminal wrapper (scripts/pty-run.py) so the escape
    # bytes themselves are part of the comparison, not just the glyphs.
    outA=$(cd "$WORK" && env TERM=xterm DIT_BACKEND=file DIT_STORE_URL="$PA/store" DIT_MARKET_URL="$PA/market" python3 "$ROOT/scripts/pty-run.py" "$SWIFT" $probeA 2>&1); codeA=$?
    outB=$(cd "$WORK" && env TERM=xterm DIT_STORE_URL="$PB/store" DIT_MARKET_URL="$PB/market" DIT_BACKEND=file python3 "$ROOT/scripts/pty-run.py" "$GO" $probeB 2>&1); codeB=$?
  else
    outA=$(cd "$WORK" && DIT_BACKEND=file DIT_STORE_URL="$PA/store" DIT_MARKET_URL="$PA/market" "$SWIFT" $probeA 2>&1); codeA=$?
    outB=$(cd "$WORK" && DIT_BACKEND=file DIT_STORE_URL="$PB/store" DIT_MARKET_URL="$PB/market" "$GO" $probeB 2>&1); codeB=$?
  fi

  # Paths differ by construction (different directories, and macOS resolves the
  # /tmp symlink while Go prints it literally). Normalising the directory keeps
  # this a test of the report rather than of temp-file naming. In PTY mode the
  # pty's ONLCR puts a \r before every line break; that is terminal plumbing,
  # not program output, and it would break the line-anchored UUID rule below.
  normA=$(printf '%s' "$outA" | tr -d '\r' | sed -e "s|/private$WORK|$WORK|g" -e "s|$PA|<SIDE>|g")
  normB=$(printf '%s' "$outB" | tr -d '\r' | sed -e "s|/private$WORK|$WORK|g" -e "s|$PB|<SIDE>|g")

  # A successful unnamed account-add prints a random auto-name (the first four
  # hex characters of a fresh UUID) plus the full ID. Both sides are random by
  # construction; the port is proven by the shape, not the digits.
  if [[ "$probe" == "account add "* ]] && [ "$codeA" -eq 0 ] && [ "$codeB" -eq 0 ]; then
    normA=$(printf '%s' "$normA" | sed -E "s/^id: [0-9A-Fa-f-]{36}$/id: <UUID>/; s/Account [0-9A-Fa-f]{4}([^0-9A-Za-z]|$)/Account <PREFIX>\1/g")
    normB=$(printf '%s' "$normB" | sed -E "s/^id: [0-9A-Fa-f-]{36}$/id: <UUID>/; s/Account [0-9A-Fa-f]{4}([^0-9A-Za-z]|$)/Account <PREFIX>\1/g")
  fi

  # For commands that write, the RESULT is compared too: an identical message
  # printed over a different store, or over a file the other side could not
  # write, is a failure and not a pass.
  resultDiff="identical"
  case "$probe" in
    "tx "*|*import*|*@SELF@*|"account "*|"ticker "*|"market "*|"update "*|"quote "*)
      if ! resultDiff=$(python3 "$ROOT/scripts/compare-results.py" "$PA" "$PB" 2>&1); then
        resultDiff="RESULT DIFFERS: ${resultDiff:-see compare-results.py}"
      else
        resultDiff="identical"
      fi ;;
  esac

  if [ "$normA" = "$normB" ] && [ "$codeA" = "$codeB" ] && [ "$resultDiff" = "identical" ]; then
    printf 'ok    — dit %s\n' "$probe"
    PASS=$((PASS + 1))
  else
    printf 'DIFF  — dit %s (exit %s vs %s)\n' "$probe" "$codeA" "$codeB"
    [ "$resultDiff" = "identical" ] || printf '  %s\n' "$resultDiff"
    diff <(printf '%s\n' "$normA") <(printf '%s\n' "$normB") | head -12
    FAIL=$((FAIL + 1))
  fi
done

echo
echo "twin-run: $PASS identical, $FAIL differing"
[ -n "${KEEP_WORK:-}" ] || rm -rf "$WORK"
[ "$FAIL" -eq 0 ]