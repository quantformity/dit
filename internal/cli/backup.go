package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"dit/internal/bundle"
	"dit/internal/decimal"
	"dit/internal/model"
	"dit/internal/store"
	"dit/internal/valuation"
)

const backupHelp = `USAGE: dit backup

  Save the current portfolio and market documents under
  ~/.dit/backup/portfolio.dat.YYYYMMDD.HHMMSS and
  ~/.dit/backup/market.dat.YYYYMMDD.HHMMSS, plus a metadata
  file with counts and offline cost-basis figures.`

const rollbackHelp = `USAGE: dit rollback <YYYYMMDD.HHMMSS> [--yes]
       dit rollback --list

  --list shows available paired backups. Restoring replaces the
  current portfolio and market documents after confirmation; pass
  --yes to confirm in a non-interactive run. Current data is backed
  up before restore.`

type backupPair struct {
	stamp                       string
	portfolio, market, metadata string
}

type backupMetadata struct {
	Schema           string                  `json:"schema"`
	DitVersion       string                  `json:"ditVersion"`
	BackupDate       string                  `json:"backupDate"`
	CreatedAt        string                  `json:"createdAt"`
	AccountCount     int                     `json:"accountCount"`
	TransactionCount int                     `json:"transactionCount"`
	TickerCount      int                     `json:"tickerCount"`
	Market           backupMarketMetadata    `json:"market"`
	Valuation        backupValuationMetadata `json:"valuation"`
}

type backupMarketMetadata struct {
	DailyCloseCount  int `json:"dailyCloseCount"`
	SeriesCount      int `json:"seriesCount"`
	LatestQuoteCount int `json:"latestQuoteCount"`
	FXRateCount      int `json:"fxRateCount"`
}

type backupValuationMetadata struct {
	Basis             string                   `json:"basis"`
	ReportingCurrency string                   `json:"reportingCurrency"`
	FXApplied         bool                     `json:"fxApplied"`
	Total             *string                  `json:"total"`
	Cash              *string                  `json:"cash"`
	Positions         *string                  `json:"positions"`
	GICs              *string                  `json:"gics"`
	RealizedPnl       *string                  `json:"realizedPnl"`
	UnrealizedPnl     *string                  `json:"unrealizedPnl"`
	Dividends         *string                  `json:"dividends"`
	ByCurrency        []backupCurrencyMetadata `json:"byCurrency"`
}

type backupCurrencyMetadata struct {
	Currency      string  `json:"currency"`
	Cash          string  `json:"cash"`
	Positions     string  `json:"positions"`
	GICs          string  `json:"gics"`
	Total         string  `json:"total"`
	RealizedPnl   string  `json:"realizedPnl"`
	UnrealizedPnl *string `json:"unrealizedPnl"`
	Dividends     string  `json:"dividends"`
}

func backupDirectory() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, ".dit", "backup"), nil
}

func backupPaths(directory, stamp string) backupPair {
	return backupPair{
		stamp:     stamp,
		portfolio: filepath.Join(directory, "portfolio.dat."+stamp),
		market:    filepath.Join(directory, "market.dat."+stamp),
		metadata:  filepath.Join(directory, "metadata.json."+stamp),
	}
}

func validBackupStamp(stamp string) bool {
	if len(stamp) != len("20060102.150405") || stamp[8] != '.' {
		return false
	}
	for i, r := range stamp {
		if i == 8 {
			continue
		}
		if r < '0' || r > '9' {
			return false
		}
	}
	_, err := time.ParseInLocation("20060102.150405", stamp, time.Local)
	return err == nil
}

func currentDocuments(c Context) ([]byte, []byte, error) {
	portfolio, err := transferRead(c, c.Layout.PortfolioDir, store.PortfolioKey)
	if err != nil {
		return nil, nil, err
	}
	if portfolio == nil {
		return nil, nil, Runtime("no portfolio document is present — nothing to back up")
	}
	if !json.Valid(portfolio) {
		return nil, nil, Runtime("the portfolio document is not valid JSON — refusing to back it up")
	}
	market, err := transferRead(c, c.Layout.MarketDir, store.MarketKey)
	if err != nil {
		return nil, nil, err
	}
	if market == nil {
		market, err = json.Marshal(store.EmptyMarket())
		if err != nil {
			return nil, nil, err
		}
	}
	if !json.Valid(market) {
		return nil, nil, Runtime("the market document is not valid JSON — refusing to back it up")
	}
	return portfolio, market, nil
}

// createBackup writes both documents atomically with respect to each filename;
// a failed second write removes the first so incomplete pairs are not exposed.
func createBackup(c Context, stamp string) (backupPair, error) {
	directory, err := backupDirectory()
	if err != nil {
		return backupPair{}, err
	}
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return backupPair{}, err
	}
	pair := backupPaths(directory, stamp)
	if _, err := os.Stat(pair.portfolio); err == nil {
		return backupPair{}, fmt.Errorf("backup %s already exists", stamp)
	}
	if _, err := os.Stat(pair.market); err == nil {
		return backupPair{}, fmt.Errorf("backup %s already exists", stamp)
	}
	if _, err := os.Stat(pair.metadata); err == nil {
		return backupPair{}, fmt.Errorf("backup %s already exists", stamp)
	}
	portfolio, market, err := currentDocuments(c)
	if err != nil {
		return backupPair{}, err
	}
	metadata, err := buildBackupMetadata(portfolio, market, stamp, c.Version)
	if err != nil {
		return backupPair{}, err
	}
	created := []string{}
	for _, file := range []struct {
		path string
		data []byte
	}{{pair.portfolio, portfolio}, {pair.market, market}, {pair.metadata, metadata}} {
		if err := atomicBackupFile(file.path, file.data); err != nil {
			for _, path := range created {
				_ = os.Remove(path)
			}
			return backupPair{}, err
		}
		created = append(created, file.path)
	}
	return pair, nil
}

func buildBackupMetadata(portfolioRaw, marketRaw []byte, stamp, ditVersion string) ([]byte, error) {
	portfolio, err := bundle.DecodePortfolio(portfolioRaw)
	if err != nil {
		return nil, fmt.Errorf("cannot create metadata from the portfolio: %w", err)
	}
	var market model.MarketData
	if err := json.Unmarshal(marketRaw, &market); err != nil {
		return nil, fmt.Errorf("cannot create metadata from the market data: %w", err)
	}
	now := time.Now()
	day := model.Day(model.DayStartUTC(now.Unix()))
	summary := valuation.CostSummary(&portfolio, model.CAD, day)
	if ditVersion == "" {
		ditVersion = "unknown"
	}
	metadata := backupMetadata{
		Schema:           "dit-backup-metadata/1",
		DitVersion:       ditVersion,
		BackupDate:       stamp,
		CreatedAt:        now.Format(time.RFC3339),
		AccountCount:     len(portfolio.Accounts),
		TransactionCount: len(portfolio.Transactions),
		TickerCount:      len(portfolio.Tickers),
		Market: backupMarketMetadata{
			DailyCloseCount:  market.TotalPoints(),
			SeriesCount:      len(market.Series),
			LatestQuoteCount: len(market.LatestQuotes),
			FXRateCount:      len(market.LatestRates),
		},
		Valuation: backupValuationMetadata{
			Basis:             "cost",
			ReportingCurrency: string(model.CAD),
			FXApplied:         false,
			Total:             decimalText(summary.Total),
			Cash:              decimalText(summary.Cash),
			Positions:         decimalText(summary.PositionValue),
			GICs:              decimalText(summary.GICValue),
			RealizedPnl:       decimalText(summary.Realized),
			UnrealizedPnl:     decimalText(summary.Unrealized),
			Dividends:         decimalText(summary.Dividends),
			ByCurrency:        backupCurrencyRows(summary),
		},
	}
	return json.MarshalIndent(metadata, "", "  ")
}

func decimalText(value *decimal.Decimal) *string {
	if value == nil {
		return nil
	}
	text := value.Fixed(2)
	return &text
}

func backupCurrencyRows(summary valuation.Summary) []backupCurrencyMetadata {
	currencies := map[model.Currency]bool{}
	for _, amounts := range []valuation.Amounts{
		summary.CashByCurrency, summary.PositionByCurrency, summary.GICByCurrency,
		summary.RealizedByCurrency, summary.UnrealizedByCurrency, summary.DividendsByCurrency,
	} {
		for currency := range amounts {
			currencies[currency] = true
		}
	}
	codes := make([]model.Currency, 0, len(currencies))
	for currency := range currencies {
		codes = append(codes, currency)
	}
	sort.Slice(codes, func(i, j int) bool { return codes[i] < codes[j] })
	rows := make([]backupCurrencyMetadata, 0, len(codes))
	for _, currency := range codes {
		cash := summary.CashByCurrency[currency]
		positions := summary.PositionByCurrency[currency]
		gics := summary.GICByCurrency[currency]
		unrealized := decimalText(summaryAmount(summary.UnrealizedByCurrency, currency))
		rows = append(rows, backupCurrencyMetadata{
			Currency:      string(currency),
			Cash:          cash.Fixed(2),
			Positions:     positions.Fixed(2),
			GICs:          gics.Fixed(2),
			Total:         cash.Add(positions).Add(gics).Fixed(2),
			RealizedPnl:   summary.RealizedByCurrency[currency].Fixed(2),
			UnrealizedPnl: unrealized,
			Dividends:     summary.DividendsByCurrency[currency].Fixed(2),
		})
	}
	return rows
}

func atomicBackupFile(path string, data []byte) error {
	directory := filepath.Dir(path)
	file, err := os.CreateTemp(directory, ".dit-backup-*")
	if err != nil {
		return err
	}
	temporary := file.Name()
	defer os.Remove(temporary)
	if err := file.Chmod(0o600); err != nil {
		file.Close()
		return err
	}
	if _, err := file.Write(data); err != nil {
		file.Close()
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	if err := os.Link(temporary, path); err != nil {
		return err
	}
	return nil
}

func nextBackupStamp(directory string) string {
	base := time.Now()
	for offset := 0; offset < 3600; offset++ {
		stamp := base.Add(time.Duration(offset) * time.Second).Format("20060102.150405")
		pair := backupPaths(directory, stamp)
		if _, err := os.Stat(pair.portfolio); os.IsNotExist(err) {
			if _, err := os.Stat(pair.market); os.IsNotExist(err) {
				if _, err := os.Stat(pair.metadata); os.IsNotExist(err) {
					return stamp
				}
			}
		}
	}
	return base.Format("20060102.150405")
}

func portfolioBackup(c Context, args []string) error {
	if len(args) != 0 {
		return usage("usage: dit backup")
	}
	directory, err := backupDirectory()
	if err != nil {
		return Runtime("cannot locate the home directory: " + err.Error())
	}
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return Runtime("cannot create backup directory: " + err.Error())
	}
	stamp := nextBackupStamp(directory)
	pair, err := createBackup(c, stamp)
	if err != nil {
		return Runtime("could not create backup: " + err.Error())
	}
	c.printf("Backed up portfolio and market data (%s):\n  %s\n  %s\n  %s\n", stamp, pair.portfolio, pair.market, pair.metadata)
	return nil
}

func availableBackups() ([]backupPair, string, error) {
	directory, err := backupDirectory()
	if err != nil {
		return nil, "", err
	}
	entries, err := os.ReadDir(directory)
	if os.IsNotExist(err) {
		return nil, directory, nil
	}
	if err != nil {
		return nil, directory, err
	}
	pairs := map[string]*backupPair{}
	for _, entry := range entries {
		name := entry.Name()
		var stamp, kind string
		switch {
		case strings.HasPrefix(name, "portfolio.dat."):
			stamp, kind = strings.TrimPrefix(name, "portfolio.dat."), "portfolio"
		case strings.HasPrefix(name, "market.dat."):
			stamp, kind = strings.TrimPrefix(name, "market.dat."), "market"
		case strings.HasPrefix(name, "metadata.json."):
			stamp, kind = strings.TrimPrefix(name, "metadata.json."), "metadata"
		default:
			continue
		}
		if !validBackupStamp(stamp) || entry.IsDir() {
			continue
		}
		pair := pairs[stamp]
		if pair == nil {
			pair = &backupPair{stamp: stamp}
			pairs[stamp] = pair
		}
		path := filepath.Join(directory, name)
		switch kind {
		case "portfolio":
			pair.portfolio = path
		case "market":
			pair.market = path
		case "metadata":
			pair.metadata = path
		}
	}
	stamps := make([]string, 0, len(pairs))
	for stamp := range pairs {
		stamps = append(stamps, stamp)
	}
	sort.Sort(sort.Reverse(sort.StringSlice(stamps)))
	result := make([]backupPair, 0, len(stamps))
	for _, stamp := range stamps {
		result = append(result, *pairs[stamp])
	}
	return result, directory, nil
}

func portfolioRollback(c Context, args []string) error {
	if len(args) == 1 && args[0] == "--list" {
		pairs, directory, err := availableBackups()
		if err != nil {
			return Runtime("cannot list backups: " + err.Error())
		}
		if len(pairs) == 0 {
			c.printf("No backups found in %s.\n", directory)
			return nil
		}
		c.printf("Available backups in %s:\n", directory)
		for _, pair := range pairs {
			status := ""
			if pair.portfolio == "" || pair.market == "" {
				missing := "portfolio"
				if pair.portfolio != "" {
					missing = "market"
				}
				status = " (incomplete: missing " + missing + ")"
			} else if pair.metadata == "" {
				status = " (metadata missing)"
			}
			if pair.portfolio != "" && pair.market != "" {
				c.printf("  %s%s  → dit rollback %s\n", pair.stamp, status, pair.stamp)
			} else {
				c.printf("  %s%s\n", pair.stamp, status)
			}
		}
		return nil
	}
	stamp := ""
	yes := false
	for _, arg := range args {
		if arg == "--yes" {
			if yes {
				return usage("--yes was supplied more than once")
			}
			yes = true
			continue
		}
		if strings.HasPrefix(arg, "-") || stamp != "" {
			return usage("usage: dit rollback <YYYYMMDD.HHMMSS> [--yes] or dit rollback --list")
		}
		stamp = arg
	}
	if !validBackupStamp(stamp) {
		return usage("usage: dit rollback <YYYYMMDD.HHMMSS> [--yes] or dit rollback --list")
	}
	directory, err := backupDirectory()
	if err != nil {
		return Runtime("cannot locate the home directory: " + err.Error())
	}
	pair := backupPaths(directory, stamp)
	portfolioRaw, err := os.ReadFile(pair.portfolio)
	if err != nil {
		return Runtime(fmt.Sprintf("cannot read portfolio backup %s: %v", pair.portfolio, err))
	}
	marketRaw, err := os.ReadFile(pair.market)
	if err != nil {
		return Runtime(fmt.Sprintf("cannot read market backup %s: %v", pair.market, err))
	}
	portfolio, err := bundle.DecodePortfolio(portfolioRaw)
	if err != nil {
		return usage("portfolio backup is invalid: " + err.Error())
	}
	var market model.MarketData
	if err := json.Unmarshal(marketRaw, &market); err != nil {
		return usage("market backup is invalid: " + err.Error())
	}
	if err := transferConfirm(c, fmt.Sprintf("Restore portfolio (%d account(s), %d transaction(s)) and market data from backup %s?", len(portfolio.Accounts), len(portfolio.Transactions), stamp), yes, true); err != nil {
		return err
	}

	// Preserve the current documents as a fresh backup before replacing them.
	preBackup := ""
	if current, err := transferRead(c, c.Layout.PortfolioDir, store.PortfolioKey); err != nil {
		return Runtime("cannot read the current portfolio before rollback: " + err.Error())
	} else if current != nil {
		preBackup, err = nextBackupStamp(directory), nil
		if _, err = createBackup(c, preBackup); err != nil {
			return Runtime("could not back up the current stores before rollback: " + err.Error())
		}
	}
	if err := transferSave(c, &portfolio, &market); err != nil {
		return Runtime("could not restore backup: " + err.Error())
	}
	if preBackup != "" {
		c.printf("Current stores backed up as %s.\n", preBackup)
	}
	c.printf("Rolled back to backup %s.\nStore: %s\nMarket store: %s\n", stamp, c.PortfolioLocation(), c.MarketLocation())
	return nil
}
