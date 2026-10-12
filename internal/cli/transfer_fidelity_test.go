package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTransferUsageOutput(t *testing.T) {
	dir := t.TempDir()
	junk := filepath.Join(dir, "junk.json")
	bad := filepath.Join(dir, "bad.json")
	dump := filepath.Join(dir, "dump.json")
	for path, text := range map[string]string{
		junk: "not json",
		bad:  `{"schema":"bundle/1","generatedAt":1,"portfolio":{},"market":{}}`,
		dump: `{"accounts":[{"id":"11111111-1111-1111-1111-111111111111"},{"id":"22222222-2222-2222-2222-222222222222"}],"transactions":[],"tickers":[]}`,
	} {
		if err := os.WriteFile(path, []byte(text), 0600); err != nil {
			t.Fatal(err)
		}
	}
	cases := []struct {
		args          []string
		code          int
		message, help string
	}{
		{[]string{"market", "show", "KO"}, 2, "unexpected argument 'KO'", marketUsage},
		{[]string{"import", junk}, 2, "error:", exportUsage},
		{[]string{"import", bad}, 2, "the document.createdAt: no such field", exportUsage},
		{[]string{"store", "import", junk}, 2, "The data couldn’t be read because it isn’t in the correct format.", storeUsage},
		{[]string{"store", "import", dump}, 1, "the import file contains 2 accounts", ""},
	}
	for _, tc := range cases {
		t.Run(strings.Join(tc.args[:2], " "), func(t *testing.T) {
			var out, stderr bytes.Buffer
			c := Context{Out: &out, Err: &stderr}
			if code := Dispatch(c, tc.args); code != tc.code {
				t.Fatalf("exit %d, want %d: %s", code, tc.code, &stderr)
			}
			text := stderr.String()
			if !strings.Contains(text, tc.message) {
				t.Fatalf("missing message: %s", text)
			}
			if tc.help != "" && !strings.HasSuffix(text, tc.help+"\n") {
				t.Fatalf("missing exact usage: %s", text)
			}
			if tc.help == "" && strings.Contains(text, "USAGE:") {
				t.Fatalf("unexpected usage: %s", text)
			}
		})
	}
}

func TestConfirmationRefusalHasNoErrorPrefixOrUsage(t *testing.T) {
	var stderr bytes.Buffer
	c := Context{Err: &stderr}
	message := "refusing to continue without --yes on a non-interactive terminal"
	if code := c.Report(confirmationRefusal(message), exportUsage); code != 1 {
		t.Fatal(code)
	}
	if stderr.String() != message+"\n" {
		t.Fatalf("unexpected refusal: %q", stderr.String())
	}
}
