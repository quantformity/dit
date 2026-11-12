package cli

import "strings"

// Help screens and the `dit help` command. The texts live in help_text.go
// (transcribed from the Swift source); this file is only the wiring.

func wantsHelp(words []string) bool {
	for _, w := range words {
		if w == "-h" || w == "--help" {
			return true
		}
	}
	return false
}

func hasFlag(word string) bool { return strings.HasPrefix(word, "-") }

const configCommandHelpLine = "  dit config <sub> [args]    read and update user config (see: dit config --help)"
const backupCommandHelpLines = "  dit backup                 timestamped backup of portfolio + market data\n  dit rollback <stamp>|--list restore or list timestamped backups"
const networkCommandHelpLines = "  dit serve [PORT]             serve this portfolio to the network (see: dit serve --help)\n  dit clone [HOST:PORT]        pull a remote portfolio into the local stores\n  dit connect [HOST:PORT]      run commands against a remote portfolio\n  dit disconnect               stop using the connected remote\n  dit self-update [--check]    install the latest dit release (GitHub) over this binary"

// withConfigCommand splices the commands that post-date the Swift help screen
// (config, backup/rollback, and the network commands) into a usage body.
func withConfigCommand(body string) string {
	anchor := "  dit store <sub> [args]     path / export / backup / import (see: dit store --help)"
	return strings.Replace(body, anchor, anchor+"\n"+configCommandHelpLine+"\n"+backupCommandHelpLines+"\n"+networkCommandHelpLines, 1)
}

// MainUsageText is the short top-level usage footer used for parse errors.
func MainUsageText() string { return withConfigCommand(helpBody16) }

// GlobalParseUsageText is the usage screen Swift emits when its global
// argument scanner rejects a value before dispatch.
func GlobalParseUsageText() string { return helpBody2 }

// UsageTextForArgs chooses the same usage screen Swift would show when a
// global-option parser fails before dispatching the command.
func UsageTextForArgs(arguments []string) string {
	group, sub, _ := SplitCommandWords(arguments)
	return helpTextFor(group, sub)
}

// resolveHelp answers a -h/--help invocation: the help screen for the command
// it was pointed at (group + first subcommand word; a flag is not a sub),
// with the Swift default-case fallback (unknown → main usage, exit 0).
func resolveHelp(context Context, arguments []string) bool {
	if !wantsHelp(arguments) {
		return false
	}
	group, sub := "", ""
	if len(arguments) >= 1 && arguments[0] != "" && !hasFlag(arguments[0]) {
		group = arguments[0]
	}
	if len(arguments) >= 2 && !hasFlag(arguments[1]) {
		sub = arguments[1]
	}
	if group == "help" {
		group, sub = "help", "" // Swift: no ("help", …) case → short help command screen
	}
	if group == "" {
		context.printf("%s\n", withConfigCommand(helpBody1))
	} else {
		context.printf("%s\n", helpTextFor(strings.ToLower(group), strings.ToLower(sub)))
	}
	return true
}
