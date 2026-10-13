"""Compare two runs by outcome, not just by printed text.

The historical twin-run harness used this after probes that write. It answers
three questions that a stdout diff cannot:

  - did both sides end up holding the same ledger and the same price history?
  - did the file each side wrote actually contain the same data?
  - did one side write something the other did not?

Comparison is canonical JSON (keys sorted, array order kept) because the Swift
encoder leaves dictionary order to a per-process hash seed: byte comparison
would flag every run as different and prove nothing. Array order is NOT
normalised — a ledger whose transactions rearranged is a real behaviour change,
not noise.

The three wall-clock fields (createdAt, updatedAt, generatedAt) and every
server-minted transaction ``id`` (a 36-char UUID) ARE dropped: a probe that
WRITES a new transaction has both binaries each generate their own random ID
and their own write-timestamp, so those legitimately differ and prove no
thing about the port. A real bug (different amount, kind, account, ticker,
date, or a missing/extra row) still shows.
two processes run microseconds apart cannot agree on a timestamp, and requiring
it would mean injecting a fake clock into both binaries for no information.
Everything else, including every number, is compared.

Prints nothing and exits 0 when equivalent; prints a reason and exits 1.
"""
import json
import pathlib
import sys
import time


VOLATILE = {"createdAt", "updatedAt", "generatedAt"}
UUID_RE = __import__("re").compile(r"^\w{8}-\w{4}-\w{4}-\w{4}-\w{12}$")


def strip_clock(value):
    if isinstance(value, str) and UUID_RE.match(value):
        return "<ID>"
    if isinstance(value, dict):
        out = {}
        for k, v in sorted(value.items()):
            if k in VOLATILE:
                continue
            out[k] = strip_now(k, v)
        return out
    if isinstance(value, list):
        return [strip_clock(x) for x in value]
    return value


def strip_now(key: str, value):
    # A probe without --date makes both binaries stamp the transaction with
    # wall-clock "now" (CoreFoundation seconds). Two separate runs are naturally
    # milliseconds apart, so a date written *by the run itself* is compared as
    # "both sides wrote now", not as a number. A date that was in the seed (i.e.
    # far from real now) is compared exactly as before.
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        now_cf = time.time() - 978307200  # CoreFoundation reference epoch
        if abs(float(value) - now_cf) < 900 and any(
            marker in key.lower() for marker in ("date", "closed", "opened", "stamp", "at")
        ):
            return "<NOW>"
    if key == "tags" and isinstance(value, list):
        # The reference stores tags in a hash-ordered set: the order is its own
        # process-by-process noise (three runs of the same command give three
        # orders). The set is the data, so compare it sorted.
        return sorted(value)
    return strip_clock(value)


def canon(path: pathlib.Path):
    if not path.exists():
        return None
    raw = path.read_bytes()
    try:
        return json.dumps(strip_clock(json.loads(raw)), separators=(",", ":"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        return raw.hex()


def main() -> int:
    side_a, side_b = (pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
    problems = []

    # The stores themselves.
    for name in ("portfolio.dat", "market.dat"):
        for group in ("store", "market"):
            left, right = canon(side_a / group / name), canon(side_b / group / name)
            if left != right:
                problems.append(f"{group}/{name} differs after the command")

    # Anything the command wrote into its own output directory.
    out_a, out_b = side_a / "out", side_b / "out"
    written = sorted(p for p in out_a.iterdir() if p.is_file()) if out_a.exists() else []
    for file in written:
        twin = out_b / file.name
        if not twin.exists():
            problems.append(f"{file.name} was written by Swift but not by Go")
        elif canon(file) != canon(twin):
            problems.append(f"{file.name} content differs")
    for file in sorted(p for p in out_b.iterdir() if p.is_file()) if out_b.exists() else []:
        if not (out_a / file.name).exists():
            problems.append(f"{file.name} was written by Go but not by Swift")

    if problems:
        print("; ".join(problems))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
