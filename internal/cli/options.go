package cli

import (
	"fmt"
	"strings"
)

// Options is one option scanner for every command, mirroring the Swift CLI's
// `Options` type token for token — including its error text, which the
// end-to-end suite asserts on.
//
// A command declares which options take a value and which are bare flags.
// Anything else that starts with a dash is a usage error rather than a
// positional: a typo like `--amunt` must not silently become a free-text
// argument and change what gets written to the ledger.
type Options struct {
	Values      map[string]string
	Flags       map[string]bool
	FlagValues  map[string]bool
	Positionals []string
}

// ParseOptions scans argument tokens.
func ParseOptions(args []string, valueOptions, flagOptions map[string]bool) (Options, error) {
	options := Options{
		Values:      map[string]string{},
		Flags:       map[string]bool{},
		FlagValues:  map[string]bool{},
		Positionals: []string{},
	}
	for index := 0; index < len(args); index++ {
		token := args[index]
		if token == "-h" || token == "--help" {
			continue
		}
		if strings.HasPrefix(token, "--") {
			body := token[2:]
			key, inline, hasInline := strings.Cut(body, "=")
			switch {
			case valueOptions[key]:
				if hasInline {
					options.Values[key] = inline
				} else {
					if index+1 >= len(args) {
						return options, usage(fmt.Sprintf("missing value for --%s", key))
					}
					options.Values[key] = args[index+1]
					index++
				}
			case flagOptions[key]:
				if hasInline {
					switch strings.ToLower(inline) {
					case "true", "yes":
						options.FlagValues[key] = true
					case "false", "no":
						options.FlagValues[key] = false
					default:
						return options, usage(fmt.Sprintf(
							"--%s is a flag — pass it, omit it, or write --%s=true / --%s=false",
							key, key, key))
					}
				} else {
					options.Flags[key] = true
				}
			default:
				return options, usage(fmt.Sprintf("unknown option '%s'", token))
			}
			continue
		}
		if strings.HasPrefix(token, "-") && len(token) > 1 {
			return options, usage(fmt.Sprintf("unknown option '%s'", token))
		}
		options.Positionals = append(options.Positionals, token)
	}
	return options, nil
}

// Value returns the raw value of --key, or "" when it was not passed.
func (o Options) Value(key string) string { return o.Values[key] }

// Has reports a bare flag, ignoring --flag=value forms.
func (o Options) Has(key string) bool { return o.Flags[key] }

// Flag reports a flag that may have been given explicitly: nil means it was
// not mentioned at all, which is different from being mentioned as false.
func (o Options) Flag(key string) *bool {
	if value, ok := o.FlagValues[key]; ok {
		return &value
	}
	if o.Flags[key] {
		value := true
		return &value
	}
	return nil
}

// Require returns a required option's value, or a usage error naming it.
func (o Options) Require(key string) (string, error) {
	value, ok := o.Values[key]
	if !ok || value == "" {
		return "", usage(fmt.Sprintf("missing required option --%s", key))
	}
	return value, nil
}

// RejectStrayPositionals turns leftover words into a usage error. Commands
// that take no arguments use it so `dit summary extra` is refused instead of
// silently ignored.
func (o Options) RejectStrayPositionals(hint string) error {
	if len(o.Positionals) == 0 {
		return nil
	}
	if hint == "" {
		return usage(fmt.Sprintf("unexpected argument '%s'", o.Positionals[0]))
	}
	return usage(fmt.Sprintf("unexpected argument '%s' — use: %s", o.Positionals[0], hint))
}
