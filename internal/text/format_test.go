package text

import (
	"strings"
	"testing"

	"dit/internal/decimal"
)

func value(t *testing.T, text string) decimal.Decimal {
	t.Helper()
	parsed, err := decimal.Parse(text)
	if err != nil {
		t.Fatal(err)
	}
	return parsed
}

func TestMoneyAndQuantityFormatting(t *testing.T) {
	cases := []struct {
		in     string
		money  string
		quanti string
	}{
		{"1234.5678", "1,234.57", "1,234.5678"},
		{"-6768.5", "-6,768.50", "-6,768.5"},
		{"1260", "1,260.00", "1,260"},
		{"96.7", "96.70", "96.7"},
		{"0.005", "0.01", "0.005"},
		{"-0.001", "-0.00", "-0.001"}, // a negative must not lose its sign
		{"12345678.9", "12,345,678.90", "12,345,678.9"},
	}
	for _, c := range cases {
		input := value(t, c.in)
		if got := Money(input); got != c.money {
			t.Errorf("Money(%s) = %s, want %s", c.in, got, c.money)
		}
		if got := Quantity(input); got != c.quanti {
			t.Errorf("Quantity(%s) = %s, want %s", c.in, got, c.quanti)
		}
	}
}

func TestPercentKeepsThePlus(t *testing.T) {
	cases := []struct{ in, want string }{
		{"0.123", "+12.3%"},
		{"-0.004", "-0.4%"},
		{"1.619", "+161.9%"},
		{"0", "0.0%"},
	}
	for _, c := range cases {
		if got := Percent(value(t, c.in)); got != c.want {
			t.Errorf("Percent(%s) = %s, want %s", c.in, got, c.want)
		}
	}
}

// TestTableMatchesSwiftRendering pins the box-drawing output. The strings here
// were captured from the Swift binary, not written by hand: the grid is the
// part of a CLI port that can drift one space at a time and look fine.
func TestTableMatchesSwiftRendering(t *testing.T) {
	headers := []string{"Name", "Institution", "Ccy", "Taxable", "Status"}
	rows := [][]string{
		{"TFSA", "", "CAD", "yes", ""},
		{"Margin", "Mercury", "USD", "yes", ""},
	}
	want := []string{
		"┌────────┬─────────────┬─────┬─────────┬────────┐",
		"│ Name   │ Institution │ Ccy │ Taxable │ Status │",
		"├────────┼─────────────┼─────┼─────────┼────────┤",
		"│ TFSA   │             │ CAD │     yes │        │",
		"├────────┼─────────────┼─────┼─────────┼────────┤",
		"│ Margin │     Mercury │ USD │     yes │        │",
		"└────────┴─────────────┴─────┴─────────┴────────┘",
	}
	got := Table(headers, rows, map[int]bool{0: true}, false)
	if len(got) != len(want) {
		t.Fatalf("got %d lines, want %d:\n%s", len(got), len(want), joinLines(got))
	}
	for index := range want {
		if got[index] != want[index] {
			t.Errorf("line %d:\n got %q\nwant %q", index, got[index], want[index])
		}
	}
}

func joinLines(lines []string) string {
	out := ""
	for _, line := range lines {
		out += line + "\n"
	}
	return out
}

// TestBarsCannotTearTheGrid checks the broken-bar rule: a vertical bar inside
// a value becomes the broken bar (¦) so data can never be mistaken for a
// column wall.
func TestBarsCannotTearTheGrid(t *testing.T) {
	lines := Table([]string{"L", "R"}, [][]string{{"a|b", "c│d"}}, map[int]bool{0: true}, false)
	joined := joinLines(lines)
	if strings.Contains(joined, "|") {
		t.Errorf("a raw bar survived into the grid:\n%s", joined)
	}
	if !strings.Contains(joined, "a¦b") {
		t.Errorf("the data bar was not broken:\n%s", joined)
	}
	// Every wall must line up, whatever the data contained.
	for _, line := range lines {
		if strings.HasPrefix(line, "│") && strings.Count(line, "│") != 3 {
			t.Errorf("grid walls do not line up: %q", line)
		}
	}
}
