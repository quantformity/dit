package cli

import (
	"sort"
	"strings"

	"dit/internal/model"
)

// The dispatch table.
//
// Commands are data: a name, the options it accepts, and a function. Keeping
// the table complete even where the Go port has not reached a command yet is
// deliberate — an unimplemented command says so, instead of falling through to
// something that prints a plausible but wrong answer.

// Command is a command: given a context and the leftover arguments, do the
// thing or return the error explaining why not. Commands are plain functions
// in a table rather than methods on a framework — adding one means adding a
// name and a function, nothing to subclass.
type Command func(context Context, arguments []string) error

// Spec is a command's entry in the table.
//
// Run == nil marks a known-but-unported command. It is reported as unported
// instead of quietly succeeding, so a half-port fails loudly.
type Spec struct {
	Run          Command
	ValueOptions map[string]bool
	FlagOptions  map[string]bool
	HelpText     string
	SkipParse    bool // the command owns parsing or deliberately ignores leftovers
}

// Registry is the command table, keyed by "group sub" or "group".
type Registry map[string]*Spec

// mergeLayers combines command tables. A later layer overrides an earlier one,
// which lets a test hand in a replacement without editing the table.
func mergeLayers(layers ...Registry) Registry {
	merged := Registry{}
	for _, layer := range layers {
		for name, spec := range layer {
			merged[name] = spec
		}
	}
	return merged
}

// Lookup finds the Spec for a group/sub pair.
//
// A two-word group ("account list") and a single-word command ("accounts")
// both resolve here so main does not need to know which style a command uses.
func (registry Registry) Lookup(group, sub string) (string, *Spec) {
	for _, name := range []string{group + " " + sub, group, strings.TrimSpace(group)} {
		if spec, ok := registry[name]; ok {
			return name, spec
		}
	}
	return "", nil
}

// ParseFor validates a command's arguments against what that command declared,
// which is where an unknown option becomes a usage error before any store is
// opened.
func (spec *Spec) ParseFor(arguments []string) (Options, error) {
	valueOptions := spec.ValueOptions
	if valueOptions == nil {
		valueOptions = map[string]bool{}
	}
	flagOptions := spec.FlagOptions
	if flagOptions == nil {
		flagOptions = map[string]bool{}
	}
	return ParseOptions(arguments, valueOptions, flagOptions)
}

// Names lists every command name, for help and for the parity harness.
func (registry Registry) Names() []string {
	names := make([]string, 0, len(registry))
	for name := range registry {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// SplitCommandWords separates the leading command words from the arguments.
// Only bare tokens at the front are command words, and only while the command
// still accepts them: "dit accounts TFSA" keeps TFSA as an argument, while
// "dit --store PATH summary" still selects summary.
func SplitCommandWords(arguments []string) (group, sub string, rest []string) {
	if len(arguments) == 0 {
		return "", "", nil
	}
	groups := map[string]bool{"account": true, "transaction": true, "tx": true,
		"ticker": true, "store": true, "market": true, "quote": true, "help": true}
	// Leading opaque options belong to the command's leftover arguments, not
	// to command resolution. Swift accepts forms such as `-x accounts` and
	// lets accounts decide whether to ignore them.
	prefix := []string{}
	start := 0
	for start < len(arguments) && strings.HasPrefix(arguments[start], "-") {
		prefix = append(prefix, arguments[start])
		start++
	}
	if start == len(arguments) {
		return strings.ToLower(arguments[0]), "", arguments[1:]
	}
	first := strings.ToLower(arguments[start])
	if !groups[first] {
		return first, "", append(prefix, arguments[start+1:]...)
	}
	if start+1 < len(arguments) && !strings.HasPrefix(arguments[start+1], "-") {
		return first, strings.ToLower(arguments[start+1]), append(prefix, arguments[start+2:]...)
	}
	return first, "", append(prefix, arguments[start+1:]...)
}

// DisplayCurrency maps a --display argument to a currency.
func DisplayCurrency(display string) model.Currency {
	return model.Currency(strings.ToUpper(strings.TrimSpace(display)))
}

// KnownDisplayCurrencies lists the codes --display accepts.
func KnownDisplayCurrencies() []model.Currency { return model.KnownCurrencies() }
