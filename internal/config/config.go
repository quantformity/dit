// Package config resolves where the two stores live.
//
// Precedence is flags > environment > ~/.dit/config.json > defaults, and the rules are shared by
// every command so a store can be moved with one flag. The defaults keep the
// Swift implementation's layout, which is what lets either binary read a store
// the other one wrote.
package config

import (
	"encoding/json"
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
	BackendEnvKey     = "DIT_BACKEND"
	StoreURLEnvKey    = "DIT_STORE_URL"
	MarketURLEnvKey   = "DIT_MARKET_URL"
	RemoteURLEnvKey   = "DIT_REMOTE_URL"
	RemoteTokenEnvKey = "DIT_REMOTE_TOKEN"
	RemoteReadOnlyKey = "DIT_REMOTE_READONLY"
	defaultStoreName  = "dit"
	legacyStoreName   = "DirectInvestTracker"
	configFileName    = "config.json"
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
	// RemoteTarget is a saved `dit connect` address (host:port). When set,
	// commands run against the remote portfolio instead of the local stores.
	RemoteTarget string
	// RemoteToken authenticates to that server. Empty means open access.
	RemoteToken string
	// RemoteReadOnly records the server's --immutable setting at connect time.
	RemoteReadOnly bool
}

// Resolve reads the environment, user config and flags. A missing user config
// is initialized at ~/.dit/config.json with the default portfolio document.
//
// `flagBackend`, `flagStore` and `flagMarket` are the --backend/--store/
// --market-store values, empty when not given.
func Resolve(environment map[string]string, flagBackend, flagStore, flagMarket string) (Layout, error) {
	fileConfig := userConfig{}
	if environment == nil {
		var err error
		environment = map[string]string{
			BackendEnvKey:   os.Getenv(BackendEnvKey),
			StoreURLEnvKey:  os.Getenv(StoreURLEnvKey),
			MarketURLEnvKey: os.Getenv(MarketURLEnvKey),
		}
		fileConfig, err = loadOrCreateUserConfig()
		if err != nil {
			return Layout{}, err
		}
	}
	backend := strings.TrimSpace(environment[BackendEnvKey])
	if backend == "" {
		backend = strings.TrimSpace(fileConfig.Backend)
	}
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

	store := firstNonEmpty(flagStore, environment[StoreURLEnvKey], fileConfig.StoreURL)
	portfolio := expandHome(strings.TrimSpace(store))
	if portfolio == "" {
		portfolio = defaultPortfolioFile()
	}

	market := expandHome(strings.TrimSpace(firstNonEmpty(flagMarket, environment[MarketURLEnvKey], fileConfig.MarketURL)))
	if market == "" {
		market = defaultMarketLocation(portfolio, Backend(backend))
	}
	portfolio = absoluteLocation(portfolio)
	market = absoluteLocation(market)
	portfolioLocation, marketLocation := portfolio, market
	if Backend(backend) == SQLite {
		portfolio = sqliteFile(portfolio, "portfolio.sqlite")
		market = sqliteFile(market, "market.sqlite")
	} else {
		portfolio = fileStoreDirectory(portfolio, "portfolio.dat")
		market = fileStoreDirectory(market, "market.dat")
	}
	layout := Layout{Backend: Backend(backend), PortfolioDir: portfolio, MarketDir: market,
		PortfolioLocation: portfolioLocation, MarketLocation: marketLocation}
	layout.RemoteTarget = strings.TrimSpace(firstNonEmpty(environment[RemoteURLEnvKey], fileConfig.RemoteURL))
	layout.RemoteToken = strings.TrimSpace(firstNonEmpty(environment[RemoteTokenEnvKey], fileConfig.RemoteToken))
	layout.RemoteReadOnly = strings.EqualFold(strings.TrimSpace(firstNonEmpty(environment[RemoteReadOnlyKey], fileConfig.RemoteReadOnly)), "true")
	return layout, nil
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

type userConfig struct {
	Backend        string `json:"DIT_BACKEND,omitempty"`
	StoreURL       string `json:"DIT_STORE_URL,omitempty"`
	MarketURL      string `json:"DIT_MARKET_URL,omitempty"`
	RemoteURL      string `json:"DIT_REMOTE_URL,omitempty"`
	RemoteToken    string `json:"DIT_REMOTE_TOKEN,omitempty"`
	RemoteReadOnly string `json:"DIT_REMOTE_READONLY,omitempty"`
}

func homeDirectory() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return "."
	}
	return home
}

func defaultPortfolioFile() string {
	return filepath.Join(homeDirectory(), ".dit", "portfolio.dat")
}

func expandHome(path string) string {
	if path == "~" {
		return homeDirectory()
	}
	if strings.HasPrefix(path, "~/") {
		return filepath.Join(homeDirectory(), path[2:])
	}
	return path
}

func loadOrCreateUserConfig() (userConfig, error) {
	home := homeDirectory()
	directory := filepath.Join(home, ".dit")
	path := filepath.Join(directory, configFileName)
	read := func() (userConfig, error) {
		data, err := os.ReadFile(path)
		if err != nil {
			return userConfig{}, err
		}
		var cfg userConfig
		if err := json.Unmarshal(data, &cfg); err != nil {
			return userConfig{}, fmt.Errorf("invalid config file %s: %w", path, err)
		}
		return cfg, nil
	}
	cfg, err := read()
	if err == nil {
		return cfg, nil
	}
	if !os.IsNotExist(err) {
		return userConfig{}, err
	}
	cfg = userConfig{StoreURL: "~/.dit/portfolio.dat", MarketURL: "~/.dit/market.dat"}
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return userConfig{}, fmt.Errorf("cannot create config directory %s: %w", directory, err)
	}
	if err := migrateLegacyStore(home, directory); err != nil {
		return userConfig{}, err
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return userConfig{}, err
	}
	data = append(data, '\n')
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if os.IsExist(err) { // Another dit process initialized it first.
		return read()
	}
	if err != nil {
		return userConfig{}, fmt.Errorf("cannot create config file %s: %w", path, err)
	}
	if _, err := file.Write(data); err != nil {
		file.Close()
		os.Remove(path)
		return userConfig{}, fmt.Errorf("cannot write config file %s: %w", path, err)
	}
	if err := file.Close(); err != nil {
		return userConfig{}, fmt.Errorf("cannot close config file %s: %w", path, err)
	}
	return cfg, nil
}

// SetUserPath updates one configured store URL without altering the other.
// Relative paths are resolved from the current working directory before save.
func SetUserPath(key, value string) error {
	value = strings.TrimSpace(value)
	if value == "" {
		return fmt.Errorf("store path cannot be empty")
	}
	cfg, err := loadOrCreateUserConfig()
	if err != nil {
		return err
	}
	path := expandHome(value)
	if !filepath.IsAbs(path) {
		path, err = filepath.Abs(path)
		if err != nil {
			return err
		}
	}
	// Keep a home-relative spelling when the user explicitly used `~`, so the
	// config remains portable to another machine with the same synced layout.
	if strings.HasPrefix(value, "~/") {
		path = "~" + string(filepath.Separator) + filepath.Clean(value[2:])
	}
	switch key {
	case StoreURLEnvKey:
		cfg.StoreURL = path
	case MarketURLEnvKey:
		cfg.MarketURL = path
	default:
		return fmt.Errorf("unsupported config key %q", key)
	}
	return writeUserConfig(cfg)
}

func writeUserConfig(cfg userConfig) error {
	directory := filepath.Join(homeDirectory(), ".dit")
	path := filepath.Join(directory, configFileName)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return fmt.Errorf("cannot create config directory %s: %w", directory, err)
	}
	data, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	file, err := os.CreateTemp(directory, ".config-*.tmp")
	if err != nil {
		return fmt.Errorf("cannot write config file %s: %w", path, err)
	}
	temporary := file.Name()
	defer os.Remove(temporary)
	if err := file.Chmod(0o600); err != nil {
		file.Close()
		return err
	}
	if _, err := file.Write(data); err != nil {
		file.Close()
		return fmt.Errorf("cannot write config file %s: %w", path, err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("cannot close config file %s: %w", path, err)
	}
	if err := os.Rename(temporary, path); err != nil {
		return fmt.Errorf("cannot update config file %s: %w", path, err)
	}
	return nil
}

// migrateLegacyStore copies the old default documents once, preserving the
// originals. It never overwrites a file already present in ~/.dit.
func migrateLegacyStore(home, target string) error {
	base := filepath.Join(home, "Library", "Application Support")
	source := filepath.Join(base, defaultStoreName)
	if info, err := os.Stat(source); err != nil || !info.IsDir() {
		source = filepath.Join(base, legacyStoreName)
	}
	for _, pair := range [][2]string{
		{filepath.Join(source, "portfolio.dat"), filepath.Join(target, "portfolio.dat")},
		{filepath.Join(source, "market", "market.dat"), filepath.Join(target, "market.dat")},
	} {
		data, err := os.ReadFile(pair[0])
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return fmt.Errorf("cannot read legacy store document %s: %w", pair[0], err)
		}
		file, err := os.OpenFile(pair[1], os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if os.IsExist(err) {
			continue
		}
		if err != nil {
			return fmt.Errorf("cannot migrate store document to %s: %w", pair[1], err)
		}
		if _, err := file.Write(data); err != nil {
			file.Close()
			os.Remove(pair[1])
			return fmt.Errorf("cannot migrate store document to %s: %w", pair[1], err)
		}
		if err := file.Close(); err != nil {
			return fmt.Errorf("cannot close migrated document %s: %w", pair[1], err)
		}
	}
	return nil
}

// defaultMarketLocation keeps the default JSON documents side by side. A
// file-backend URL ending in portfolio.dat implies sibling market.dat; folder
// URLs retain the historical nested market directory. SQLite uses a sibling
// market.sqlite file.
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
	if filepath.Base(portfolio) == "portfolio.dat" {
		return filepath.Join(filepath.Dir(portfolio), "market.dat")
	}
	return filepath.Join(portfolio, "market")
}

func fileStoreDirectory(location, documentName string) string {
	if filepath.Base(location) == documentName {
		return filepath.Dir(location)
	}
	return location
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
