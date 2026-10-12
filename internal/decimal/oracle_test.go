package decimal

import (
	"bufio"
	"os"
	"strconv"
	"strings"
	"testing"
)

// TestAgainstExactRationalOracle replays ~13,500 cases computed independently
// in Python with arbitrary-precision rationals (fractions.Fraction), where
// rounding means "scale to N places, half away from zero".
//
// It exists because money code is where a subtly wrong rounding rule hides:
// it shows up as one cent of difference on one instrument on one day, which
// no hand-written test will think to ask about. An oracle that shares no code
// with this package is the only way to learn the rule is right rather than
// merely self-consistent.
//
// Regenerate the cases with scripts/gen-decimal-cases.sh.
func TestAgainstExactRationalOracle(t *testing.T) {
	file, err := os.Open("../../testdata/decimal-cases.txt")
	if err != nil {
		t.Skip("oracle cases not present:", err)
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	scanner.Buffer(make([]byte, 64*1024), 64*1024)
	checked := 0
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		parts := strings.Split(line, "|")
		if len(parts) != 5 {
			t.Fatalf("malformed case %q", line)
		}
		op, a, b, want := parts[0], parts[1], parts[2], parts[4]
		scale, err := strconv.ParseInt(parts[3], 10, 32)
		if err != nil {
			t.Fatalf("malformed scale in %q", line)
		}
		left := parse(t, a)
		right := parse(t, b)

		var got string
		switch op {
		case "add":
			got = left.Add(right).String()
		case "sub":
			got = left.Sub(right).String()
		case "mul":
			got = left.Mul(right).String()
		case "div":
			if right.IsZero() {
				continue
			}
			got = left.Div(right, int32(scale)).Fixed(int32(scale))
		case "round", "fixed":
			rounded := left
			if left.scale > int32(scale) {
				rounded = left.Round(int32(scale))
			}
			got = rounded.Fixed(int32(scale))
		default:
			t.Fatalf("unknown op %q", op)
		}
		checked++
		if got != want {
			t.Errorf("%s: %s (op %s, scale %d) = %s, oracle says %s", op, a, b, scale, got, want)
			if checked > 50 {
				t.Fatal("too many mismatches; stopping early")
			}
		}
	}
	if err := scanner.Err(); err != nil {
		t.Fatal(err)
	}
	if checked < 10_000 {
		t.Fatalf("only replayed %d cases", checked)
	}
}

func parse(t *testing.T, text string) Decimal {
	t.Helper()
	if text == "" {
		return Zero
	}
	d, err := Parse(text)
	if err != nil {
		t.Fatalf("Parse(%q): %v", text, err)
	}
	return d
}
