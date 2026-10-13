package main

import (
	"bytes"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"dit/internal/cli"
	"dit/internal/config"
	"dit/internal/model"
)

// These tests drive a command through the path a real invocation takes:
// parseGlobals, then newContext, then Dispatch. The default reporting currency
// lives in that wiring, and nowhere else — the unit tests in internal/market
// hand the command a Context whose Display is already CAD, so a default that
// quietly resolved to "no currency" could only ever be caught here.

// fixtureDir holds stores and answers written by /opt/homebrew/bin/dit; see
// testdata/market/README.md.
const fixtureDir = "../../testdata/market"

// outcome is what one CLI run produced.
type outcome struct {
	code   int
	stdout string
	stderr string
	// market is the scratch market directory named in the header line; the
	// fixtures hold that path as <MARKET>.
	market string
}

// withoutPath is stdout with the scratch store path put back the way the
// fixtures spell it: the path is scaffolding, and comparing it would test the
// name of a temporary directory instead of the answer.
func (r outcome) withoutPath() string {
	return strings.ReplaceAll(r.stdout, r.market, "<MARKET>")
}

// runCLI dispatches one invocation against a copy of the Swift-written fixture
// store, so the run reads exactly the bytes the oracle produced its answer
// from. A fresh copy per run keeps a command that writes from tilting the
// next one.
func runCLI(t *testing.T, arguments []string) outcome {
	t.Helper()
	root := t.TempDir()
	ledger := filepath.Join(root, "store")
	prices := filepath.Join(root, "market")
	for _, entry := range []struct{ dir, file string }{
		{ledger, "portfolio.dat"},
		{prices, "market.dat"},
	} {
		if err := os.MkdirAll(entry.dir, 0o755); err != nil {
			t.Fatal(err)
		}
		payload, err := os.ReadFile(filepath.Join(fixtureDir, entry.file))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(entry.dir, entry.file), payload, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	global, rest, err := parseGlobals(arguments)
	if err != nil {
		t.Fatalf("parseGlobals(%v): %v", arguments, err)
	}
	var out, errors bytes.Buffer
	context := newContext(global, config.Layout{
		Backend:      config.File,
		PortfolioDir: ledger,
		MarketDir:    prices,
	}, &out, &errors)
	code := cli.Dispatch(context, rest)
	return outcome{code: code, stdout: out.String(), stderr: errors.String(), market: prices}
}

func TestDefaultDisplayIsTheOracleDefault(t *testing.T) {
	// `Global.display` starts at .cad in the Swift original and nothing but
	// --display moves it. Here an empty string decodes to model.Unknown, which
	// means "no reporting currency at all" — a state the original cannot be in.
	global, rest, err := parseGlobals([]string{"market", "coverage"})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(rest, " ") != "market coverage" {
		t.Fatalf("parsing the globals lost the command words: %v", rest)
	}
	if global.display != defaultDisplay {
		t.Fatalf("default display currency is %q, want %q", global.display, defaultDisplay)
	}
	if got := cli.DisplayCurrency(global.display); got != model.CAD {
		t.Fatalf("the default decodes to %q, which is no currency at all", got)
	}
	// The default is a starting value, not a second source of truth: a given
	// --display still wins, and an unknown code is still refused rather than
	// quietly replaced by something plausible.
	overridden, _, err := parseGlobals([]string{"--display", "USD", "market", "coverage"})
	if err != nil {
		t.Fatal(err)
	}
	if overridden.display != "USD" {
		t.Fatalf("--display never reached the globals: %q", overridden.display)
	}
	if err := checkDisplay("XYZ"); err == nil {
		t.Fatal("an unknown display currency must stay a usage error")
	}
}

// TestCoverageWithoutDisplayMatchesOracle pins the answer, not the layout.
//
// With no reporting currency the audit has nothing to combine, so every FX
// chain dropped out of the report and complete came back true: the Go binary
// was describing a portfolio with no foreign money in it and calling the ledger
// covered. The fixtures are the Swift binary's own answers on this store,
// taken at its default CAD, so they carry the USD→CAD, HKD→CAD and JPY→CAD
// rows and complete:false.
func TestCoverageWithoutDisplayMatchesOracle(t *testing.T) {
	const strictNote = "error: coverage gaps listed above — " +
		"'dit market history' fetches, 'dit market import' seeds\n"
	for _, tc := range []struct {
		name       string
		arguments  []string
		fixture    string
		wantCode   int
		wantStderr string
	}{
		{"human", []string{"market", "coverage", "--to", "2026-10-01"}, "coverage.txt", 0, ""},
		{"machine", []string{"market", "coverage", "--to", "2026-10-01", "--json"}, "coverage.json", 0, ""},
		{"strict", []string{"market", "coverage", "--to", "2026-10-01", "--strict"}, "coverage.txt", 1, strictNote},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := runCLI(t, tc.arguments)
			payload, err := os.ReadFile(filepath.Join(fixtureDir, tc.fixture))
			if err != nil {
				t.Fatal(err)
			}
			want := string(payload)
			if got.withoutPath() != want {
				t.Fatalf("stdout differs from the oracle\n--- got ---\n%s\n--- want ---\n%s",
					got.withoutPath(), want)
			}
			if got.code != tc.wantCode {
				t.Fatalf("exit code %d, want %d", got.code, tc.wantCode)
			}
			if got.stderr != tc.wantStderr {
				t.Fatalf("stderr = %q, want %q", got.stderr, tc.wantStderr)
			}
		})
	}
}

func TestVersionTextIncludesVersionAndBuildTimestamp(t *testing.T) {
	got := versionText()
	if !regexp.MustCompile(`^dit 0\.0\.1 \([0-9]{8}\.[0-9]{6}\)$`).MatchString(got) {
		t.Fatalf("versionText() = %q, want dit 0.0.1 (YYYYMMDD.HHMMSS)", got)
	}
}

func TestGlobalBooleanFlagsRejectInlineValuesLikeSwift(t *testing.T) {
	for _, token := range []string{"--json=1", "--json=false", "--offline=1"} {
		t.Run(token, func(t *testing.T) {
			_, _, err := parseGlobals([]string{token, "summary"})
			if err == nil || !strings.Contains(err.Error(), "is a flag and takes no value") {
				t.Fatalf("parseGlobals(%q) error = %v", token, err)
			}
		})
	}
}
