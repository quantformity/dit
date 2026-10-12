package model

import (
	"encoding/json"
	"fmt"
	"time"
)

// ReferenceDelta is the gap between the stored date epoch and Unix time.
//
// The Swift implementation encodes Date through Foundation, which counts
// seconds from 2001-01-01 UTC (CoreFoundation's reference date), not from
// 1970. Nothing in a store file says so: a date reads as a bare number like
// 726019200, which is 1993-01-03 in Unix time and 2024-01-04 in the real
// format. Guessing wrong here shifts every transaction, price and maturity
// date 31 years into the past and still "works" until someone compares a
// number against the calendar — so the offset lives in one place and the
// fixtures carry the proof.
const ReferenceDelta int64 = 978307200

// Day is a calendar date, held internally as Unix seconds at UTC midnight and
// stored as reference seconds.
//
// Normalizing to UTC midnight is what makes "already have 2026-05-01" work
// across providers whose timestamps carry exchange-local times.
type Day int64

// Stamp is a point in time with sub-second precision (a fetched quote's
// asOf, a store's updatedAt). Like Day it is stored relative to 2001-01-01.
type Stamp float64

// DayStartUTC collapses Unix seconds onto their UTC calendar day.
func DayStartUTC(seconds int64) int64 {
	return time.Unix(seconds, 0).UTC().Truncate(24 * time.Hour).Unix()
}

// DayTime resolves a Day to a Go time in UTC.
func (d Day) DayTime() time.Time { return time.Unix(int64(d), 0).UTC() }

// String renders a Day as YYYY-MM-DD.
func (d Day) String() string { return d.DayTime().Format("2006-01-02") }

// ToReference converts Unix seconds to the stored form.
func ToReference(unixSeconds int64) float64 {
	return float64(unixSeconds) - float64(ReferenceDelta)
}

// FromReference converts a stored date number to Unix seconds.
func FromReference(stored float64) int64 {
	return int64(stored + float64(ReferenceDelta))
}

// ParseDay reads YYYY-MM-DD (also accepting a longer timestamp that starts
// with one) as a UTC calendar day.
func ParseDay(text string) (Day, error) {
	body := text
	if len(body) >= 10 {
		body = body[:10]
	}
	parsed, err := time.Parse("2006-01-02", body)
	if err != nil {
		return 0, fmt.Errorf("not a date (want YYYY-MM-DD): %q", text)
	}
	return Day(parsed.Unix()), nil
}

// MarshalJSON writes reference seconds. A whole number is written without a
// fraction, matching how the Swift encoder prints a date with no sub-second
// part.
func (d Day) MarshalJSON() ([]byte, error) {
	return []byte(fmt.Sprintf("%d", int64(ToReference(int64(d))))), nil
}

// UnmarshalJSON reads a stored date, normalizing it to its UTC day. The
// fraction is dropped: a Day is a calendar day, whatever timestamp arrived.
func (d *Day) UnmarshalJSON(data []byte) error {
	var raw json.Number
	if err := json.Unmarshal(data, &raw); err != nil {
		return fmt.Errorf("date is not a number: %s", data)
	}
	stored, err := raw.Float64()
	if err != nil {
		return fmt.Errorf("unreadable date: %s", data)
	}
	*d = Day(DayStartUTC(FromReference(stored)))
	return nil
}

// AsDay drops the time of day, for comparing timestamps by calendar day.
func (s Stamp) AsDay() Day { return Day(DayStartUTC(int64(s))) }

// String renders a Stamp as a UTC timestamp.
func (s Stamp) String() string {
	return time.Unix(int64(s), 0).UTC().Format("2006-01-02 15:04:05")
}

// MarshalJSON writes reference seconds, keeping the fraction.
func (s Stamp) MarshalJSON() ([]byte, error) {
	return []byte(fmt.Sprintf("%g", float64(s)-float64(ReferenceDelta))), nil
}

// UnmarshalJSON reads a stored timestamp.
func (s *Stamp) UnmarshalJSON(data []byte) error {
	var raw json.Number
	if err := json.Unmarshal(data, &raw); err != nil {
		return fmt.Errorf("timestamp is not a number: %s", data)
	}
	stored, err := raw.Float64()
	if err != nil {
		return fmt.Errorf("unreadable timestamp: %s", data)
	}
	*s = Stamp(stored + float64(ReferenceDelta))
	return nil
}

// DayFromUnix puts a Unix timestamp (a fetched quote's asOf, say) onto the
// calendar day that contains it. Both Day and Unix seconds are counted from
// 1970 internally, so this is a truncation, not a reference-epoch conversion.
func DayFromUnix(unixSeconds int64) Day { return Day(DayStartUTC(unixSeconds)) }
