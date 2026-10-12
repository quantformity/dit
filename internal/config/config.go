// Package config resolves where the two stores live.
//
// Precedence is flags > environment > defaults, and the rules are shared by
// every command so a store can be moved with one flag. The defaults keep the
// Swift implementation's layout, which is what lets either binary read a store
// the other one wrote.
package config

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Backend names the persistence flavour.
type Backend string

const (
	// File keeps one JSON document per key inside a directory.
	File Backend = "file"
	// SQLite keeps the same JSON payloads as BLOBs in one database.
	SQLite Backend = "sqlite"
)

// Environment variable names, shared with the Swift implementation.
const (
	BackendEnvKey    = "DIT_BACKEND"
	StoreURLEnvKey   = "DIT_STORE_URL"
	MarketURLEnvKey  = "DIT_MARKET_URL"
	defaultStoreName = "dit"
	legacyStoreName  = "DirectInvestTracker"
)

// Layout is a resolved pair of store locations.
type Layout struct {
	Backend Backend
	// PortfolioLocation and MarketLocation retain the resolved user-facing
	// locations; SQLite's database filenames live in the corresponding Dir fields.
	PortfolioLocation string
	MarketLocation    string
	// PortfolioDir is the directory (file backend) or database file
	// (sqlite backend) holding the ledger document.
	PortfolioDir string
	// MarketDir is the matching location for price data.
	MarketDir string
}

// Resolve reads the environment and the flags.
//
// `flagBackend`, `flagStore` and `flagMarket` are the --backend/--store/
// --market-store values, empty when not given.
func Resolve(environment map[string]string, flagBackend, flagStore, flagMarket string) (Layout, error) {
	if environment == nil {
		environment = map[string]string{
			BackendEnvKey:   os.Getenv(BackendEnvKey),
			StoreURLEnvKey:  os.Getenv(StoreURLEnvKey),
			MarketURLEnvKey: os.Getenv(MarketURLEnvKey),
		}
	}
	backend := strings.TrimSpace(environment[BackendEnvKey])
	if flagBackend != "" {
		backend = flagBackend
	}
	if backend == "" {
		backend = string(File)
	}
	switch strings.ToLower(backend) {
	case "file":
		backend = string(File)
	case "sqlite":
		backend = string(SQLite)
	default:
		return Layout{}, fmt.Errorf(`configuration(message: "Unknown %s value \'%s\' (expected: file, sqlite)")`,
			BackendEnvKey, strings.ToLower(backend))
	}

	store := firstNonEmpty(flagStore, environment[StoreURLEnvKey])
	portfolio := strings.TrimSpace(store)
	if portfolio == "" {
		portfolio = defaultStoreDirectory()
	}

	market := strings.TrimSpace(firstNonEmpty(flagMarket, environment[MarketURLEnvKey]))
	if market == "" {
		market = defaultMarketLocation(portfolio, Backend(backend))
	}
	portfolio = absoluteLocation(portfolio)
	market = absoluteLocation(market)
	portfolioLocation, marketLocation := portfolio, market
	if Backend(backend) == SQLite {
		portfolio = sqliteFile(portfolio, "portfolio.sqlite")
		market = sqliteFile(market, "market.sqlite")
	}
	return Layout{Backend: Backend(backend), PortfolioDir: portfolio, MarketDir: market,
		PortfolioLocation: portfolioLocation, MarketLocation: marketLocation}, nil
}

func absoluteLocation(location string) string {
	absolute, err := filepath.Abs(location)
	if err != nil {
		return filepath.Clean(location)
	}
	return absolute
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

// defaultStoreDirectory returns ~/Library/Application Support/dit, honouring
// the pre-rename DirectInvestTracker folder when only that exists, so an
// existing store keeps working after the rename. When both exist, `dit` wins.
func defaultStoreDirectory() string {
	home, err := os.UserHomeDir()
	if err != nil {
		home = "."
	}
	base := filepath.Join(home, "Library", "Application Support")
	current := filepath.Join(base, defaultStoreName)
	if info, err := os.Stat(current); err == nil && info.IsDir() {
		return current
	}
	legacy := filepath.Join(base, legacyStoreName)
	if info, err := os.Stat(legacy); err == nil && info.IsDir() {
		return legacy
	}
	return current
}

// defaultMarketLocation puts the price store beside the ledger: a `market`
// directory inside the portfolio directory, or `market.sqlite` beside
// `portfolio.sqlite`. Pointing the portfolio store somewhere new therefore
// isolates market data automatically, and one backup covers a predictable
// pair of locations.
func defaultMarketLocation(portfolio string, backend Backend) string {
	if backend == SQLite {
		directory := filepath.Dir(portfolio)
		base := filepath.Base(portfolio)
		if info, err := os.Stat(portfolio); err == nil && !info.IsDir() &&
			strings.HasSuffix(strings.ToLower(base), ".sqlite") {
			return filepath.Join(directory, "market.sqlite")
		}
		if info, err := os.Stat(portfolio); err == nil && info.IsDir() {
			return filepath.Join(portfolio, "market.sqlite")
		}
		return filepath.Join(directory, "market.sqlite")
	}
	return filepath.Join(portfolio, "market")
}

// sqliteFile interprets a location as the place holding a database: an
// existing directory contains the named file, anything else is the file
// itself.
func sqliteFile(location, fileName string) string {
	if info, err := os.Stat(location); err == nil && info.IsDir() {
		return filepath.Join(location, fileName)
	}
	return location
}
