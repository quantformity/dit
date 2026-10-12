// Package model holds the persisted data shapes: the portfolio document, the
// market document, and the wire format shared with the Swift implementation.
//
// The JSON shapes are copied from the Swift encoders rather than invented,
// because both binaries read and write the same store files. Where Swift is
// lenient on purpose (a stale market cache should refill, not brick the CLI)
// this package stays lenient; where Swift is strict (a bundle import must not
// quietly drop rows) the strictness is reproduced too.
package model

// Currency is an ISO 4217 alphabetic code.
//
// The known list is deliberately short — it is the set of currencies a
// personal portfolio realistically holds, not Yahoo's 154-code catalog, which
// changes over time. Anything unrecognised decodes to Unknown rather than
// failing, so a foreign code in imported data cannot break a store.
type Currency string

const (
	CAD Currency = "CAD"
	USD Currency = "USD"
	GBP Currency = "GBP"
	EUR Currency = "EUR"
	JPY Currency = "JPY"
	CHF Currency = "CHF"
	AUD Currency = "AUD"
	NZD Currency = "NZD"
	CNY Currency = "CNY"
	HKD Currency = "HKD"

	// Unknown is the fallback for any code not listed above. It encodes as
	// the empty string, which is how the Swift side stores it.
	Unknown Currency = ""
)

// knownCurrencies is the curated list, excluding Unknown.
var knownCurrencies = []Currency{CAD, USD, GBP, EUR, JPY, CHF, AUD, NZD, CNY, HKD}

// ConversionHub is the currency other pairs are quoted against. Yahoo quotes
// most pairs against USD, so multi-hop conversions route through it.
const ConversionHub = USD

// KnownCurrencies returns the curated currencies, sorted by code.
func KnownCurrencies() []Currency { return append([]Currency(nil), knownCurrencies...) }

// IsKnown reports whether the code is one of the curated currencies.
func (c Currency) IsKnown() bool {
	for _, known := range knownCurrencies {
		if c == known {
			return true
		}
	}
	return false
}

// String renders the code; Unknown renders as an em dash for display, which
// is what the Swift tables print for "currency unknown".
func (c Currency) String() string {
	if c == Unknown {
		return "—"
	}
	return string(c)
}

// Code renders the raw code, empty for Unknown (used inside identifiers such
// as FX pair keys, where an em dash would be data).
func (c Currency) Code() string { return string(c) }

// PairKey is the storage key for an FX pair, e.g. "USD/CAD".
func PairKey(base, quote Currency) string {
	return string(base) + "/" + string(quote)
}
