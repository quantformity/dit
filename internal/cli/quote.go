package cli

import (
	"fmt"
	"strings"
	"time"
	"unicode"

	"dit/internal/model"
	"dit/internal/provider"
	"dit/internal/text"
)

var quoteSpecs = Registry{"quote": {Run: QuoteLookup, SkipParse: true, HelpText: quoteHelp}}

// QuoteLookup receives ALL symbol tokens, including the dispatch sub-word.
// Live mode deliberately does not load or write a store: the reference only
// uses stored closes in historical mode, not as a silent live substitute.
func QuoteLookup(c Context, args []string) error {
	if len(args) == 0 || strings.HasPrefix(args[0], "--") {
		return usage("usage: dit quote <SYMBOL> [SYMBOL ...] — see 'dit help quote'")
	}
	first := args[0]
	o, err := ParseOptions(args[1:], setOf("as-of", "from", "to"), nil)
	if err != nil {
		return err
	}
	_, as := o.Values["as-of"]
	_, from := o.Values["from"]
	_, to := o.Values["to"]
	if as && (from || to) {
		return usage("--as-of (one point) and --from/--to (a range) cannot be combined — pick one view")
	}
	parts := strings.Split(strings.ToUpper(first), "/")
	chain := len(parts) >= 3
	for _, p := range parts {
		if len([]rune(p)) != 3 {
			chain = false
		}
		for _, r := range p {
			if !unicode.IsLetter(r) {
				chain = false
			}
		}
	}
	if chain {
		if len(o.Positionals) > 0 {
			return usage("an FX matrix must be the only request — quote other symbols separately")
		}
		if from || to {
			return usage("the FX matrix is single-day — use --as-of for one day, or 'dit quote USD/CAD --from … --to …' for a series")
		}
		seen := map[model.Currency]bool{}
		currencies := []model.Currency{}
		for _, p := range parts {
			ccy := model.Currency(p)
			if !ccy.IsKnown() || seen[ccy] {
				return usage(fmt.Sprintf("unknown currency in '%s' — the matrix needs known ISO codes (see 'dit help quote')", first))
			}
			seen[ccy] = true
			currencies = append(currencies, ccy)
		}
		return quoteMatrix(c, currencies, first, o)
	}
	if !as && !from && !to && c.Offline {
		return usage("'dit quote' needs the network for live prices — drop --offline (offline mode exists to *avoid* fetching)")
	}
	symbols := append([]string{first}, o.Positionals...)
	for i, s := range symbols {
		symbols[i] = model.NormalizeSymbol(s)
		if symbols[i] == "" {
			return usage("--ticker cannot be empty")
		}
	}
	if as || from || to {
		return quoteHistorical(c, symbols, o, as)
	}
	return quoteLive(c, symbols, providerForCommand())
}

func quotePair(symbol string) (model.Currency, model.Currency, bool) {
	parts := strings.Split(symbol, "/")
	if len(parts) != 2 {
		return "", "", false
	}
	a, b := model.Currency(parts[0]), model.Currency(parts[1])
	return a, b, a.IsKnown() && b.IsKnown() && a != b
}
func quoteClock(t time.Time) string { return t.In(time.Local).Format("Jan 2, 2006 at 3:04\u202fPM") }
func quoteLive(c Context, symbols []string, p provider.Provider) error {
	by := map[string]provider.Quote{}
	equities := []string{}
	pairs := []string{}
	for _, s := range symbols {
		if _, _, ok := quotePair(s); ok {
			pairs = append(pairs, s)
		} else {
			equities = append(equities, s)
		}
	}
	if len(equities) > 0 {
		qs, err := p.Quotes(equities)
		if err != nil {
			return Runtime("live quote fetch failed: " + err.Error())
		}
		for _, q := range qs {
			by[q.Symbol] = q
		}
	}
	for _, s := range pairs {
		a, b, _ := quotePair(s)
		if r, err := p.Rate(a, b); err == nil {
			by[s] = provider.Quote{Symbol: s, Currency: b, Price: r.Rate, AsOf: r.AsOf, Source: r.Source}
		}
	}
	missing := []string{}
	rows := [][]string{}
	entries := []map[string]any{}
	for _, s := range symbols {
		entry := map[string]any{"symbol": s, "price": nil, "ccy": nil, "asOf": nil, "source": nil, "basis": "none"}
		q, ok := by[s]
		if !ok {
			missing = append(missing, s)
			rows = append(rows, []string{s, "(none)", "", "", ""})
		} else {
			ccy := "??"
			if q.Currency != model.Unknown {
				ccy = q.Currency.Code()
				entry["ccy"] = ccy
			}
			stamp := "unknown"
			if q.AsOf != nil {
				stamp = quoteClock(*q.AsOf)
				entry["asOf"] = q.AsOf.UTC().Format("2006-01-02T15:04:05Z")
			}
			source := "?"
			if q.Source != "" {
				source = q.Source
				entry["source"] = source
			}
			scale := int32(2)
			if _, _, pair := quotePair(s); pair {
				scale = 6
			}
			entry["symbol"] = q.Symbol
			entry["price"] = quoteFixed(q.Price, scale)
			entry["basis"] = "live"
			rows = append(rows, []string{q.Symbol, quoteQuantity(q.Price), ccy, stamp, source})
		}
		entries = append(entries, entry)
	}
	failure := Runtime("no live quotes available for: " + strings.Join(symbols, ", "))
	if c.JSON {
		if len(by) == 0 {
			return failure
		}
		return quoteJSON(c, map[string]any{"mode": "live", "quotes": entries})
	}
	c.printf("Live quotes:\n")
	marketTable(c, []string{"Symbol", "Price", "Ccy", "AsOf", "Source"}, rows)
	if len(missing) > 0 {
		c.printf("no quote found: %s\n", strings.Join(missing, ", "))
	}
	if len(by) == 0 {
		return failure
	}
	return nil
}
func quoteJSON(c Context, data map[string]any) error {
	return c.WriteJSON(map[string]any{"ok": true, "schema": "quote/1", "data": data})
}
func quoteDate(raw string) (model.Day, error) {
	t, err := time.Parse("2006-01-02", raw)
	if err != nil {
		return 0, usage(fmt.Sprintf("invalid date '%s' — expected YYYY-MM-DD", raw))
	}
	return model.Day(t.Unix()), nil
}
func quoteDay(d model.Day) string { return time.Unix(int64(d), 0).UTC().Format("2006-01-02") }
func quoteMarket(c Context) (model.MarketData, error) {
	_, s, err := marketReadStores(c)
	if err != nil {
		return model.MarketData{}, err
	}
	payload, err := s.Load("market")
	if err != nil {
		return model.MarketData{}, err
	}
	return readMarketCache(payload), nil
}

func quoteHistorical(c Context, symbols []string, o Options, as bool) error {
	dates := map[string]model.Day{}
	for _, key := range []string{"as-of", "from", "to"} {
		if raw, ok := o.Values[key]; ok {
			d, err := quoteDate(raw)
			if err != nil {
				return err
			}
			dates[key] = d
		}
	}
	if f, ok := dates["from"]; ok {
		if t, ok := dates["to"]; ok && t < f {
			return usage(fmt.Sprintf("--to '%s' is before --from '%s'", o.Value("to"), o.Value("from")))
		}
	}
	m, err := quoteMarket(c)
	if err != nil {
		return err
	}
	if as {
		return quoteAsOf(c, m, symbols, dates["as-of"])
	}
	return quoteRange(c, m, symbols, dates)
}
func quoteAsOf(c Context, m model.MarketData, symbols []string, day model.Day) error {
	rows := [][]string{}
	entries := []map[string]any{}
	missing := []string{}
	for _, s := range symbols {
		entry := map[string]any{"symbol": s, "price": nil, "ccy": nil, "date": nil, "basis": "none", "via": nil}
		point, ok := m.CloseOnOrBefore(s, day)
		if !ok {
			missing = append(missing, s)
			rows = append(rows, []string{s, "(none)", "", "", "no stored quote"})
		} else {
			lag := int((day - point.Day) / 86400)
			on := quoteDay(point.Day)
			if lag != 0 {
				on += fmt.Sprintf(" (%dd earlier)", lag)
			}
			ccy := "?"
			if series := m.SeriesFor(s); series != nil && series.Currency != model.Unknown {
				ccy = series.Currency.Code()
				entry["ccy"] = ccy
			}
			provenance := "observed"
			entry["basis"] = "observed"
			if point.Via != "" {
				provenance = "backfilled — " + point.Via
				entry["basis"] = "derived"
				entry["via"] = point.Via
			}
			entry["date"] = quoteDay(point.Day)
			entry["price"] = quoteFixed(point.Price, 2)
			entry["lagDays"] = lag
			rows = append(rows, []string{s, quoteQuantity(point.Price), ccy, on, provenance})
		}
		entries = append(entries, entry)
	}
	failure := Runtime("no stored quotes for: " + strings.Join(symbols, ", ") + " — the market store is empty for these; run 'dit market history'")
	if c.JSON {
		if len(missing) == len(symbols) {
			return failure
		}
		return quoteJSON(c, map[string]any{"mode": "store", "asOf": quoteDay(day), "store": c.Layout.MarketDir, "quotes": entries})
	}
	c.printf("Historical quotes — %s\n  as of %s — read from the market store, nothing fetched\n", marketLocation(c), quoteDay(day))
	marketTable(c, []string{"Symbol", "Price", "Ccy", "On", "Provenance"}, rows, 0, 3, 4)
	if len(missing) > 0 {
		c.printf("no stored quote for: %s — 'dit market history' fills this store (derive proxy history with 'dit market backfill', fill with 'dit market import')\n", strings.Join(missing, ", "))
	}
	if len(missing) == len(symbols) {
		return failure
	}
	return nil
}

func quoteRange(c Context, m model.MarketData, symbols []string, dates map[string]model.Day) error {
	to, hasTo := dates["to"]
	if !hasTo {
		to = model.DayFromUnix(time.Now().Unix())
	}
	from, hasFrom := dates["from"]
	fromText := "the beginning"
	if hasFrom {
		fromText = quoteDay(from)
	}
	toText := quoteDay(to)
	if !hasTo {
		toText = "today (" + toText + ")"
	}
	rangeText := fromText + " … " + toText
	entries := []map[string]any{}
	missing := []string{}
	count := 0
	if !c.JSON {
		c.printf("Historical closes — %s\n  %s — read from the market store, nothing fetched\n", marketLocation(c), rangeText)
	}
	for _, s := range symbols {
		points := []model.DailyPrice{}
		series := m.SeriesFor(s)
		ccy := "?"
		if series != nil {
			if series.Currency != model.Unknown {
				ccy = series.Currency.Code()
			}
			for _, p := range series.Points {
				if p.Day <= to && (!hasFrom || p.Day >= from) {
					points = append(points, p)
				}
			}
		}
		if len(points) == 0 {
			missing = append(missing, s)
			entries = append(entries, map[string]any{"symbol": s, "date": nil, "price": nil, "ccy": nil, "basis": "none", "via": nil})
			continue
		}
		count += len(points)
		rows := [][]string{}
		for _, p := range points {
			basis, provenance := "observed", "observed"
			var via any
			if p.Via != "" {
				basis = "derived"
				provenance = "backfilled — " + p.Via
				via = p.Via
			}
			var currency any
			if ccy != "?" {
				currency = ccy
			}
			entries = append(entries, map[string]any{"symbol": s, "date": quoteDay(p.Day), "price": quoteFixed(p.Price, 2), "ccy": currency, "basis": basis, "via": via})
			rows = append(rows, []string{quoteDay(p.Day), quoteQuantity(p.Price), provenance})
		}
		if !c.JSON {
			plural := ""
			if len(points) != 1 {
				plural = "s"
			}
			c.printf("\n  %s (%s) — %d close%s\n", s, ccy, len(points), plural)
			for _, line := range text.Table([]string{"Date", "Price", "Provenance"}, rows, map[int]bool{0: true, 2: true}, boldHeaders(c)) {
				c.printf("    %s\n", line)
			}
		}
	}
	if c.JSON {
		if count == 0 {
			return Runtime("no stored closes for: " + strings.Join(symbols, ", ") + " in " + rangeText + " — 'dit market history' fills this store")
		}
		var f, t any
		if hasFrom {
			f = quoteDay(from)
		}
		if hasTo {
			t = quoteDay(to)
		}
		return quoteJSON(c, map[string]any{"mode": "series", "from": f, "to": t, "count": count, "store": c.Layout.MarketDir, "quotes": entries})
	}
	if len(missing) > 0 {
		c.printf("\nno stored closes for: %s — 'dit market history' fills this store (derive proxy history with 'dit market backfill', fill with 'dit market import')\n", strings.Join(missing, ", "))
	}
	if count == 0 {
		return Runtime("no stored closes for: " + strings.Join(symbols, ", ") + " in " + rangeText + " — the market store is empty for these; run 'dit market history'")
	}
	return nil
}
