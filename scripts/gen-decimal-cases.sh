#!/usr/bin/env bash
# Regenerate the arithmetic oracle cases consumed by
# internal/decimal/oracle_test.go.
#
# The expected values are computed with Python's arbitrary-precision rationals
# (fractions.Fraction), NOT with this package's code. That is the point: a
# money bug is one cent on one instrument on one day, and a self-consistent
# implementation cannot detect its own wrong rounding rule.
#
# Rounding model: scale to N places, half away from zero — Foundation's
# NSDecimalNumberHandler(.plain), which the Swift code uses for every stored
# price and every display figure.
set -eu
OUT="$(dirname "$0")/../testdata/decimal-cases.txt"
python3 - "$OUT" <<'PY'
import random, sys
from fractions import Fraction
random.seed(7)

def round_half_away(fr, scale):
    scaled = fr * 10**scale
    n, d = scaled.numerator, scaled.denominator
    sign = -1 if n < 0 else 1
    an = abs(n)
    q, r = divmod(an, d)
    if 2 * r >= d:
        q += 1
    return sign * q

def pad(fr, scale):
    n = round_half_away(fr, scale)
    neg = n < 0
    text = str(abs(n)).rjust(scale + 1, "0")
    out = text[:-scale] + "." + text[-scale:] if scale else text
    return ("-" + out) if neg else out

def minimal(fr):
    if fr == 0:
        return "0"
    neg = fr < 0
    fr = abs(fr)
    scale, x = 0, fr
    while x != int(x) and scale < 40:
        x *= 10
        scale += 1
    text = str(int(x))
    if scale:
        text = text.rjust(scale + 1, "0")
        out = text[:-scale] + "." + text[-scale:]
    else:
        out = text
    return ("-" + out) if neg else out

def rnd_val():
    r = random.random()
    if r < .3:
        return str(random.randint(0, 2_000_000))
    if r < .6:
        return str(round(random.uniform(-5000, 5000), random.randint(1, 6)))
    if r < .85:
        return str(round(random.uniform(0.0001, 9.99), 4))
    return str(round(random.uniform(0.001, 2.5), 6))

lines = []
for _ in range(1500):
    a, b = rnd_val(), rnd_val()
    fa, fb = Fraction(a), Fraction(b)
    if fb != 0:
        lines.append(f"add|{a}|{b}|0|{minimal(fa + fb)}")
        lines.append(f"sub|{a}|{b}|0|{minimal(fa - fb)}")
        lines.append(f"mul|{a}|{b}|0|{minimal(fa * fb)}")
        lines.append(f"div|{a}|{b}|4|{pad(fa / fb, 4)}")
        lines.append(f"div|{a}|{b}|2|{pad(fa / fb, 2)}")
    lines.append(f"round|{a}||2|{pad(fa, 2)}")
    lines.append(f"round|{a}||4|{pad(fa, 4)}")
    lines.append(f"fixed|{a}||2|{pad(fa, 2)}")
    lines.append(f"fixed|{a}||4|{pad(fa, 4)}")
open(sys.argv[1], "w").write("\n".join(lines) + "\n")
print(f"{len(lines)} cases -> {sys.argv[1]}")
PY
