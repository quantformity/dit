// Command dit is the Go port of the Swift `dit` CLI.
//
// It reads the same store files the Swift binary writes, and answers the same
// questions the same way: the acceptance test is scripts/parity.sh, which runs
// a command through both binaries against one store and fails on any
// difference.
//
// Exit codes are unchanged: 0 success, 1 runtime error, 2 usage error.
package main

import (
	"fmt"
	"io"
	"os"
	"strings"

	"dit/internal/cli"
	"dit/internal/config"
)

// globalValueFlags are the options that consume a following value wherever
// they appear: `dit --store PATH summary` and `dit summary --store PATH` are
// the same request.
var globalValueFlags = map[string]bool{
	"--display": true, "--store": true, "--market-store": true, "--backend": true,
}

var globalBoolFlags = map[string]bool{"--offline": true, "--json": true}

func main() {
	// Line-buffered output, so a message written to stderr cannot land in the
	// middle of a table row when the two streams are merged.
	arguments := os.Args[1:]
	global, rest, err := parseGlobals(arguments)
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		fmt.Fprintln(os.Stderr, cli.GlobalParseUsageText())
		os.Exit(2)
	}
	layout, err := config.Resolve(nil, global.backend, global.store, global.market)
	if err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
	if err := checkDisplay(global.display); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		fmt.Fprintln(os.Stderr, cli.GlobalParseUsageText())
		os.Exit(2)
	}
	context := newContext(global, layout, os.Stdout, os.Stderr)
	os.Exit(cli.Dispatch(context, rest))
}

// defaultDisplay is the currency combined totals speak when nobody says
// otherwise. The Swift original declares it once, as the starting value of
// `Global.display` (`var display: Currency = .cad`), and `market coverage`
// takes its default REPORTING currency from that same field: a CAD account
// holding USD cash still gets a USD→CAD chain audited.
//
// An empty default is not the neutral choice it looks like. Reporting into no
// currency means there is no foreign total to combine, so the FX half of the
// audit silently vanishes and the report claims its ledger is covered — a
// wrong answer, not a formatting difference. So the default is resolved here,
// where the globals are, and never inside a command.
const defaultDisplay = "CAD"

// newContext assembles what a command is handed from the parsed globals. It is
// a function rather than a literal in main so the default above can be tested
// through the same path a real invocation takes.
func newContext(global globals, layout config.Layout, stdout io.Writer, stderr io.Writer) cli.Context {
	return cli.Context{
		Layout:  layout,
		JSON:    global.json,
		Offline: global.offline,
		Display: cli.DisplayCurrency(global.display),
		Out:     stdout,
		Err:     stderr,
	}
}

type globals struct {
	backend, store, market, display string
	offline, json                   bool
}

// parseGlobals lifts the global options out of the argument list and keeps the
// command words in their original order.
func parseGlobals(arguments []string) (globals, []string, error) {
	// The zero value would mean "no reporting currency", which is not a state
	// the Swift CLI can be in.
	found := globals{display: defaultDisplay}
	rest := make([]string, 0, len(arguments))
	for index := 0; index < len(arguments); index++ {
		argument := arguments[index]
		name, inlineValue, hasInline := strings.Cut(argument, "=")
		switch {
		case globalValueFlags[name]:
			value := inlineValue
			if !hasInline {
				index++
				if index >= len(arguments) {
					return found, nil, fmt.Errorf("missing value for %s", argument)
				}
				value = arguments[index]
			}
			switch name {
			case "--display":
				found.display = value
			case "--store":
				found.store = value
			case "--market-store":
				found.market = value
			case "--backend":
				if value != "file" && value != "sqlite" {
					return found, nil, fmt.Errorf("unknown backend '%s' — use 'file' or 'sqlite'", value)
				}
				found.backend = value
			}
		case globalBoolFlags[name]:
			if hasInline {
				return found, nil, fmt.Errorf("%s is a flag and takes no value", name)
			}
			if name == "--offline" {
				found.offline = true
			} else {
				found.json = true
			}
		default:
			rest = append(rest, argument)
		}
	}
	return found, rest, nil
}

// checkDisplay rejects an unknown currency at the point it is given. A display
// currency that silently fell back would print numbers in the wrong unit under
// a header naming a different one. The untouched default passes: it is the
// oracle's own default, not a fallback for a bad argument.
func checkDisplay(display string) error {
	if display == "" || display == defaultDisplay {
		return nil
	}
	normalized := strings.ToUpper(strings.TrimSpace(display))
	for _, known := range cli.KnownDisplayCurrencies() {
		if string(known) == normalized {
			return nil
		}
	}
	return fmt.Errorf("unknown currency '%s' for --display — use e.g. CAD, USD, JPY, or GBp", display)
}
