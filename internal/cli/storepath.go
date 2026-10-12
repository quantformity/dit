package cli

import (
	"fmt"
	"strings"

	"dit/internal/store"
)

// storePath reports where the two stores live and what is in them.
//
// It exists so "where is my data" is one command, and so a bug report can
// start by pasting it. Both stores are shown because they are genuinely two
// places: a store with no prices prices nothing, and the answer to "why is my
// P&L dashed" usually lives in the second line.
func storePath(context Context, arguments []string) error {
	// The Swift `store path` command ignores trailing arguments and options.
	ledger, _, err := context.Stores()
	if err != nil {
		return err
	}
	portfolio, err := store.LoadPortfolio(ledger)
	if err != nil {
		return err
	}
	body := []string{
		"Backend:  " + string(context.Layout.Backend) + " (flags > DIT_BACKEND > default)",
		"Location: " + context.PortfolioLocation(),
	}
	if portfolio != nil {
		body = append(body, fmt.Sprintf(
			"Document: present — %d account(s), %d transaction(s), %d ticker(s) registered",
			len(portfolio.Accounts), len(portfolio.Transactions), len(portfolio.Tickers)))
	} else {
		body = append(body, "Document: empty (no portfolio recorded yet)")
	}
	if keys := ledger.KeysOrEmpty(); len(keys) > 0 {
		body = append(body, "Keys: "+strings.Join(keys, ", "))
	}
	context.printf("Store configuration:\n")
	for _, line := range body {
		context.printf("  %s\n", line)
	}
	return nil
}
