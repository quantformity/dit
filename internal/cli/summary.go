package cli

import (
	"database/sql"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"dit/internal/config"
	"dit/internal/decimal"
	"dit/internal/model"
	"dit/internal/provider"
	"dit/internal/store"
	"dit/internal/text"
	"dit/internal/valuation"
)

var summarySpecs = Registry{
	"":        &Spec{Run: summaryCommand, SkipParse: true},
	"summary": &Spec{Run: summaryCommand, SkipParse: true},
}

func summaryCommand(c Context, args []string) error {
	// The oracle accepts (and ignores) everything after "summary": stray
	// positionals, unknown flags and all — parity over strictness.
	return summaryRun(c, time.Now())
}

// quoteMaxAge is the summary's tolerance for quote age: three days, so that
// outside market hours (weekends, holidays) the last close still marks the
// position. Anything older degrades to cost basis, loudly.
const quoteMaxAge = 3 * 24 * time.Hour

func summaryRun(c Context, now time.Time) error {
	day := model.Day(model.DayStartUTC(now.Unix()))
	p, m, err := summaryLoad(c)
	if err != nil {
		return err
	}
	if p == nil {
		return emptySummary(c)
	}
	if len(p.Accounts) == 0 {
		if c.JSON {
			notes := []string{"the portfolio has no accounts yet"}
			return c.WriteJSON(SummaryJSON(valuation.CostSummary(p, c.Display, day), now, c.PortfolioLocation(), notes, c.Offline, c.Offline))
		}
		c.printf("The portfolio has no accounts yet.\n")
		return nil
	}
	notes := []string{}
	var s valuation.Summary
	var liveCache *provider.Cache
	stalePriced := false
	if c.Offline {
		s = valuation.CostSummary(p, c.Display, day)
		notes = append(notes, "offline mode: positions at cost basis, no FX conversion")
	} else {
		s, liveCache, stalePriced = runLive(p, m, c.Display, now, &notes)
	}
	for _, short := range s.Shorts {
		notes = append(notes, fmt.Sprintf("untracked short: %s sold %s %s (%s) beyond its holding — cash shows the proceeds, the short itself is not tracked, so totals here are incomplete", short.AccountName, summaryQuantity(short.Shares), short.Symbol, short.Currency))
	}
	degraded := c.Offline || stalePriced || notesContainFetchFailure(notes)
	if c.JSON {
		if liveCache != nil {
			return c.WriteJSON(SummaryJSONLive(s, now, c.PortfolioLocation(), notes, false, degraded, liveCache, m, quoteMaxAge))
		}
		return c.WriteJSON(SummaryJSON(s, now, c.PortfolioLocation(), notes, c.Offline, degraded))
	}
	if stalePriced {
		// Above the report, not under it: by the time a reader reaches the
		// notes they have already copied the totals down.
		c.printf("No live quote could be fetched. Positions below are priced from stored closes, " +
			"which are NOT today's prices — see Notes.\n\n")
	}
	c.printf("%s\n\nStore: %s\n", RenderSummary(s, now, notes, boldHeaders(c)), c.PortfolioLocation())
	return nil
}

func emptySummary(c Context) error {
	if c.JSON {
		return c.WriteJSON(map[string]any{"ok": true, "schema": "summary/1", "data": map[string]any{"empty": true, "note": "no portfolio found — add accounts and transactions first", "store": c.PortfolioLocation()}})
	}
	c.printf("No portfolio found (store: %s at %s).\nAdd accounts and transactions first.\n", c.Layout.Backend, c.PortfolioLocation())
	return nil
}

// runLive observes the market (quotes for open positions, hub FX rates for
// every currency in play) and values the portfolio from those observations,
// adding the notes a degraded answer owes: failed fetches, then staleness.
func runLive(p *model.Portfolio, m model.MarketData, display model.Currency, now time.Time, notes *[]string) (valuation.Summary, *provider.Cache, bool) {
	symbols, fx := providerPlan(p, display, now)
	cache := provider.NewCache()
	prov := providerForCommand()
	if len(symbols) == 0 {
		*notes = append(*notes, "no open positions — no quotes to fetch")
	} else {
		quotes, err := prov.Quotes(symbols)
		if err != nil {
			// The cost/stored-close consequence is stated where it can be
			// checked — per position, and in stalePriceNote — rather than as a
			// blanket clause here, which used to assert "at cost basis" even
			// when the numbers came from stored closes.
			*notes = append(*notes, "quote fetch failed: "+err.Error())
		} else {
			for _, quote := range quotes {
				cache.Upsert(quote)
			}
		}
	}
	for _, ccy := range fx {
		rate, err := prov.Rate(model.ConversionHub, ccy)
		if err != nil {
			*notes = append(*notes, strings.ToUpper(string(model.ConversionHub))+"-"+strings.ToUpper(string(ccy))+" rate fetch failed: "+err.Error())
		} else {
			cache.UpsertRate(rate)
		}
	}
	*notes = append(*notes, stalenessNotes(cache, symbols, now)...)
	s := valuation.Live(p, cache, m, display, quoteMaxAge, now)
	// Anything not priced from a live quote was priced from a stored close, or
	// not priced at all. Say which, before printing the totals it produced.
	stale := valuation.StaleMarks(s, cache, m, quoteMaxAge, now)
	if len(stale) > 0 {
		*notes = append(*notes, stalePriceNote(stale))
	}
	return s, cache, len(stale) > 0
}

// stalePriceNote names the stored closes a report was priced from. A figure
// that looks like a market price but came out of a file is the easiest wrong
// number to believe, so this gives the price, its date and its age instead of
// a bare warning word — and it stays honest when the fetch merely came back
// empty rather than failing outright.
func stalePriceNote(stale []valuation.StaleMark) string {
	pieces := make([]string, 0, len(stale))
	unverified := false
	for _, mark := range stale {
		label := fmt.Sprintf("%s %s on %s (%dd old)", mark.Symbol, text.Money(mark.Price), mark.Day, mark.AgeDays)
		if mark.CurrencyUnverified {
			label += " currency unrecorded"
			unverified = true
		}
		pieces = append(pieces, label)
	}
	note := "no live quote for " + strings.Join(pieces, ", ") + " — those positions are shown at the stored close, which is not today's price"
	if unverified {
		note += " (at least one series has no recorded currency: check it is quoted in the position's own currency)"
	}
	return note
}

// providerPlan mirrors the oracle's market-data plan: symbols with open
// positions, plus every non-hub currency in play (positions, cash, GICs,
// display). A cost-basis walk is enough to see them — which positions are
// open does not depend on the price.
func providerPlan(p *model.Portfolio, display model.Currency, now time.Time) (symbols []string, fx []model.Currency) {
	s := valuation.CostSummary(p, display, model.Day(model.DayStartUTC(now.Unix())))
	seenSymbols := map[string]bool{}
	seenCurrencies := map[model.Currency]bool{display: true}
	for _, h := range s.Holdings {
		seenSymbols[h.Symbol] = true
		seenCurrencies[h.Currency] = true
	}
	for c := range s.CashByCurrency {
		seenCurrencies[c] = true
	}
	for c := range s.GICByCurrency {
		seenCurrencies[c] = true
	}
	for symbol := range seenSymbols {
		symbols = append(symbols, symbol)
	}
	sort.Strings(symbols)
	for c := range seenCurrencies {
		if c == model.ConversionHub || c == model.Unknown {
			continue
		}
		fx = append(fx, c)
	}
	sort.Slice(fx, func(i, j int) bool { return fx[i] < fx[j] })
	return symbols, fx
}

// providerForCommand picks the observation source: a pin file when
// DIT_PROVIDER_STUB names one (deterministic twin runs), otherwise the live
// Yahoo provider. A pin file that cannot be read is a connection failure,
// not a data answer — every observation errors with why.
func providerForCommand() provider.Provider {
	if path := os.Getenv("DIT_PROVIDER_STUB"); path != "" {
		pin, err := provider.LoadStub(path)
		if err != nil {
			message := err.Error()
			failure := func() *provider.Error {
				return &provider.Error{Kind: "network", Message: "DIT_PROVIDER_STUB: " + message}
			}
			return provider.Provider{
				DailySeries: func(string, model.Day, model.Day) (provider.DailySeries, error) {
					return provider.DailySeries{}, failure()
				},
				Quotes: func([]string) ([]provider.Quote, error) { return nil, failure() },
				Rate:   func(model.Currency, model.Currency) (provider.Rate, error) { return provider.Rate{}, failure() },
			}
		}
		return pin
	}
	return provider.Yahoo(provider.YahooConfig{})
}

// stalenessNotes mirrors the oracle's staleness note: present when the
// newest observation across the planned symbols is older than a minute.
func stalenessNotes(cache *provider.Cache, symbols []string, now time.Time) []string {
	var newest *time.Time
	for _, symbol := range symbols {
		if quote := cache.Quote(symbol); quote != nil && quote.AsOf != nil {
			if newest == nil || quote.AsOf.After(*newest) {
				newest = quote.AsOf
			}
		}
	}
	if newest == nil || now.Sub(*newest) <= time.Minute {
		return nil
	}
	return []string{"quote data as of " + summaryClock(*newest) + " — market may be closed, prices may be stale"}
}

func notesContainFetchFailure(notes []string) bool {
	for _, note := range notes {
		if strings.Contains(note, "fetch failed") {
			return true
		}
	}
	return false
}

// Shared store constructors create directories and initialize SQLite schemas.
// A read command instead supplies a load-only Store so even first contact with
// a nonexistent portfolio leaves the filesystem unchanged.
func summaryLoad(c Context) (*model.Portfolio, model.MarketData, error) {
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
	p, err := store.LoadPortfolio(readOnly(c.Layout.PortfolioDir))
	if err != nil {
		return nil, model.MarketData{}, err
	}
	if c.Offline || p == nil || len(p.Accounts) == 0 {
		return p, store.EmptyMarket(), nil
	}
	return p, store.LoadMarket(readOnly(c.Layout.MarketDir)), nil
}

func summaryMoney(d *decimal.Decimal) string {
	if d == nil {
		return "—"
	}
	return text.Money(*d)
}
func summaryPercent(d *decimal.Decimal) string {
	if d == nil {
		return "—"
	}
	s := text.Percent(*d)
	if d.Sign() == 0 {
		return "+" + s
	}
	if d.Sign() < 0 && !strings.HasPrefix(s, "-") {
		return "-" + s
	}
	return s
}
func summaryClock(t time.Time) string {
	return t.Local().Format("Jan 2, 2006 at 3:04") + "\u202f" + t.Local().Format("PM")
}
func accountPosition(a valuation.Account) *decimal.Decimal {
	if a.Total == nil || a.Cash == nil || a.GICValue == nil {
		return nil
	}
	d := a.Total.Sub(*a.Cash).Sub(*a.GICValue)
	return &d
}

// summaryPositionText preserves Foundation Decimal's signed-zero rendering
// for settled GIC-only accounts. The exact Go value remains zero (including
// in JSON); this is a text-only compatibility quirk of the Swift report.
func summaryPositionText(a valuation.Account) string {
	position := accountPosition(a)
	if position != nil && position.IsZero() && a.GICValue != nil && !a.GICValue.IsZero() && len(a.Positions) == 0 {
		return "-0.00"
	}
	return summaryMoney(position)
}
func summaryCurrencies(s valuation.Summary) []model.Currency {
	out := []model.Currency{}
	for c := range s.ValueByCurrency() {
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}
func summaryAmount(a valuation.Amounts, c model.Currency) *decimal.Decimal {
	d, ok := a[c]
	if !ok {
		return nil
	}
	return &d
}

// RenderSummary formats only at the boundary: printed cents never flow back
// into position values, FX conversion, or return percentages.
func RenderSummary(s valuation.Summary, now time.Time, notes []string, bold bool) string {
	display := string(s.DisplayCurrency)
	lines := []string{"Portfolio summary — " + summaryClock(now) + "  (display: " + display + ")", ""}
	money := func(d *decimal.Decimal) string {
		if d == nil {
			return "—"
		}
		return summaryMoney(d) + " " + display
	}
	showDay, showConverted := false, false
	for _, h := range s.Holdings {
		showDay = showDay || h.DayChange != nil
		showConverted = showConverted || h.Currency != s.DisplayCurrency
	}
	lines = append(lines, "  Total value      "+money(s.Total), "  Cash             "+money(s.Cash), "  Positions        "+money(s.PositionValue), "  GICs (at par)    "+money(s.GICValue), "", "  Unrealized P&L   "+money(s.Unrealized))
	if showDay {
		lines = append(lines, "  Day change       "+money(s.DayChange)+"   (vs previous close)")
	}
	lines = append(lines, "  Realized P&L     "+money(s.Realized), "  Dividends        "+money(s.Dividends), "", "By currency:")
	currencies := summaryCurrencies(s)
	rows := [][]string{}
	headers := []string{"Ccy", "Cash", "Positions", "GIC", "Total"}
	if showDay {
		headers = append(headers, "Day")
	}
	for _, ccy := range currencies {
		cash, pos, gic, total := s.CashByCurrency[ccy], s.PositionByCurrency[ccy], s.GICByCurrency[ccy], s.ValueByCurrency()[ccy]
		row := []string{string(ccy), text.Money(cash), text.Money(pos), text.Money(gic), text.Money(total)}
		if showDay {
			row = append(row, summaryMoney(summaryAmount(s.DayByCurrency, ccy)))
		}
		rows = append(rows, row)
	}
	if len(rows) == 0 {
		lines = append(lines, "  —")
	} else {
		lines = append(lines, text.Table(headers, rows, map[int]bool{0: true}, bold)...)
	}
	lines = append(lines, "", "Accounts:")
	rows = [][]string{}
	headers = []string{"Name", "Ccy", "Cash", "Positions", "GIC", "Total", "Unrealized"}
	if showDay {
		headers = append(headers, "Day")
	}
	for _, a := range s.Accounts {
		row := []string{valuation.Name(a.Account), string(a.Account.ReportingCurrency), summaryMoney(a.Cash), summaryPositionText(a), summaryMoney(a.GICValue), summaryMoney(a.Total), summaryMoney(a.Unrealized)}
		if showDay {
			row = append(row, summaryMoney(a.DayChange))
		}
		rows = append(rows, row)
	}
	if len(rows) == 0 {
		lines = append(lines, "  —")
	} else {
		lines = append(lines, text.Table(headers, rows, map[int]bool{0: true}, bold)...)
	}
	lines = append(lines, "", "Holdings:")
	rows = [][]string{}
	headers = []string{"Symbol", "Name", "Ccy", "Shares", "Avg cost", "Last", "Value"}
	if showConverted {
		headers = append(headers, "Value ("+display+")")
	}
	if showDay {
		headers = append(headers, "Day ("+display+")", "Day%")
	}
	headers = append(headers, "P&L ("+display+")", "P&L%", "Where")
	for _, h := range s.Holdings {
		last, pct := "—", "—"
		if h.Unrealized != nil && !h.Shares.IsZero() {
			last = text.Money(h.Value.Div(h.Shares, 38))
		}
		if h.Unrealized != nil && h.Shares.Sign() > 0 && h.Cost.Sign() > 0 {
			ratio := h.Unrealized.Div(h.Cost, 38)
			pct = summaryPercent(&ratio)
		}
		row := []string{h.Symbol, OrEmpty(h.Name), string(h.Currency), text.Quantity(h.Shares), text.Money(h.AverageCost), last, string(h.Currency) + " " + text.Money(h.Value)}
		if showConverted {
			row = append(row, summaryMoney(h.ValueDisplay))
		}
		if showDay {
			row = append(row, summaryMoney(h.DayDisplay), summaryPercent(h.DayFraction))
		}
		row = append(row, summaryMoney(h.UnrealizedDisplay), pct, strings.Join(h.AccountNames, ", "))
		rows = append(rows, row)
	}
	if len(rows) == 0 {
		lines = append(lines, "  —")
	} else {
		lines = append(lines, text.Table(headers, rows, map[int]bool{0: true, 1: true}, bold)...)
	}
	allNotes := append([]string(nil), notes...)
	if showConverted {
		allNotes = append(allNotes, "Value ("+display+"), Day ("+display+") and P&L ("+display+") are converted at the current FX rate; Day% and P&L% stay native-currency ratios so FX movement cannot masquerade as trading gain")
	}
	if showDay {
		allNotes = append(allNotes, "day change = latest quote vs the previous stored close of the same ticker (a model comparison where history is derived)")
	}
	modelSymbols := []string{}
	for _, h := range s.Holdings {
		if h.DayChange != nil && h.DayModel {
			modelSymbols = append(modelSymbols, h.Symbol)
		}
	}
	sort.Strings(modelSymbols)
	if len(modelSymbols) > 0 {
		allNotes = append(allNotes, "day change for "+strings.Join(modelSymbols, ", ")+" mirrors the underlying's move through a derived proxy — it is not a real quote of these tickers")
	}
	for _, h := range s.Holdings {
		if h.Unrealized == nil {
			allNotes = append(allNotes, h.Symbol+" ("+string(h.Currency)+") valued at cost basis — no fresh quote")
		}
	}
	if s.Total == nil || s.Cash == nil || s.PositionValue == nil || s.GICValue == nil {
		allNotes = append(allNotes, "some totals are unconverted — see the per-currency breakdown")
	}
	if len(allNotes) > 0 {
		lines = append(lines, "", "Notes:")
		for _, note := range allNotes {
			lines = append(lines, "  - "+note)
		}
	}
	return strings.Join(lines, "\n")
}

func summaryFixed(d *decimal.Decimal, scale int32) any {
	if d == nil {
		return nil
	}
	return text.Fixed(*d, scale)
}
func summaryQuantity(d decimal.Decimal) string {
	s := strings.TrimRight(d.Fixed(4), "0")
	return strings.TrimSuffix(s, ".")
}
func summaryNullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// SummaryJSON uses strings for financial quantities and null for unknowns;
// consumers must never mistake a missing quote or FX leg for a measured zero.
func SummaryJSON(s valuation.Summary, now time.Time, store string, warnings []string, offline, degraded bool) map[string]any {
	return summaryJSONDoc(s, now, store, warnings, offline, degraded, nil, nil)
}

// SummaryJSONLive is the same document, with each holding's quote block
// replayed from the provider cache exactly as the oracle does: the fresh,
// currency-matched observation plus the stored point strictly before it.
func SummaryJSONLive(s valuation.Summary, now time.Time, store string, warnings []string, offline, degraded bool, cache *provider.Cache, market model.MarketData, maxAge time.Duration) map[string]any {
	// Which positions were priced from a file rather than from a quote, so the
	// document can say so per holding.
	stale := map[string]valuation.StaleMark{}
	for _, mark := range valuation.StaleMarks(s, cache, market, maxAge, now) {
		stale[mark.Symbol] = mark
	}
	return summaryJSONDoc(s, now, store, warnings, offline, degraded, func(h valuation.Position) map[string]any {
		quote := cache.FreshQuote(h.Symbol, maxAge, now)
		if quote == nil || quote.Currency != h.Currency {
			return nil
		}
		bound := now
		if quote.AsOf != nil {
			bound = *quote.AsOf
		}
		var previous any
		if point, ok := market.CloseStrictlyBefore(h.Symbol, bound.Unix()); ok && point.Price.Sign() > 0 {
			previous = map[string]any{"date": point.Day.String(), "price": point.Price.Fixed(2), "via": summaryNullable(point.Via)}
		}
		asOf := any(nil)
		if quote.AsOf != nil {
			asOf = quote.AsOf.UTC().Format("2006-01-02T15:04:05Z")
		}
		return map[string]any{"asOf": asOf, "previousClose": previous, "price": quote.Price.Fixed(2), "source": summaryNullable(quote.Source)}
	}, stale)
}

func summaryJSONDoc(s valuation.Summary, now time.Time, store string, warnings []string, offline, degraded bool, liveQuote func(h valuation.Position) map[string]any, stale map[string]valuation.StaleMark) map[string]any {
	f := func(d *decimal.Decimal) any { return summaryFixed(d, 2) }
	accounts := []any{}
	for _, a := range s.Accounts {
		accounts = append(accounts, map[string]any{"id": a.Account.ID, "name": valuation.Name(a.Account), "reportingCurrency": string(a.Account.ReportingCurrency), "cash": f(a.Cash), "positions": f(accountPosition(a)), "gic": f(a.GICValue), "total": f(a.Total), "unrealizedPnl": f(a.Unrealized), "dayChange": f(a.DayChange)})
	}
	holdings := []any{}
	for _, h := range s.Holdings {
		var pct *decimal.Decimal
		if h.Unrealized != nil && h.Shares.Sign() > 0 && h.Cost.Sign() > 0 {
			d := h.Unrealized.Div(h.Cost, 38)
			pct = &d
		}
		row := map[string]any{"accounts": h.AccountNames, "avgCost": h.AverageCost.Fixed(2), "ccy": string(h.Currency), "dayChange": f(h.DayChange), "dayChangeDisplay": f(h.DayDisplay), "dayPct": summaryFixed(h.DayFraction, 4), "name": h.Name, "pnl": f(h.Unrealized), "pnlDisplay": f(h.UnrealizedDisplay), "pnlPct": summaryFixed(pct, 4), "shares": summaryQuantity(h.Shares), "symbol": h.Symbol, "value": h.Value.Fixed(2), "valueDisplay": f(h.ValueDisplay)}
		if h.Price != nil {
			var previous any
			if h.Previous != nil {
				previous = map[string]any{"date": h.Previous.Day.String(), "price": h.Previous.Price.Fixed(2), "via": summaryNullable(h.Previous.Via)}
			}
			q := map[string]any{"asOf": h.Price.Day.DayTime().Format("2006-01-02T15:04:05Z"), "previousClose": previous, "price": h.Price.Price.Fixed(2), "source": "market-store"}
			if h.Price.Via != "" {
				q["via"] = h.Price.Via
			}
			if _, fromFile := stale[h.Symbol]; fromFile {
				// Not a live observation: the price is a stored close of the
				// date above. Without this flag a consumer reading the JSON
				// sees a quote-shaped object and has no way to know.
				q["live"] = false
			}
			row["quote"] = q
		} else if liveQuote != nil {
			if q := liveQuote(h); q != nil {
				row["quote"] = q
			}
		}
		holdings = append(holdings, row)
	}
	byCurrency := map[string]any{}
	for _, ccy := range summaryCurrencies(s) {
		byCurrency[string(ccy)] = map[string]any{"cash": s.CashByCurrency[ccy].Fixed(2), "positions": s.PositionByCurrency[ccy].Fixed(2), "gic": s.GICByCurrency[ccy].Fixed(2), "total": s.ValueByCurrency()[ccy].Fixed(2), "dayChange": f(summaryAmount(s.DayByCurrency, ccy))}
	}
	shorts := []any{}
	for _, sh := range s.Shorts {
		shorts = append(shorts, map[string]any{"account": sh.AccountName, "symbol": sh.Symbol, "ccy": string(sh.Currency), "shares": summaryQuantity(sh.Shares)})
	}
	if warnings == nil {
		warnings = []string{}
	}
	return map[string]any{"ok": true, "schema": "summary/1", "data": map[string]any{"accounts": accounts, "degraded": degraded, "displayCurrency": string(s.DisplayCurrency), "generatedAt": now.UTC().Format("2006-01-02T15:04:05Z"), "holdings": holdings, "offline": offline, "store": store, "totals": map[string]any{"byCurrency": byCurrency, "cash": f(s.Cash), "dayChange": f(s.DayChange), "dividends": f(s.Dividends), "gic": f(s.GICValue), "positions": f(s.PositionValue), "realizedPnl": f(s.Realized), "totalValue": f(s.Total), "unrealizedPnl": f(s.Unrealized)}, "untrackedShorts": shorts, "warnings": warnings}}
}
