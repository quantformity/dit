package cli

import (
	"os"

	"dit/internal/text"

	"github.com/mattn/go-isatty"
)

// boldHeaders mirrors the reference's TerminalStyle.stdoutSupportsBold:
// bold on a terminal, plain when piped or redirected, silent under
// NO_COLOR (any non-empty value) or TERM=dumb. The check is made against
// the command's own output writer, so unit tests that capture into a
// buffer stay plain while a real terminal run emits the same escape bytes
// the reference does. Only header labels are wrapped: padding and grid
// walls stay unstyled, and widths are measured on plain text.
func boldHeaders(c Context) bool {
	file, ok := c.Out.(*os.File)
	if !ok || !isatty.IsTerminal(file.Fd()) {
		return false
	}
	return os.Getenv("TERM") != "dumb" && os.Getenv("NO_COLOR") == ""
}

// Table renders a box-drawing table with only the first column left-aligned,
// which is how every report in the Swift CLI lines up its numbers: labels
// read left to right, amounts compare right to left. Header bold follows the
// same terminal policy as the reference.
func Table(c Context, headers []string, rows [][]string) []string {
	return text.Table(headers, rows, map[int]bool{0: true}, boldHeaders(c))
}
