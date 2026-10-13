package cli

import (
	"fmt"
	"strings"

	"dit/internal/config"
)

const configSetHelp = `USAGE: dit config set <store|market> <PATH>

  Update a store path in ~/.dit/config.json. Paths may be absolute,
  relative to the current directory, or begin with ~. File-backend
  paths may name the portfolio.dat / market.dat document directly.

  Examples:
    dit config set store ~/Sync/dit/portfolio.dat
    dit config set market ~/Sync/dit/market.dat

  Environment variables and command-line flags override these values.`

var configSpecs = Registry{
	"config set": {Run: configSet, SkipParse: true, HelpText: configSetHelp},
}

func configSet(c Context, args []string) error {
	if len(args) != 2 {
		return usage("usage: dit config set <store|market> <PATH>")
	}
	key := ""
	switch strings.ToLower(args[0]) {
	case "store", "portfolio", "store-url", "dit_store_url":
		key = config.StoreURLEnvKey
	case "market", "market-url", "dit_market_url":
		key = config.MarketURLEnvKey
	default:
		return usage(fmt.Sprintf("unknown config key %q — use store or market", args[0]))
	}
	if strings.TrimSpace(args[1]) == "" {
		return usage("config path cannot be empty")
	}
	if err := config.SetUserPath(key, args[1]); err != nil {
		return Runtime(err.Error())
	}
	c.printf("Updated %s in ~/.dit/config.json. The new path applies to the next command.\n", key)
	return nil
}
