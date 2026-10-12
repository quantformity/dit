// Package decimal provides exact base-10 decimal arithmetic for money and
// prices, replacing the Foundation Decimal used by the Swift implementation.
//
// Values are held as an arbitrary-precision integer times a power of ten, so
// addition, subtraction and multiplication are exact and never touch a binary
// float. That mirrors the Swift project's rule that money is decimal, never
// Double.
//
// One deliberate difference from Foundation Decimal: division is computed to a
// caller-chosen number of decimal places, rounding half away from zero
// (Foundation's `.plain` mode). The Swift code rounds at the same places it
// stores or displays a value, so the two agree wherever Foundation's own
// 39-significant-digit limit is not binding.
package decimal

import (
	"fmt"
	"math/big"
	"strings"
)

// Decimal is an immutable exact decimal number. The zero value is zero.
//
// The value is unscaled × 10^-scale, kept canonical (no trailing zeros), so
// equal numbers compare, print and hash identically however they were built.
type Decimal struct {
	unscaled *big.Int // nil means zero
	scale    int32
}

// Zero is the additive identity.
var Zero = Decimal{}

var ten = big.NewInt(10)

func pow10(n int32) *big.Int {
	if n <= 0 {
		return big.NewInt(1)
	}
	return new(big.Int).Exp(ten, big.NewInt(int64(n)), nil)
}

// normalize makes the representation canonical and returns it.
func normalize(unscaled *big.Int, scale int32) Decimal {
	if unscaled == nil || unscaled.Sign() == 0 {
		return Zero
	}
	value := new(big.Int).Set(unscaled)
	for scale > 0 && value.Sign() != 0 {
		if new(big.Int).Mod(value, ten).Sign() != 0 {
			break
		}
		value.Quo(value, ten)
		scale--
	}
	for scale < 0 {
		value.Mul(value, ten)
		scale++
	}
	return Decimal{unscaled: value, scale: scale}
}

// FromInt builds an exact integer decimal.
func FromInt(v int64) Decimal {
	if v == 0 {
		return Zero
	}
	return normalize(big.NewInt(v), 0)
}

// Parse reads a decimal literal such as "-3.25" or "1.5e3". It is the entry
// point for values that arrive as text: CLI arguments, CSV columns, JSON.
func Parse(text string) (Decimal, error) {
	trimmed := strings.TrimSpace(text)
	if trimmed == "" {
		return Zero, fmt.Errorf("empty decimal")
	}
	body, exponent := trimmed, int32(0)
	if i := strings.IndexAny(trimmed, "eE"); i >= 0 {
		e, err := parseExponent(trimmed[i+1:])
		if err != nil {
			return Zero, fmt.Errorf("bad exponent in %q", text)
		}
		exponent = e
		body = trimmed[:i]
	}
	scale := int32(0)
	if dot := strings.IndexByte(body, '.'); dot >= 0 {
		scale = int32(len(body) - dot - 1)
		body = body[:dot] + body[dot+1:]
	}
	if body == "" {
		return Zero, fmt.Errorf("not a decimal: %q", text)
	}
	value, ok := new(big.Int).SetString(body, 10)
	if !ok {
		return Zero, fmt.Errorf("not a decimal: %q", text)
	}
	return normalize(value, scale-exponent), nil
}

// MustParse is Parse for literals known to be valid; it panics otherwise.
func MustParse(text string) Decimal {
	d, err := Parse(text)
	if err != nil {
		panic(err)
	}
	return d
}

func parseExponent(text string) (int32, error) {
	body := strings.TrimSpace(text)
	if body == "" {
		return 0, fmt.Errorf("empty exponent")
	}
	negative := false
	if body[0] == '+' || body[0] == '-' {
		negative = body[0] == '-'
		body = body[1:]
	}
	var value int64
	for _, r := range body {
		if r < '0' || r > '9' {
			return 0, fmt.Errorf("bad exponent digit %q", r)
		}
		value = value*10 + int64(r-'0')
		if value > 1_000_000 {
			return 0, fmt.Errorf("exponent out of range")
		}
	}
	if negative {
		return -int32(value), nil
	}
	return int32(value), nil
}

func (d Decimal) big() *big.Int {
	if d.unscaled == nil {
		return new(big.Int)
	}
	return new(big.Int).Set(d.unscaled)
}

// align rewrites both operands at the larger scale.
func align(a, b Decimal) (*big.Int, *big.Int, int32) {
	scale := a.scale
	if b.scale > scale {
		scale = b.scale
	}
	x := a.big()
	if a.scale < scale {
		x.Mul(x, pow10(scale-a.scale))
	}
	y := b.big()
	if b.scale < scale {
		y.Mul(y, pow10(scale-b.scale))
	}
	return x, y, scale
}

// IsZero reports exact zero.
func (d Decimal) IsZero() bool { return d.big().Sign() == 0 }

// Sign returns -1, 0 or 1.
func (d Decimal) Sign() int { return d.big().Sign() }

// Neg returns -d.
func (d Decimal) Neg() Decimal { return normalize(d.big().Neg(d.big()), d.scale) }

// Abs returns |d|.
func (d Decimal) Abs() Decimal {
	if d.Sign() < 0 {
		return d.Neg()
	}
	return d
}

// Add returns d + o exactly.
func (d Decimal) Add(o Decimal) Decimal {
	x, y, scale := align(d, o)
	return normalize(x.Add(x, y), scale)
}

// Sub returns d - o exactly.
func (d Decimal) Sub(o Decimal) Decimal { return d.Add(o.Neg()) }

// Mul returns d × o exactly, carrying the sum of both scales like Foundation
// Decimal does, so a shares × price product keeps every digit until
// something rounds it.
func (d Decimal) Mul(o Decimal) Decimal {
	if d.IsZero() || o.IsZero() {
		return Zero
	}
	return normalize(d.big().Mul(d.big(), o.big()), d.scale+o.scale)
}

// Div returns d ÷ o rounded to scale decimal places, half away from zero.
//
// The quotient is formed as an exact rational first, so the only approximation
// is the final rounding at `scale`. Dividing by zero yields zero: an
// unavailable rate means "no conversion", and no caller of this wants a panic
// in a portfolio report.
func (d Decimal) Div(o Decimal, scale int32) Decimal {
	if o.IsZero() {
		return Zero
	}
	// d/o as an exact rational, then scaled by 10^scale and rounded once.
	numer := new(big.Rat).SetFrac(d.big(), pow10(d.scale))
	denom := new(big.Rat).SetFrac(o.big(), pow10(o.scale))
	quotient := new(big.Rat).Quo(numer, denom)
	scaled := new(big.Rat).Mul(quotient, new(big.Rat).SetFrac(pow10(scale), big.NewInt(1)))
	return normalize(roundHalfAway(scaled), scale)
}

// roundHalfAway rounds a rational to the nearest integer, ties away from
// zero, and returns the result as an unscaled integer.
func roundHalfAway(r *big.Rat) *big.Int {
	num := new(big.Int).Set(r.Num())
	den := new(big.Int).Set(r.Denom())
	sign := num.Sign()
	if sign == 0 {
		return big.NewInt(0)
	}
	absNum := new(big.Int).Abs(num)
	absDen := new(big.Int).Abs(den)
	quotient := new(big.Int).Quo(absNum, absDen)
	remainder := new(big.Int).Mod(absNum, absDen)
	if new(big.Int).Lsh(remainder, 1).Cmp(absDen) >= 0 {
		quotient.Add(quotient, big.NewInt(1))
	}
	if sign < 0 {
		quotient.Neg(quotient)
	}
	return quotient
}

// Round rounds half away from zero to scale decimal places, the equivalent of
// NSDecimalNumberHandler(roundingMode: .plain, scale:).
func (d Decimal) Round(scale int32) Decimal {
	if d.IsZero() || scale >= d.scale {
		return d
	}
	return d.Div(FromInt(1), scale)
}

// Cmp orders two decimals: -1, 0 or 1.
func (d Decimal) Cmp(o Decimal) int {
	x, y, _ := align(d, o)
	return x.Cmp(y)
}

// Equal reports exact numeric equality, ignoring scale.
func (d Decimal) Equal(o Decimal) bool { return d.Cmp(o) == 0 }

// String renders the value with the fewest digits that are exactly correct.
func (d Decimal) String() string {
	if d.IsZero() {
		return "0"
	}
	text := new(big.Int).Abs(d.unscaled).String()
	if d.scale > 0 {
		for len(text) <= int(d.scale) {
			text = "0" + text
		}
		cut := len(text) - int(d.scale)
		text = text[:cut] + "." + text[cut:]
	}
	if d.unscaled.Sign() < 0 {
		return "-" + text
	}
	return text
}

// Fixed renders the value with exactly scale decimal places, rounding the
// same way the store does. This is what table and JSON output use for money
// (scale 2) and prices or rates (scale 4).
func (d Decimal) Fixed(scale int32) string {
	if scale < 0 {
		scale = 0
	}
	value := d
	if value.scale > scale {
		value = value.Round(scale)
	}
	negative := value.Sign() < 0
	digits := new(big.Int).Abs(value.big())
	if scale > 0 {
		digits.Mul(digits, pow10(scale-value.scale))
	}
	text := digits.String()
	// One digit more than the fraction so "0.5" never renders as ".5000".
	if pad := int(scale) + 1 - len(text); pad > 0 {
		text = strings.Repeat("0", pad) + text
	}
	if scale > 0 {
		cut := len(text) - int(scale)
		text = text[:cut] + "." + text[cut:]
	}
	if negative {
		return "-" + text
	}
	return text
}

// MarshalJSON writes the number unquoted, which is how the Swift store keeps
// money: a JSON number, not a string.
func (d Decimal) MarshalJSON() ([]byte, error) { return []byte(d.String()), nil }

// UnmarshalJSON accepts a bare JSON number or a quoted decimal string.
func (d *Decimal) UnmarshalJSON(data []byte) error {
	text := strings.Trim(strings.TrimSpace(string(data)), `"`)
	parsed, err := Parse(text)
	if err != nil {
		return err
	}
	*d = parsed
	return nil
}
