package cli

// The command table. Every command the Swift CLI has is listed here, with the
// options it declares, whether the Go port has implemented it, and what help
// it owes the user.
//
// The table is complete on purpose. `dit summary` on an unported build must
// say "not ported", not print a plausible-looking table: a wrong number in a
// portfolio tool is worse than no number, and "no output" would be read as an
// empty portfolio.
//
// Option names come from the Swift sources; they are copied rather than
// invented because the end-to-end suite drives the same commands and asserts
// on their failures.

// commandSpecs is the whole surface. Implementations live in the file for
// their own command group; a nil Run means "known, not ported".
func commandSpecs() Registry {
	registry := Registry{}
	register := func(name string, spec *Spec) {
		registry[name] = spec
	}

	// Reading the portfolio.
	register("", &Spec{})
	register("summary", &Spec{SkipParse: true})
	register("accounts", &Spec{Run: accountsListing, SkipParse: true})
	register("pnl", &Spec{})

	// Accounts.
	register("account list", &Spec{Run: accountsListing, SkipParse: true})
	register("account show", &Spec{})
	register("account add", &Spec{
		ValueOptions: setOf("name", "currency", "institution", "number", "opened", "closed", "notes", "taxable"),
		FlagOptions:  setOf("taxable", "non-taxable"),
	})
	register("account edit", &Spec{})
	register("account close", &Spec{})
	register("account delete", &Spec{})

	// The transaction log.
	register("tx list", &Spec{})
	register("tx show", &Spec{})
	register("tx deposit", &Spec{})
	register("tx withdraw", &Spec{})
	register("tx buy", &Spec{})
	register("tx sell", &Spec{})
	register("tx dividend", &Spec{})
	register("tx gic", &Spec{})
	register("tx gic-redeem", &Spec{})
	register("tx fx", &Spec{})
	register("tx edit", &Spec{})
	register("tx delete", &Spec{})

	// The instrument registry.
	register("ticker", &Spec{})
	register("ticker list", &Spec{})
	register("ticker show", &Spec{})
	register("ticker add", &Spec{})
	register("ticker edit", &Spec{})
	register("ticker delete", &Spec{})

	// Moving data: one account's ledger.
	register("store path", &Spec{Run: storePath, SkipParse: true})
	register("store export", &Spec{})
	register("store backup", &Spec{})
	register("store import", &Spec{})

	// Moving data: the whole portfolio plus prices.
	register("export", &Spec{})
	register("import", &Spec{})

	// Market data.
	register("quote", &Spec{})
	register("market latest", &Spec{})
	register("market history", &Spec{})
	register("market backfill", &Spec{})
	register("market show", &Spec{})
	register("market coverage", &Spec{})
	register("market import", &Spec{})
	register("update", &Spec{})

	// Help.
	register("help", &Spec{})

	// Lane registries last, so a real implementation always beats the
	// placeholder above it. Placeholders stay: they are how an unported
	// command announces itself instead of falling through to a wrong answer.
	return mergeLayers(registry, summarySpecs, txListSpecs, marketSpecs, transferSpecs, txWriteSpecs, pnlSpecs, acctmgktSpecs, quoteSpecs)
}

func setOf(names ...string) map[string]bool {
	options := make(map[string]bool, len(names))
	for _, name := range names {
		options[name] = true
	}
	return options
}
