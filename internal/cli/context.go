package cli

import (
	"fmt"
	"io"

	"dit/internal/config"
	"dit/internal/model"
	"dit/internal/store"
)

// Exit codes, unchanged from the Swift CLI: 0 success, 1 runtime error,
// 2 usage error. Scripts and agents branch on these.
const (
	exitOK      = 0
	exitRuntime = 1
	exitUsage   = 2
)

// UsageError is a wrong request: bad option, missing argument, unknown
// subcommand. It exits 2 and never touches a store.
type UsageError struct{ Message string }

func (e UsageError) Error() string { return e.Message }

// RuntimeError is a right request that could not be carried out: no such
// account, a store that cannot be read, a quote that cannot be fetched. It
// exits 1.
type RuntimeError struct{ Message string }

func (e RuntimeError) Error() string { return e.Message }

func usage(message string) error { return UsageError{Message: message} }

// Runtime is the constructor commands reach for when a request is well formed
// but the data says no.
func Runtime(message string) error { return RuntimeError{Message: message} }

// Context is what a command gets: where the stores are, the global flags, and
// somewhere to write. Everything a command needs is either in here or in its
// arguments; nothing is hidden in a package-level mutable state.
type Context struct {
	Layout  config.Layout
	Version string
	JSON    bool
	Offline bool
	Display model.Currency
	// DisplaySet records whether --display was given explicitly. A command
	// that defaults to something other than the global display (account show
	// reports in the account's own currency) uses this to tell "no --display"
	// from "--display CAD" when CAD happens to be the default too.
	DisplaySet bool
	Out        io.Writer
	Err        io.Writer
}

// Stores opens both documents' backing stores.
//
// A failure here is a runtime error, not a usage error: the user asked for
// something reasonable and the machine could not provide it.
func (c Context) Stores() (ledger store.Store, market store.Store, err error) {
	if c.Layout.Backend == config.SQLite {
		ledger, err = store.NewSQLiteStore(c.Layout.PortfolioDir)
		if err != nil {
			return store.Store{}, store.Store{}, err
		}
		market, err = store.NewSQLiteStore(c.Layout.MarketDir)
		if err != nil {
			return store.Store{}, store.Store{}, err
		}
		return ledger, market, nil
	}
	ledger, err = store.NewFileStore(c.Layout.PortfolioDir)
	if err != nil {
		return store.Store{}, store.Store{}, err
	}
	market, err = store.NewFileStore(c.Layout.MarketDir)
	if err != nil {
		return store.Store{}, store.Store{}, err
	}
	return ledger, market, nil
}

// Ledger loads the ledger document (nil when nothing has been recorded).
func (c Context) Ledger() (*model.Portfolio, error) {
	ledger, _, err := c.Stores()
	if err != nil {
		return nil, err
	}
	return store.LoadPortfolio(ledger)
}

// LedgerAndMarket loads both documents at once, which is what anything that
// prices a portfolio needs.
func (c Context) LedgerAndMarket() (*model.Portfolio, model.MarketData, error) {
	ledger, market, err := c.Stores()
	if err != nil {
		return nil, model.MarketData{}, err
	}
	portfolio, err := store.LoadPortfolio(ledger)
	if err != nil {
		return nil, model.MarketData{}, err
	}
	return portfolio, store.LoadMarket(market), nil
}

func (c Context) PortfolioLocation() string {
	if c.Layout.PortfolioLocation != "" {
		return c.Layout.PortfolioLocation
	}
	return c.Layout.PortfolioDir
}

func (c Context) MarketLocation() string {
	if c.Layout.MarketLocation != "" {
		return c.Layout.MarketLocation
	}
	return c.Layout.MarketDir
}

func (c Context) printf(format string, arguments ...any) {
	fmt.Fprintf(c.Out, format, arguments...)
}

// errorEnvelope is the machine-mode error shape: the same document whether the
// failure was a usage error or a runtime one, distinguished by "kind".
//
// One parse path matters more than a pretty message: a caller that asked for
// JSON must never receive prose, or its parser dies on the one response where
// it most needs to know what happened.
func (c Context) errorEnvelope(kind, message string) {
	c.WriteJSONFailure(kind, message)
}

type confirmationRefusal string

func (e confirmationRefusal) Error() string { return string(e) }

// Report turns a command's error into output and an exit code.
func (c Context) Report(err error, help string) int {
	switch failure := err.(type) {
	case confirmationRefusal:
		fmt.Fprintln(c.Err, failure)
		return exitRuntime
	case UsageError:
		if c.JSON {
			c.WriteJSONFailure("usage", failure.Message)
		} else {
			fmt.Fprintln(c.Err, "error:", failure.Message)
			if help != "" {
				fmt.Fprintln(c.Err, help)
			}
		}
		return exitUsage
	case RuntimeError:
		if c.JSON {
			c.WriteJSONFailure("runtime", failure.Message)
		} else {
			fmt.Fprintln(c.Err, "error:", failure.Message)
		}
		return exitRuntime
	default:
		message := err.Error()
		if c.JSON {
			c.WriteJSONFailure("runtime", message)
		} else {
			fmt.Fprintln(c.Err, "error:", message)
		}
		return exitRuntime
	}
}
