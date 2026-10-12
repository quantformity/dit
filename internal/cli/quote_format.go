package cli

import (
	"strings"

	"dit/internal/decimal"
	"dit/internal/text"
)

// NumberFormatter in the reference uses ties-to-even for displayed prices
// and JSON strings; ledger arithmetic's Round deliberately uses half-away.
// Keep that display choice local, without changing arithmetic or shared text.
func quoteRound(d decimal.Decimal, scale int32) decimal.Decimal {
	rounded := d.Round(scale)
	unit := decimal.FromInt(1)
	if scale > 0 {
		unit = decimal.MustParse("0." + strings.Repeat("0", int(scale)-1) + "1")
	}
	half := unit.Div(decimal.FromInt(2), scale+1)
	if d.Sub(rounded).Abs().Equal(half) {
		fixed := rounded.Fixed(scale)
		if (fixed[len(fixed)-1]-'0')%2 != 0 {
			if d.Sign() < 0 {
				rounded = rounded.Add(unit)
			} else {
				rounded = rounded.Sub(unit)
			}
		}
	}
	return rounded
}
func quoteFixed(d decimal.Decimal, scale int32) string { return quoteRound(d, scale).Fixed(scale) }
func quoteQuantity(d decimal.Decimal) string           { return text.Quantity(quoteRound(d, 4)) }
