package cli

// Historical (as-of) reporting.
//
// `--as-of DATE` replays the ledger to a past day: transactions after that day
// are excluded, positions are priced from the newest stored close on or before
// it (never a live quote, and never a two-year-old purchase price masquerading
// as a market price), and totals convert at the FX rate recorded for that day
// or are dashed when no historical rate exists. It answers "what was I worth /
// holding then?" without pretending the answer is today's market.

import (
	"database/sql"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"dit/internal/config"
	"dit/internal/decimal"
	"dit/internal/model"
	"dit/internal/store"
	"dit/internal/text"
	"dit/internal/valuation"
)

// seriesCap bounds how many points one report will compute, so a pathological
// window (say `--daily` across a century) cannot hang the CLI.
const seriesCap = 3000

// seriesRunConfig is what a `summary`/`account show` invocation resolves its
// arguments to before any market data is touched.
type summaryRunConfig struct {
	asOf   *model.Day // single past day, or nil for "now"
	from   *model.Day // start of a net-worth series
	to     *model.Day // end of a net-worth series
	series bool       // --time-series: emit a series instead of a snapshot
	daily  bool       // --daily: slice the series by day instead of month
}

// parseSummaryRunArgs scans a summary-style argument list for the as-of knobs.
// It deliberately ignores everything else — the oracle treats `summary`
// arguments leniently (stray positionals and unknown flags included), and
// summarySpecs keep SkipParse so that stays true; a genuinely malformed date
// for a knob we DO recognise is still a usage error.
func parseSummaryRunArgs(args []string) (summaryRunConfig, error) {
	var cfg summaryRunConfig
	setDay := func(dst **model.Day, raw string) error {
		d, err := model.ParseDay(raw)
		if err != nil || len(raw) != 10 || d.String() != raw {
			return usage(errInvalidDate(raw))
		}
		*dst = &d
		return nil
	}
	for i := 0; i < len(args); i++ {
		arg := args[i]
		name, inlineValue, hasInline := strings.Cut(arg, "=")
		var raw string
		switch name {
		case "--as-of", "--as-of-from", "--as-of-to":
			raw = inlineValue
			if !hasInline {
				if i+1 < len(args) {
					raw = args[i+1]
					i++
				}
			}
			if raw == "" {
				return cfg, usage("missing value for " + name)
			}
			switch name {
			case "--as-of":
				if err := setDay(&cfg.asOf, raw); err != nil {
					return cfg, err
				}
			case "--as-of-from":
				if err := setDay(&cfg.from, raw); err != nil {
					return cfg, err
				}
			case "--as-of-to":
				if err := setDay(&cfg.to, raw); err != nil {
					return cfg, err
				}
			}
		case "--time-series":
			cfg.series = true
		case "--daily":
			cfg.daily = true
			cfg.series = true
		default:
			// Unknown flag or positional: ignored, per the oracle's leniency.
		}
	}
	// A window on its own implies a series: silently ignoring `--as-of-from`/
	// `--as-of-to` would answer a past-window question with today's numbers.
	if cfg.from != nil || cfg.to != nil {
		cfg.series = true
	}
	if cfg.asOf != nil && (cfg.from != nil || cfg.to != nil) {
		return cfg, usage("--as-of and --as-of-from/--as-of-to cannot be combined — pick a snapshot or a series")
	}
	return cfg, nil
}

func errInvalidDate(raw string) string {
	return "invalid date '" + raw + "' — expected YYYY-MM-DD"
}

// resolveWindow turns the config into the concrete days a report should cover.
// Without explicit bounds a series defaults to the last twelve month-ends plus
// the last day, so a bare `--time-series` is bounded and cheap.
func (cfg summaryRunConfig) resolveWindow(now time.Time) (from, to model.Day, err error) {
	last := model.Day(model.DayStartUTC(now.Unix()))
	if cfg.asOf != nil {
		last = *cfg.asOf
	}
	if cfg.to != nil {
		last = *cfg.to
	}
	if !cfg.series {
		return last, last, nil
	}
	start := model.Day(model.DayStartUTC(last.DayTime().AddDate(0, -12, 0).Unix()))
	if cfg.from != nil {
		start = *cfg.from
	}
	if start > last {
		return 0, 0, usage("--as-of-from must not be after the report's last day")
	}
	return start, last, nil
}

// seriesDays lists the days a net-worth series reports, oldest first. Month
// mode emits month-ends (capped at the last day); daily mode steps day by day.
//
// A `--time-series` with no bounds deliberately shows only the last twelve
// month-ends (cheap, and enough for a glance). An EXPLICIT window is honoured
// in full, so 13 points never masquerade as a five-year answer. `seriesCap`
// bounds the work for an absurd window (a daily walk over centuries).
func (cfg summaryRunConfig) seriesDays(from, to model.Day) []model.Day {
	seen := map[model.Day]bool{}
	days := []model.Day{}
	if !cfg.daily {
		anchor := to.DayTime()
		// Walk back month by month across the whole requested window instead of a
		// fixed 12 months, stopping only at the cap.
		for back := 0; back < seriesCap; back++ {
			monthStart := anchor.AddDate(0, -back, 0)
			eom := time.Date(monthStart.Year(), monthStart.Month()+1, 0, 0, 0, 0, 0, time.UTC)
			if eom.After(to.DayTime()) {
				eom = to.DayTime()
			}
			day := model.Day(model.DayStartUTC(eom.Unix()))
			if day < from {
				break
			}
			if !seen[day] {
				seen[day] = true
				days = append(days, day)
			}
		}
	} else {
		for day, i := from, 0; day <= to && i < seriesCap; day, i = day+86400, i+1 {
			if !seen[day] {
				seen[day] = true
				days = append(days, day)
			}
		}
	}
	// Oldest first regardless of the walk direction above.
	sort.Slice(days, func(i, j int) bool { return days[i] < days[j] })
	return days
}

// asOfSeries computes one Summary per day, using stored closes and historical
// FX (never the network).
func asOfSeries(p *model.Portfolio, market model.MarketData, display model.Currency, days []model.Day) []valuation.Summary {
	out := make([]valuation.Summary, 0, len(days))
	for _, d := range days {
		out = append(out, valuation.Compute(p, market, display, d))
	}
	return out
}

func moneyOrDash(d *decimal.Decimal, display string) string {
	if d == nil {
		return "—"
	}
	return text.Money(*d) + " " + display
}

// renderAsOfSnapshot is the text body of an as-of report. It is intentionally
// separate from RenderSummary: a past-dated report must not carry a "day
// change vs previous close" column, which a reader would take for today's move.
func renderAsOfSnapshot(s valuation.Summary, asOf model.Day, display string, notes []string, bold bool, title string) string {
	if display == "" {
		display = "CAD"
	}
	money := func(d *decimal.Decimal) string { return moneyOrDash(d, display) }
	lines := []string{
		title + " — " + asOf.String() + "  (display: " + display + "; prices: last stored close on or before this date)",
		"",
		"  Total value      " + money(s.Total),
		"  Cash             " + money(s.Cash),
		"  Positions        " + money(s.PositionValue),
		"  GICs (at par)    " + money(s.GICValue),
		"",
		"  Unrealized P&L   " + money(s.Unrealized),
		"  Realized P&L     " + money(s.Realized),
		"  Dividends        " + money(s.Dividends),
		"",
		"By currency (native; not converted):",
	}
	currencies := summaryCurrencies(s)
	rows := [][]string{}
	for _, ccy := range currencies {
		cash, pos, gic, total := s.CashByCurrency[ccy], s.PositionByCurrency[ccy], s.GICByCurrency[ccy], s.ValueByCurrency()[ccy]
		rows = append(rows, []string{string(ccy), text.Money(cash), text.Money(pos), text.Money(gic), text.Money(total)})
	}
	if len(rows) == 0 {
		lines = append(lines, "  —")
	} else {
		lines = append(lines, text.Table([]string{"Ccy", "Cash", "Positions", "GIC", "Total"}, rows, map[int]bool{0: true}, bold)...)
	}
	lines = append(lines, "", "Holdings:")
	rows = [][]string{}
	for _, h := range s.Holdings {
		last, basis := "—", "cost basis"
		if h.Price != nil {
			last = string(h.Currency) + " " + text.Money(h.Price.Price)
			basis = "close " + h.Price.Day.String()
		}
		rows = append(rows, []string{h.Symbol, OrEmpty(h.Name), string(h.Currency), text.Quantity(h.Shares), text.Money(h.AverageCost), last, basis})
	}
	if len(rows) == 0 {
		lines = append(lines, "  —")
	} else {
		lines = append(lines, text.Table([]string{"Symbol", "Name", "Ccy", "Shares", "Avg cost", "Last", "Basis"}, rows, map[int]bool{0: true, 1: true}, bold)...)
	}
	if len(notes) > 0 {
		lines = append(lines, "", "Notes:")
		for _, n := range notes {
			lines = append(lines, "  - "+n)
		}
	}
	return strings.Join(lines, "\n")
}

// renderSeriesAt prints one net-worth row per reported day (total, cash,
// positions) in the display currency, dashed where no historical FX existed.
func renderSeriesAt(days []model.Day, snapshots []valuation.Summary, display string, bold bool) string {
	if display == "" {
		display = "CAD"
	}
	lines := []string{
		"Net worth over time (display: " + display + ")",
		"",
		"Each row replays the ledger to that date and prices it from the last stored close on or before it; a total is dashed when no historical FX rate exists for the day.",
		"",
	}
	rows := [][]string{}
	for i, s := range snapshots {
		rows = append(rows, []string{days[i].String(), moneyOrDash(s.Total, display), moneyOrDash(s.Cash, display), moneyOrDash(s.PositionValue, display)})
	}
	if len(rows) == 0 {
		lines = append(lines, "  —")
		return strings.Join(lines, "\n")
	}
	return strings.Join(append(lines, text.Table([]string{"Date", "Total", "Cash", "Positions"}, rows, map[int]bool{}, bold)...), "\n")
}

// loadStoredMarketForAsOf loads the stored market document WITHOUT fetching,
// read-only, so an as-of report never touches the network and a nonexistent
// market leaves the filesystem unchanged.
func loadStoredMarketForAsOf(c Context) model.MarketData {
	readOnly := func(path string) store.Store {
		return store.Store{Location: path, Load: func(key string) ([]byte, error) {
			if c.Layout.Backend != config.SQLite {
				b, err := os.ReadFile(filepath.Join(path, store.SanitizeKey(key)+".dat"))
				if os.IsNotExist(err) {
					return nil, nil
				}
				return b, err
			}
			if _, err := os.Stat(path); os.IsNotExist(err) {
				return nil, nil
			} else if err != nil {
				return nil, err
			}
			u := url.URL{Scheme: "file", Path: path}
			db, err := sql.Open("sqlite", u.String()+"?mode=ro")
			if err != nil {
				return nil, err
			}
			defer db.Close()
			var b []byte
			err = db.QueryRow("SELECT payload FROM store WHERE key = ?", key).Scan(&b)
			if err == sql.ErrNoRows {
				return nil, nil
			}
			return b, err
		}}
	}
	return store.LoadMarket(readOnly(c.Layout.MarketDir))
}
