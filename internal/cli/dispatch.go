package cli

import (
	"fmt"
	"strings"
)

// Dispatch routes one invocation: find the command, check its options, run it,
// and turn a failure into the right exit code.
//
// Three things are enforced here rather than inside the commands, because they
// are easy to forget one command at a time:
//
//   - an unported command says so instead of printing something plausible;
//   - --json is refused where no schema exists, so a caller that asked for
//     machine output is never handed prose;
//   - an unknown option is a usage error before any store is opened.
func Dispatch(context Context, arguments []string) int {
	registry := commandSpecs()

	// -h/--help is global and answers BEFORE command resolution, option parsing,
	// and even --json (the Swift binary does exactly that; `dit --json --help`
	// prints plain help and exits 0). `dit help …` goes through the next branch
	// as a normal command, including the --json allowlist.
	if resolveHelp(context, arguments) {
		return 0
	}

	// `dit help [topic]`: the first topic word picks the screen, later words are
	// dropped (`help account show` prints the account GROUP screen, exactly as
	// the Swift binary does); a missing topic is the "usage" screen — the Swift
	// default case, which is NOT the same text as the main `dit --help` screen
	// (the two differ in line-wrapping; both are preserved byte-for-byte).
	{
		group, sub, _ := SplitCommandWords(arguments)
		if group == "help" {
			if context.JSON {
				label := "help"
				if sub != "" && !strings.HasPrefix(sub, "-") {
					label += " " + sub
				}
				return context.Report(usage(fmt.Sprintf(
					"--json is not supported for '%s' — documented schemas: summary, accounts, "+
						"account show, quote, pnl, market coverage (see docs/json.md)", label)), "")
			}
			topic := sub
			if strings.HasPrefix(topic, "-") || topic == "" {
				topic = "usage"
			}
			context.printf("%s\n", helpTextFor(strings.ToLower(topic), ""))
			return 0
		}
	}

	group, sub, rest := SplitCommandWords(arguments)
	// The lower-cased sub is fine for picking a command but not for passing
	// back as data: ids and symbols arrive in whatever case the user typed.
	rawSub := ""
	if len(arguments) >= 2 && !strings.HasPrefix(arguments[1], "-") {
		rawSub = arguments[1]
	}
	name, spec, rest := resolve(registry, group, sub, rawSub, rest)
	if spec != nil && spec.HelpText == "" {
		copy := *spec
		copy.HelpText = commandHelp(name)
		if copy.HelpText == "" {
			parts := strings.SplitN(name, " ", 2)
			group, sub := parts[0], ""
			if len(parts) == 2 {
				sub = parts[1]
			}
			copy.HelpText = helpTextFor(group, sub)
		}
		spec = &copy
	}
	if spec == nil {
		if isCommandGroup(group) && sub != "" {
			message, help := unknownSubcommand(group, sub)
			return context.Report(usage(message), help)
		}
		reported := strings.TrimSpace(group + " " + sub)
		return context.Report(usage(
			fmt.Sprintf("unknown command '%s' — run 'dit help' for usage", reported)), helpTextFor("", ""))
	}
	if context.JSON && !jsonIsDocumented(name) {
		label := strings.TrimSpace(name)
		if label == "" {
			label = "this command"
		}
		return context.Report(usage(fmt.Sprintf(
			"--json is not supported for '%s' — documented schemas: summary, accounts, "+
				"account show, quote, pnl, market coverage (see docs/json.md)", label)), "")
	}
	if spec.Run == nil {
		label := strings.TrimSpace(name)
		if label == "" {
			label = "summary"
		}
		return context.Report(Runtime(fmt.Sprintf(
			"%s is not ported to Go yet — this build implements: accounts, store path, "+
				"tx list, tx show, summary, market show, market coverage", label)), "")
	}

	if !spec.SkipParse {
		if _, err := spec.ParseFor(rest); err != nil {
			return context.Report(err, spec.HelpText)
		}
	}
	// A saved connection means every result below comes from another machine;
	// the banner says so before the first line of output. Commands that manage
	// the connection (or the local stores only) name their own target.
	if context.Layout.RemoteTarget != "" && !remoteBannerExcluded(name) {
		context.printRemoteBanner()
	}
	if err := spec.Run(context, rest); err != nil {
		if _, refused := err.(coverageStrictJSON); refused {
			// The coverage document is already on stdout, "complete": false
			// included. A second document would break one-answer-per-call.
			return exitRuntime
		}
		return context.Report(err, spec.HelpText)
	}
	return 0
}

// resolve picks the Spec, including the two argument shapes that a plain
// (group, sub) lookup cannot express:
//
//   - `dit tx 8E13D4B1` is the documented shortcut for `tx show`. The id
//     arrives where a subcommand word would be, so it has to be handed back
//     to the command as an argument or the command never sees it.
//   - a bare `dit tx` / `dit transaction` means the list view.
func resolve(registry Registry, group, sub, rawSub string, rest []string) (string, *Spec, []string) {
	if group == "store" && sub == "" {
		if spec, found := registry["store path"]; found {
			return "store path", spec, rest
		}
	}
	if group == "market" && sub == "" {
		if spec, found := registry["market latest"]; found {
			return "market latest", spec, rest
		}
	}
	if (group == "tx" || group == "transaction") && looksLikeTransactionID(sub) {
		if spec, found := registry["tx show"]; found {
			return "tx show", spec, append([]string{rawSub}, rest...)
		}
	}
	if (group == "tx" || group == "transaction") && sub == "" {
		if spec, found := registry["tx list"]; found {
			return "tx list", spec, rest
		}
	}
	if group == "quote" && sub != "" && !strings.HasPrefix(sub, "-") {
		if spec, found := registry["quote"]; found {
			return "quote", spec, append([]string{rawSub}, rest...)
		}
	}
	if isCommandGroup(group) && sub != "" && !knownSubcommand(registry, group, sub) {
		return "", nil, rest
	}
	name, spec := registry.Lookup(group, sub)
	return name, spec, rest
}

// knownSubcommand prevents a group's default action from swallowing an
// unknown subcommand (notably `ticker nope` becoming `ticker list`).
func knownSubcommand(registry Registry, group, sub string) bool {
	if group == "transaction" {
		group = "tx"
	}
	_, ok := registry[group+" "+sub]
	return ok
}

func isCommandGroup(group string) bool {
	switch group {
	case "account", "transaction", "tx", "ticker", "store", "market", "config":
		return true
	}
	return false
}

func unknownSubcommand(group, sub string) (string, string) {
	help := helpTextFor(group, sub)
	switch group {
	case "account":
		return fmt.Sprintf("unknown account subcommand '%s' — use list, show, add, edit, close, or delete", sub), help
	case "tx", "transaction":
		return fmt.Sprintf("unknown tx subcommand '%s' — see 'dit help tx'", sub), help
	case "store":
		return fmt.Sprintf("unknown store subcommand '%s' — use path, export, backup, or import", sub), help
	case "ticker":
		return fmt.Sprintf("unknown ticker subcommand '%s' — use list, show, add, edit, or delete", sub), help
	case "market":
		return fmt.Sprintf("unknown market subcommand '%s' — use latest, history, backfill, import, coverage, or show (see 'dit help market')", sub), help
	case "config":
		return fmt.Sprintf("unknown config subcommand '%s' — use set (see 'dit help config')", sub), help
	}
	return fmt.Sprintf("unknown command '%s %s' — run 'dit help' for usage", group, sub), help
}

// looksLikeTransactionID recognises a bare transaction reference: eight or
// more hex characters. Eight is the documented shortcut length; the explicit
// `tx show` accepts shorter unique prefixes, which is why this is about
// routing a *word* and not about matching an id.
func looksLikeTransactionID(word string) bool {
	if len(word) < 8 {
		return false
	}
	for _, character := range word {
		switch {
		case character >= '0' && character <= '9':
		case character >= 'a' && character <= 'f':
		case character >= 'A' && character <= 'F':
		default:
			return false
		}
	}
	return true
}

// jsonIsDocumented mirrors the Swift CLI's allowlist: --json exists where a
// schema exists, and is a usage error everywhere else.
func jsonIsDocumented(name string) bool {
	switch name {
	case "", "summary", "accounts", "account list", "account show", "quote", "pnl", "income", "market coverage":
		return true
	}
	return false
}
