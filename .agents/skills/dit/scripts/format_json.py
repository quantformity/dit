#!/usr/bin/env python3
"""Format one `dit --json` document into a compact briefing block.

Reads a single JSON document on stdin, prints Markdown-ish lines on stdout.
Unknown schemas print a short raw excerpt instead of a fabricated summary.

Honesty rules it enforces: a null is shown as an em dash (never 0), and a
non-null `via` / `basis: "derived"` is labelled as a model, not a quote.
"""
import json
import sys

DASH = "\u2014"  # a dash means "unknown", and must never read as zero


def n(value):
    """Print a value, or a dash when there is no information."""
    return DASH if value is None or value == "" else str(value)


def pct(value):
    try:
        return "%.2f%%" % (float(value) * 100)
    except (TypeError, ValueError):
        return DASH


def summary(data):
    totals = data.get("totals", {})
    print("- total %s %s (cash %s, positions %s, GIC %s)" % (
        n(data.get("displayCurrency")), n(totals.get("totalValue")),
        n(totals.get("cash")), n(totals.get("positions")), n(totals.get("gic"))))
    print("- unrealized %s / realized %s / day change %s" % (
        n(totals.get("unrealizedPnl")), n(totals.get("realizedPnl")),
        n(totals.get("dayChange"))))
    # A null cross-currency total is a refusal, not a zero: show the native
    # per-currency figures the document still carries.
    by_ccy = data.get("totals", {}).get("byCurrency") or {}
    if totals.get("totalValue") is None and by_ccy:
        for ccy, row in sorted(by_ccy.items()):
            print("  - %s native: total %s (cash %s, positions %s, GIC %s)" % (
                ccy, n(row.get("total")), n(row.get("cash")),
                n(row.get("positions")), n(row.get("gic"))))
    if data.get("offline"):
        print("- _offline: no pricing happened, holdings carry cost-basis figures_")
    if data.get("degraded"):
        print("- _market store unreadable: day data unavailable, never guessed_")

    def sort_key(holding):
        try:
            return -float(holding.get("value") or 0)
        except (TypeError, ValueError):
            return 0

    holdings = sorted(data.get("holdings", []), key=sort_key)[:8]
    if not holdings:
        print("- no holdings recorded")
        return
    print("- top holdings by value:")
    for holding in holdings:
        quote = holding.get("quote") or {}
        derived = bool(quote.get("via"))
        mark = quote.get("source") or "no quote (valued at cost)"
        if derived:
            mark = "DERIVED %s" % quote.get("via")
        print("  - %-9s %s %s sh @ %s = %s | P&L %s (%s) | %s" % (
            n(holding.get("symbol")), n(holding.get("ccy")),
            n(holding.get("shares")), n(holding.get("avgCost")),
            n(holding.get("value")), n(holding.get("pnl")),
            pct(holding.get("pnlPct")), mark))
    for warning in data.get("warnings", [])[:6]:
        print("- WARNING %s" % warning)
    for short in data.get("untrackedShorts", [])[:6]:
        print("- untracked short %s" % short)


def coverage(data):
    window = data.get("window") or {}
    print("- complete: %s (audit %s, window %s to %s)" % (
        n(data.get("complete")), n(data.get("auditDate")),
        n(window.get("from")), n(window.get("to"))))
    findings = [p for p in data.get("prices", []) if p.get("status") != "ok"]
    if not data.get("prices") and not data.get("fx"):
        print("- nothing held in scope to audit (empty store, or filters matched nothing)")
    for row in findings[:8]:
        gap = row.get("longestGap") or {}
        print("- PRICE %-10s %s %-14s last %s, %s pt, stale %s%s" % (
            n(row.get("symbol")), n(row.get("currency")), n(row.get("status")),
            n(row.get("lastClose")), n(row.get("points")), n(row.get("staleDays")),
            ", longest gap %sd" % gap.get("days") if gap else ""))
    if len(findings) > 8:
        print("- ... %d more price findings" % (len(findings) - 8))
    broken_fx = [f for f in data.get("fx", []) if not f.get("usableNow")]
    for row in broken_fx[:8]:
        print("- FX %s/%s would NOT convert (chain: %s)" % (
            n(row.get("from")), n(row.get("to")), n(row.get("chain"))))
    if not findings and not broken_fx and (data.get("prices") or data.get("fx")):
        print("- no findings: every held position has usable history and FX")


def pnl(data):
    window = data.get("window") or {}
    scope = data.get("scope") or {}
    print("- window %s to %s (%s), reporting %s" % (
        n(window.get("start")), n(window.get("end")),
        "from ledger start" if window.get("fromLedgerStart") else "explicit",
        n(scope.get("reportingCurrency"))))
    for row in data.get("currencyTotals", []):
        extra = ""
        if row.get("incompletePositions"):
            extra = " (%d incomplete, dropped from the total)" % row["incompletePositions"]
        print("- %s: realized %s | position delta %s | total %s%s" % (
            n(row.get("currency")), n(row.get("realized")),
            n(row.get("positionChange")), n(row.get("total")), extra))
    combined = data.get("combined")
    if isinstance(combined, dict):
        print("- combined %s %s at %s (%s)" % (
            n(combined.get("currency")), n(combined.get("value")),
            n(combined.get("at")), n(combined.get("rates"))))
    else:
        print("- combined: %s (not combinable = a currency could not convert)" % n(combined))
    for note in data.get("notes", [])[:6]:
        print("- note %s" % note)


def tx_pnl(data):
    booked = data.get("booked", [])
    print("- booked events: %d | policy %s | scope %s" % (
        len(booked), n(data.get("policy")), n(data.get("scope"))))
    for row in booked[:8]:
        print("  - %s %s %s %s: %s%s" % (
            n(row.get("date")), n(row.get("kind")), n(row.get("symbol")),
            n(row.get("currency")), n(row.get("pnl")),
            " (incomplete)" if row.get("incomplete") else ""))
    opens = data.get("open", [])
    derived = [o for o in opens if o.get("markKind") not in ("stored", "live", None)]
    print("- open lots: %d%s" % (len(opens), "; marks by %s" % sorted(
        {str(o.get("markKind")) for o in opens}) if opens else ""))
    if derived:
        print("- _%d open lots marked from a non-observed source: label them if shown_" % len(derived))
    for note in data.get("notes", [])[:4]:
        print("- note %s" % note)


FORMATTERS = {
    "summary/1": summary,
    "coverage/1": coverage,
    "pnl/1": pnl,
    "tx-pnl/1": tx_pnl,
}


def main():
    raw = sys.stdin.read()
    try:
        document = json.loads(raw)
    except ValueError:
        print("_(not JSON): %s_" % raw[:300].replace("\n", " "))
        return 0
    if not document.get("ok"):
        print("_%s error: %s_" % (n(document.get("kind")), n(document.get("error"))))
        return 0
    schema = document.get("schema")
    data = document.get("data") or {}
    formatter = FORMATTERS.get(schema)
    if formatter is None:
        print("_(%s: no formatter, raw excerpt) %s_" % (n(schema), json.dumps(data)[:400]))
        return 0
    formatter(data)
    return 0


if __name__ == "__main__":
    sys.exit(main())
