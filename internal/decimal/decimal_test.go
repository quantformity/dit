package decimal

import (
	"encoding/json"
	"testing"
)

func mustParse(t *testing.T, text string) Decimal {
	t.Helper()
	d, err := Parse(text)
	if err != nil {
		t.Fatalf("Parse(%q): %v", text, err)
	}
	return d
}

func TestParseAndStringRoundTrip(t *testing.T) {
	cases := []struct{ in, want string }{
		{"0", "0"},
		{"0.00", "0"},
		{"-0", "0"},
		{"3", "3"},
		{"3.25", "3.25"},
		{"-3.250", "-3.25"},
		{"0.0001", "0.0001"},
		{"1234.5678", "1234.5678"},
		{"100000.000001", "100000.000001"},
		{"1.5e3", "1500"},
		{"1.5e-3", "0.0015"},
		{"  -0.75  ", "-0.75"},
	}
	for _, c := range cases {
		if got := mustParse(t, c.in).String(); got != c.want {
			t.Errorf("Parse(%q).String() = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestParseRejectsGarbage(t *testing.T) {
	for _, bad := range []string{"", "  ", "abc", "1.2.3", "1e", "1e99999999"} {
		if _, err := Parse(bad); err == nil {
			t.Errorf("Parse(%q) should have failed", bad)
		}
	}
}

func TestExactArithmetic(t *testing.T) {
	cases := []struct {
		op   string
		a, b string
		want string
	}{
		{"add", "0.1", "0.2", "0.3"}, // the classic float trap
		{"add", "123456.78", "0.01", "123456.79"},
		{"sub", "0.3", "0.1", "0.2"},
		{"sub", "0", "5", "-5"},
		{"mul", "1.1", "1.1", "1.21"},
		{"mul", "0.0001", "0.0001", "0.00000001"},
		{"mul", "3.5", "100", "350"},
		{"mul", "-2.5", "4", "-10"},
	}
	for _, c := range cases {
		a, b := mustParse(t, c.a), mustParse(t, c.b)
		var got Decimal
		switch c.op {
		case "add":
			got = a.Add(b)
		case "sub":
			got = a.Sub(b)
		case "mul":
			got = a.Mul(b)
		}
		if got.String() != c.want {
			t.Errorf("%s(%s,%s) = %s, want %s", c.op, c.a, c.b, got, c.want)
		}
	}
}

func TestDivRoundsHalfAwayFromZero(t *testing.T) {
	cases := []struct {
		a, b  string
		scale int32
		want  string
	}{
		{"1", "3", 4, "0.3333"},
		{"2", "3", 4, "0.6667"},
		{"10", "4", 2, "2.50"},
		{"1", "8", 4, "0.1250"},
		{"1", "16", 4, "0.0625"},
		{"-1", "3", 4, "-0.3333"},
		{"-0.00005", "0.0001", 4, "-0.5000"},
		{"100", "3", 2, "33.33"},
		{"2", "7", 6, "0.285714"},
	}
	for _, c := range cases {
		got := mustParse(t, c.a).Div(mustParse(t, c.b), c.scale).Fixed(c.scale)
		if got != c.want {
			t.Errorf("%s/%s at scale %d = %s, want %s", c.a, c.b, c.scale, got, c.want)
		}
	}
}

func TestDivByZeroIsZero(t *testing.T) {
	if got := FromInt(5).Div(Zero, 4).String(); got != "0" {
		t.Errorf("5/0 = %s, want 0", got)
	}
}

func TestRoundHalfAway(t *testing.T) {
	cases := []struct {
		in    string
		scale int32
		want  string
	}{
		{"2.345", 2, "2.35"}, // .345 ties away from zero
		{"-2.345", 2, "-2.35"},
		{"2.344", 2, "2.34"},
		{"2.3449999", 2, "2.34"},
		{"0.00005", 4, "0.0001"},
		{"1234.5678", 2, "1234.57"},
		{"1.5", 4, "1.5000"}, // rounding UP to a longer scale is a no-op
	}
	for _, c := range cases {
		if got := mustParse(t, c.in).Round(c.scale).Fixed(c.scale); got != c.want {
			t.Errorf("Round(%s,%d) = %s, want %s", c.in, c.scale, got, c.want)
		}
	}
}

func TestFixedPadsZeros(t *testing.T) {
	cases := []struct {
		in    string
		scale int32
		want  string
	}{
		{"0", 2, "0.00"},
		{"-0.5", 2, "-0.50"},
		{"12500", 2, "12500.00"},
		{"0.5", 4, "0.5000"},
		{"-1234.5", 2, "-1234.50"},
		{"7", 0, "7"},
	}
	for _, c := range cases {
		if got := mustParse(t, c.in).Fixed(c.scale); got != c.want {
			t.Errorf("Fixed(%s,%d) = %s, want %s", c.in, c.scale, got, c.want)
		}
	}
}

func TestCmpIgnoresScale(t *testing.T) {
	a := mustParse(t, "1.50")
	b := mustParse(t, "1.5")
	if !a.Equal(b) {
		t.Errorf("1.50 should equal 1.5")
	}
	if a.Cmp(mustParse(t, "1.4999")) != 1 {
		t.Errorf("1.50 should be greater than 1.4999")
	}
	if mustParse(t, "-1").Cmp(Zero) != -1 {
		t.Errorf("-1 should be less than 0")
	}
}

func TestJSONIsABareNumber(t *testing.T) {
	// The Swift store writes money as a JSON number ("amount":12500), so a
	// quoted string here would be a different file format.
	payload, err := json.Marshal(map[string]any{"amount": FromInt(12500)})
	if err != nil {
		t.Fatal(err)
	}
	if string(payload) != `{"amount":12500}` {
		t.Errorf("marshalled %s", payload)
	}
	var back struct {
		Amount Decimal `json:"amount"`
	}
	if err := json.Unmarshal(payload, &back); err != nil {
		t.Fatal(err)
	}
	if !back.Amount.Equal(FromInt(12500)) {
		t.Errorf("round trip gave %s", back.Amount)
	}
	quoted := []byte(`{"amount":"12500.50"}`)
	if err := json.Unmarshal(quoted, &back); err != nil {
		t.Fatalf("quoted decimals should still decode: %v", err)
	}
	if back.Amount.String() != "12500.5" {
		t.Errorf("got %s", back.Amount)
	}
}

// TestMoneySumStaysExact replays the accumulation the summary path does:
// hundreds of small additions must not drift.
func TestMoneySumStaysExact(t *testing.T) {
	step := mustParse(t, "0.01")
	total := Zero
	for i := 0; i < 10000; i++ {
		total = total.Add(step)
	}
	if total.String() != "100" {
		t.Errorf("10000 × 0.01 = %s, want 100", total)
	}
}
