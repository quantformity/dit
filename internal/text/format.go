// Package text holds the display formatting decisions: what a cent looks
// like, what a quantity looks like, and what a table looks like.
//
// These are shared by every command on purpose. The same shapes were spelled
// by hand in about ten places in the original Swift CLI, each free to drift;
// one home makes "what a cent looks like" a single decision.
//
// Two families stay separate, per docs/json.md: DISPLAY text groups thousands
// (en_US), MACHINE text (JSON) never groups. Neither path uses a binary
// float.
package text

import (
	"strings"

	"dit/internal/decimal"
)

// Money renders table money: exactly two places, thousands grouped
// ("1,234.57", "-6,789.50"). The currency tag is the caller's business.
//
// A negative that is too small to show still prints its sign ("-0.00"),
// because hiding the sign of a negative balance is how a report starts lying.
func Money(value decimal.Decimal) string {
	text := grouped(value, 2, true)
	if value.Sign() < 0 && !strings.HasPrefix(text, "-") {
		text = "-" + text
	}
	return text
}

// Quantity renders prices and share counts: up to four places, trailing zeros
// trimmed, grouped ("42.7674", "1,260", "96.7").
func Quantity(value decimal.Decimal) string {
	trimmed := strings.TrimRight(value.Fixed(4), "0")
	trimmed = strings.TrimSuffix(trimmed, ".")
	if trimmed == "" || trimmed == "-" {
		trimmed = "0"
	}
	if !strings.Contains(trimmed, ".") {
		return groupedText(trimmed, true)
	}
	parts := strings.SplitN(trimmed, ".", 2)
	return groupedText(parts[0], true) + "." + parts[1]
}

// Fixed renders non-grouped text with exactly scale places, for JSON output
// ("279900.60" at 2, "0.0153" at 4).
func Fixed(value decimal.Decimal, scale int32) string { return value.Fixed(scale) }

// grouped renders a value with `scale` places and optional thousands grouping.
func grouped(value decimal.Decimal, scale int32, grouping bool) string {
	return groupedText(value.Fixed(scale), grouping)
}

// groupedText inserts thousands separators into an already-formatted decimal
// string, leaving the fraction untouched.
func groupedText(text string, grouping bool) string {
	if !grouping {
		return text
	}
	negative := strings.HasPrefix(text, "-")
	body := strings.TrimPrefix(text, "-")
	whole, fraction := body, ""
	if dot := strings.IndexByte(body, '.'); dot >= 0 {
		whole, fraction = body[:dot], body[dot:]
	}
	if len(whole) <= 3 {
		if negative {
			return "-" + whole + fraction
		}
		return whole + fraction
	}
	var builder strings.Builder
	leading := len(whole) % 3
	if leading == 0 {
		leading = 3
	}
	builder.WriteString(whole[:leading])
	for index := leading; index < len(whole); index += 3 {
		builder.WriteString(",")
		builder.WriteString(whole[index : index+3])
	}
	if negative {
		return "-" + builder.String() + fraction
	}
	return builder.String() + fraction
}

// Percent renders a fraction as a percentage with one place, keeping an
// explicit "+" on positives so a column of mixed results reads at a glance
// (0.123 → "+12.3%", -0.004 → "-0.4%").
func Percent(fraction decimal.Decimal) string {
	value := fraction.Mul(decimal.FromInt(100)).Round(1)
	text := value.Fixed(1)
	if fraction.Sign() > 0 {
		return "+" + text + "%"
	}
	return text + "%"
}

// Table renders a full-grid table in Unicode box-drawing style: │ column
// walls, a ├─┼─┤ rule between every pair of rows, and ┌ ┬ ┐ joints. Columns
// are padded to the widest cell so the grid aligns straight off stdout.
//
// Bars inside data become broken bars (¦) so a value can never tear a grid
// wall apart. `bold` adds the terminal bold escape to header labels only —
// measurement stays plain text, so column widths do not depend on whether
// output is a terminal.
func Table(headers []string, rows [][]string, leftColumns map[int]bool, bold bool) []string {
	columns := len(headers)
	if len(leftColumns) == 0 {
		leftColumns = map[int]bool{0: true}
	}
	sanitize := func(cell string) string {
		cell = strings.ReplaceAll(cell, "|", "¦")
		return strings.ReplaceAll(cell, "│", "¦")
	}
	widths := make([]int, columns)
	for column := 0; column < columns; column++ {
		widest := len([]rune(sanitize(headers[column])))
		for _, row := range rows {
			if column < len(row) {
				if length := len([]rune(sanitize(row[column]))); length > widest {
					widest = length
				}
			}
		}
		widths[column] = widest
	}

	rule := func(left, middle, right string) string {
		var builder strings.Builder
		builder.WriteString(left)
		for column, width := range widths {
			if column > 0 {
				builder.WriteString(middle)
			}
			// One padding space on each side, plus one for the wall: the rule
			// has to span a cell's padding too, so every joint lands exactly on
			// a row wall.
			builder.WriteString(strings.Repeat("─", width+2))
		}
		builder.WriteString(right)
		return builder.String()
	}

	rowLine := func(cells []string, boldRow bool) string {
		parts := make([]string, 0, columns)
		for column := 0; column < columns; column++ {
			cell := ""
			if column < len(cells) {
				cell = sanitize(cells[column])
			}
			padding := strings.Repeat(" ", widths[column]-len([]rune(cell)))
			label := cell
			if boldRow && cell != "" {
				label = "\x1b[1m" + cell + "\x1b[22m"
			}
			if leftColumns[column] {
				parts = append(parts, " "+label+padding+" ")
			} else {
				parts = append(parts, " "+padding+label+" ")
			}
		}
		return "│" + strings.Join(parts, "│") + "│"
	}

	lines := []string{rule("┌", "┬", "┐"), rowLine(headers, bold)}
	for _, row := range rows {
		lines = append(lines, rule("├", "┼", "┤"), rowLine(row, false))
	}
	lines = append(lines, rule("└", "┴", "┘"))
	return lines
}
