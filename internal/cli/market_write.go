package cli

import (
	"bytes"
	"dit/internal/decimal"
	"dit/internal/market"
	"dit/internal/model"
	"dit/internal/provider"
	"dit/internal/store"
	"dit/internal/text"
	"fmt"
	"os"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

var marketWriteSpecs = Registry{
	"market latest":   {Run: MarketLatest},
	"market import":   {Run: MarketImport, FlagOptions: setOf("dry-run")},
	"market backfill": {Run: MarketBackfill, ValueOptions: setOf("from", "ratio"), FlagOptions: setOf("dry-run")},
	"update":          {Run: Update, FlagOptions: setOf("quick", "rebuild"), HelpText: updateUsage},
}

func loadWriteMarket(c Context) (*model.Portfolio, model.MarketData, error) {
	l, m, e := marketReadStores(c)
	if e != nil {
		return nil, model.MarketData{}, e
	}
	p, e := store.LoadPortfolio(l)
	if e != nil {
		return nil, model.MarketData{}, e
	}
	if p == nil {
		return nil, store.EmptyMarket(), nil
	}
	raw, e := m.Load(store.MarketKey)
	if e != nil {
		return nil, model.MarketData{}, e
	}
	return p, readMarketCache(raw), nil
}
func saveWriteMarket(c Context, d model.MarketData) error {
	var s store.Store
	var e error
	if c.Layout.Backend == "sqlite" {
		s, e = store.NewSQLiteStore(c.Layout.MarketDir)
	} else {
		s, e = store.NewFileStore(c.Layout.MarketDir)
	}
	if e != nil {
		return e
	}
	return store.SaveMarket(s, &d)
}
func noMarketPortfolio(c Context) {
	c.printf("No portfolio found (store: %s at %s).\nNothing to update — add accounts and transactions first.\n", c.Layout.Backend, c.Layout.PortfolioDir)
}
func writeNow(d *model.MarketData, now time.Time) { s := model.Stamp(now.Unix()); d.UpdatedAt = &s }
func providerStamp(t *time.Time) *model.Stamp {
	if t == nil {
		return nil
	}
	s := model.Stamp(t.Unix())
	return &s
}
func seriesFetch(p provider.Provider, symbol string, from, to model.Day) (provider.DailySeries, error) {
	if p.DailySeries == nil {
		return provider.DailySeries{}, Runtime("daily provider is unavailable")
	}
	return p.DailySeries(symbol, from, to)
}

func MarketImport(c Context, args []string) error {
	o, e := ParseOptions(args, nil, setOf("dry-run"))
	if e != nil {
		return e
	}
	if len(o.Positionals) != 1 {
		return usage("usage: dit market import <FILE> [--dry-run] — CSV lines 'SYMBOL,YYYY-MM-DD,PRICE' (# comments and blank lines skipped)")
	}
	path := o.Positionals[0]
	b, e := os.ReadFile(path)
	if e != nil || !utf8.Valid(b) {
		return Runtime(fmt.Sprintf("cannot read '%s' as UTF-8 text", path))
	}
	entries, problems := market.ParseCSV(string(b))
	if len(entries) == 0 {
		return Runtime(fmt.Sprintf("no usable 'SYMBOL,YYYY-MM-DD,PRICE' lines in '%s'", path))
	}
	// Import does not need (or decode) a portfolio.
	_, s, e := marketReadStores(c)
	if e != nil {
		return e
	}
	raw, e := s.Load(store.MarketKey)
	if e != nil {
		return e
	}
	d := readMarketCache(raw)
	grouped := map[string][]model.DailyPrice{}
	for _, v := range entries {
		grouped[v.Symbol] = append(grouped[v.Symbol], v.Point)
	}
	keys := []string{}
	for k := range grouped {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var out bytes.Buffer
	cc := c
	cc.Out = &out
	total := 0
	for _, symbol := range keys {
		ccy := model.Unknown
		if s := d.Series[symbol]; s != nil {
			ccy = s.Currency
		}
		pair := strings.Split(symbol, "/")
		if ccy == model.Unknown && len(pair) == 2 && model.Currency(pair[0]).IsKnown() && model.Currency(pair[1]).IsKnown() {
			ccy = model.Currency(pair[1])
		}
		n := market.Merge(&d, symbol, ccy, grouped[symbol], nil)
		total += n
		cc.printf("  %s: %d point(s) stored from %d line(s)\n", symbol, n, len(grouped[symbol]))
	}
	if o.Has("dry-run") {
		cc.printf("  dry run — nothing written\n")
	} else {
		writeNow(&d, time.Now())
		if e = saveWriteMarket(c, d); e != nil {
			return e
		}
		cc.printf("  %d point(s) added; imported observations replace derived values on the same day\n", total)
	}
	c.printf("Market import — %s\n", marketLocation(c))
	for i, p := range problems {
		if i == 8 {
			break
		}
		fmt.Fprintln(c.Err, "warning:", p)
	}
	if len(problems) > 8 {
		fmt.Fprintf(c.Err, "warning: ...and %d more unparsable line(s)\n", len(problems)-8)
	}
	c.printf("%s", out.String())
	return nil
}

func latestStage(c Context, p *model.Portfolio, d *model.MarketData, prov provider.Provider, now time.Time, announce bool) error {
	symbols, fx := providerPlan(p, c.Display, now)
	rows := [][]string{}
	warnings := []string{}
	if len(symbols) > 0 {
		quotes, e := prov.Quotes(symbols)
		if e != nil {
			return e
		}
		found := map[string]bool{}
		for _, q := range quotes {
			found[q.Symbol] = true
			kept := []model.MarketQuote{}
			for _, old := range d.LatestQuotes {
				if old.Symbol != q.Symbol {
					kept = append(kept, old)
				}
			}
			source := q.Source
			s := providerStamp(q.AsOf)
			d.LatestQuotes = append(kept, model.MarketQuote{Symbol: q.Symbol, Currency: q.Currency, Price: q.Price, AsOf: s, Source: &source})
			stamp := "unknown time"
			if s != nil {
				stamp = marketStamp(s, true)
			}
			ccy := q.Currency.Code()
			if !q.Currency.IsKnown() {
				ccy = "?"
			}
			rows = append(rows, []string{q.Symbol, text.Quantity(q.Price), ccy, stamp})
		}
		for _, s := range symbols {
			if !found[s] {
				warnings = append(warnings, "no quote: "+s)
			}
		}
	}
	for _, ccy := range fx {
		r, e := prov.Rate(model.ConversionHub, ccy)
		if e != nil {
			warnings = append(warnings, fmt.Sprintf("USD/%s rate failed: %s", ccy, e))
			continue
		}
		kept := []model.ExchangeRate{}
		for _, old := range d.LatestRates {
			if old.Base != r.Base || old.Quote != r.Quote {
				kept = append(kept, old)
			}
		}
		source := r.Source
		s := providerStamp(r.AsOf)
		d.LatestRates = append(kept, model.ExchangeRate{Base: r.Base, Quote: r.Quote, Rate: r.Rate, AsOf: s, Source: &source})
		stamp := now.In(time.Local).Format("2006-01-02 15:04")
		if s != nil {
			stamp = marketStamp(s, true)
		}
		rows = append(rows, []string{"USD/" + ccy.Code(), text.Quantity(r.Rate), ccy.Code(), stamp})
	}
	if len(symbols) > 0 || len(fx) > 0 {
		writeNow(d, now)
	}
	c.printf("Latest market data — %s\n", marketLocation(c))
	if len(rows) == 0 {
		if len(symbols) == 0 && len(fx) == 0 {
			c.printf("  no open positions and no foreign cash — nothing to update\n")
		}
	} else {
		sort.Slice(rows, func(i, j int) bool { return rows[i][0] < rows[j][0] })
		marketTable(c, []string{"Symbol/Pair", "Price", "Ccy", "As of (local)"}, rows, 0, 3)
	}
	for _, w := range warnings {
		fmt.Fprintln(c.Err, "warning:", w)
	}
	if announce {
		c.printf("next: 'dit market history' fills daily closes for every held day\n")
	}
	return nil
}
func MarketLatest(c Context, args []string) error {
	if c.Offline {
		return usage("'dit market latest' refreshes prices from the provider — --offline refuses the network (offline summaries use cost basis)")
	}
	// Swift's latest handler does not consume positional arguments.
	p, d, e := loadWriteMarket(c)
	if e != nil {
		return e
	}
	if p == nil {
		noMarketPortfolio(c)
		return nil
	}
	var out, errs bytes.Buffer
	cc := c
	cc.Out = &out
	cc.Err = &errs
	if e = latestStage(cc, p, &d, providerForCommand(), time.Now(), true); e != nil {
		return e
	}
	symbols, fx := providerPlan(p, c.Display, time.Now())
	if len(symbols) > 0 || len(fx) > 0 {
		if e = saveWriteMarket(c, d); e != nil {
			return e
		}
	}
	c.printf("%s", out.String())
	fmt.Fprint(c.Err, errs.String())
	return nil
}

type historyOutcome struct {
	name  string
	added int
}

func historyStage(c Context, p *model.Portfolio, d *model.MarketData, prov provider.Provider, now time.Time, all, rebuild bool) error {
	notes := []string{}
	if rebuild {
		notes = append(notes, fmt.Sprintf("erased stored history (%d series) — refetching everything", len(d.Series)))
		d.Series = map[string]*model.PriceSeries{}
	}
	today := model.DayFromUnix(now.Unix())
	windows := market.HoldingWindows(p, today)
	_, fx := providerPlan(p, c.Display, now)
	outcomes := []historyOutcome{}
	failures := []string{}
	fetched, total := 0, 0
	fetch := func(key, ticker string, start, end model.Day, ccy model.Currency, ws []market.Window) {
		existing := d.Series[key]
		if !all && !rebuild && existing != nil && existing.CoveredThrough != nil {
			if *existing.CoveredThrough >= end {
				outcomes = append(outcomes, historyOutcome{key, 0})
				return
			}
			start = *existing.CoveredThrough + 86400
		}
		if start > end {
			outcomes = append(outcomes, historyOutcome{key, 0})
			return
		}
		fetched++
		s, e := seriesFetch(prov, ticker, start, end)
		if e != nil {
			failures = append(failures, fmt.Sprintf("%s: history fetch failed: %s", key, e))
			return
		}
		points := []model.DailyPrice{}
		for _, pt := range s.Points {
			inside := ws == nil
			for _, w := range ws {
				if pt.Day >= w.Start && pt.Day <= w.End {
					inside = true
				}
			}
			if inside {
				points = append(points, pt)
			}
		}
		if ccy == model.Unknown {
			ccy = s.Currency
		}
		n := market.Merge(d, key, ccy, points, &end)
		total += n
		outcomes = append(outcomes, historyOutcome{key, n})
	}
	keys := []string{}
	for k := range windows {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		ws := windows[k]
		end := ws[len(ws)-1].End
		if end > today {
			end = today
		}
		fetch(k, k, ws[0].Start, end, model.Unknown, ws)
	}
	var earliest model.Day
	for _, tx := range p.Transactions {
		if earliest == 0 || tx.Date < earliest {
			earliest = tx.Date
		}
	}
	for _, ccy := range fx {
		if earliest != 0 {
			fetch("USD/"+ccy.Code(), fxTicker(model.USD, ccy), earliest, today, ccy, nil)
		}
	}
	if len(windows) == 0 && len(fx) == 0 {
		notes = append(notes, "nothing has ever been held — no history to fetch")
	} else {
		writeNow(d, now)
	}
	c.printf("Daily history — %s\n", marketLocation(c))
	for _, n := range notes {
		c.printf("  %s\n", n)
	}
	if total > 0 {
		changed := []string{}
		for _, r := range outcomes {
			if r.added > 0 {
				changed = append(changed, fmt.Sprintf("%s +%d", r.name, r.added))
			}
		}
		c.printf("  +%d new points stored (%s)\n", total, strings.Join(changed, ", "))
	}
	rows := [][]string{}
	for _, r := range outcomes {
		first, last, count := "—", "—", 0
		if s := d.Series[r.name]; s != nil && len(s.Points) > 0 {
			first = s.Points[0].Day.String()
			last = s.Points[len(s.Points)-1].Day.String()
			count = len(s.Points)
		}
		rows = append(rows, []string{r.name, first, last, fmt.Sprint(count)})
	}
	if len(rows) > 0 {
		marketTable(c, []string{"Ticker", "Earliest", "Latest", "Quotes"}, rows, 0, 1, 2)
	} else if len(notes) == 0 {
		c.printf("  no series to maintain (nothing has ever been held)\n")
	}
	for _, w := range failures {
		fmt.Fprintln(c.Err, "warning:", w)
	}
	if total == 0 && fetched > 0 && len(failures) >= fetched {
		return Runtime("every history fetch failed — check the network and retry")
	}
	return nil
}
func fxTicker(from, to model.Currency) string {
	if from == model.USD {
		return to.Code() + "=X"
	}
	return from.Code() + to.Code() + "=X"
}
func marketHistoryWrite(c Context, o Options) error {
	p, d, e := loadWriteMarket(c)
	if e != nil {
		return e
	}
	if p == nil {
		noMarketPortfolio(c)
		return nil
	}
	var out, errs bytes.Buffer
	cc := c
	cc.Out = &out
	cc.Err = &errs
	e = historyStage(cc, p, &d, providerForCommand(), time.Now(), o.Has("all"), o.Has("rebuild"))
	_, fx := providerPlan(p, c.Display, time.Now())
	if e == nil && (len(market.HoldingWindows(p, model.DayFromUnix(time.Now().Unix()))) > 0 || len(fx) > 0) {
		e = saveWriteMarket(c, d)
	}
	c.printf("%s", out.String())
	fmt.Fprint(c.Err, errs.String())
	return e
}
func Update(c Context, args []string) error {
	if c.Offline {
		return usage("'dit update' downloads prices from the provider — --offline refuses the network (offline mode exists to *avoid* fetching)")
	}
	o, e := ParseOptions(args, nil, setOf("quick", "rebuild"))
	if e != nil {
		return e
	}
	if len(o.Positionals) > 0 {
		return usage(fmt.Sprintf("unexpected argument '%s' — 'dit update' takes only --quick / --rebuild (per-part control lives under 'dit market …')", o.Positionals[0]))
	}
	p, d, e := loadWriteMarket(c)
	if e != nil {
		return e
	}
	if p == nil {
		noMarketPortfolio(c)
		return nil
	}
	var out, errs bytes.Buffer
	cc := c
	cc.Out = &out
	cc.Err = &errs
	prov := providerForCommand()
	now := time.Now()
	if e = latestStage(cc, p, &d, prov, now, false); e != nil {
		return e
	}
	cc.printf("\n")
	e = historyStage(cc, p, &d, prov, now, !o.Has("quick") && !o.Has("rebuild"), o.Has("rebuild"))
	if e != nil {
		c.printf("%s", out.String())
		fmt.Fprint(c.Err, errs.String())
		return e
	}
	symbols, fx := providerPlan(p, c.Display, now)
	if len(symbols) > 0 || len(fx) > 0 || len(market.HoldingWindows(p, model.DayFromUnix(now.Unix()))) > 0 {
		if e = saveWriteMarket(c, d); e != nil {
			return e
		}
	}
	cc.printf("\n")
	e = MarketCoverage(cc, nil)
	c.printf("%s", out.String())
	fmt.Fprint(c.Err, errs.String())
	return e
}

// Positive ratios use the same decimal-only parsing boundary as import.
func backfillRatio(raw string) (decimal.Decimal, error) {
	d, e := market.FoundationDecimal(raw)
	if e != nil || d.Sign() <= 0 {
		return decimal.Zero, usage(fmt.Sprintf("--ratio needs a positive number (got '%s')", raw))
	}
	return d, nil
}
