package cli

import (
	"encoding/json"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"dit/internal/market"
	"dit/internal/model"
	"dit/internal/store"
	"dit/internal/text"
)

var marketSpecs = mergeLayers(marketWriteSpecs, Registry{
	"market history":  {Run: MarketHistory, ValueOptions: setOf("from", "to"), FlagOptions: setOf("all", "rebuild")},
	"market show":     {Run: MarketShow, ValueOptions: setOf("symbol", "days")},
	"market coverage": {Run: MarketCoverage, ValueOptions: setOf("from", "to", "account", "tickers", "reporting-ccy"), FlagOptions: setOf("strict")},
})

// File-store construction creates directories. Read-only commands instead
// supply only Load; absent directories must remain absent after inspection.
func marketReadStores(c Context) (store.Store, store.Store, error) {
	// Every read goes through transferRead: it consults the saved remote
	// connection first and falls back to the local store, so a connected
	// client on a machine without its own portfolio reads the remote, never
	// the empty local store. The Location keeps the local path for labels.
	reader := func(path string) store.Store {
		return store.Store{Location: path, Load: func(key string) ([]byte, error) {
			return transferRead(c, path, key)
		}}
	}
	return reader(c.Layout.PortfolioDir), reader(c.Layout.MarketDir), nil
}

// Only the refetchable cache can lose malformed sections. Ledger decoding
// still goes through store.LoadPortfolio and propagates every error.
func readMarketCache(payload []byte) model.MarketData {
	out := model.MarketData{LatestQuotes: []model.MarketQuote{}, LatestRates: []model.ExchangeRate{}, Series: map[string]*model.PriceSeries{}}
	var fields map[string]json.RawMessage
	if json.Unmarshal(payload, &fields) != nil {
		return out
	}
	if json.Unmarshal(fields["updatedAt"], &out.UpdatedAt) != nil {
		out.UpdatedAt = nil
	}
	for _, section := range []string{"latestQuotes", "latestRates", "series"} {
		if raw, ok := fields[section]; ok {
			wrapped, _ := json.Marshal(map[string]json.RawMessage{section: raw})
			var part model.MarketData
			_ = json.Unmarshal(wrapped, &part)
			switch section {
			case "latestQuotes":
				out.LatestQuotes = part.LatestQuotes
			case "latestRates":
				out.LatestRates = part.LatestRates
			case "series":
				out.Series = part.Series
			}
		}
	}
	for _, s := range out.Series {
		if s.Currency == "" {
			s.Currency = model.Unknown
		}
	}
	return out
}
func marketLocation(c Context) string {
	return fmt.Sprintf("%s at %s", c.Layout.Backend, c.Layout.MarketDir)
}
func marketTable(c Context, headers []string, rows [][]string, left ...int) {
	alignment := map[int]bool{}
	for _, i := range left {
		alignment[i] = true
	}
	for _, line := range text.Table(headers, rows, alignment, boldHeaders(c)) {
		c.printf("  %s\n", line)
	}
}
func marketStamp(s *model.Stamp, compact bool) string {
	if s == nil {
		if compact {
			return "unknown"
		}
		return "an unknown time"
	}
	t := time.Unix(int64(*s), 0).In(time.Local)
	if compact {
		return t.Format("2006-01-02 15:04")
	}
	return t.Format("Jan 2, 2006") + " at " + t.Format("3:04\u202fPM")
}
func marketStray(o Options, hint string) error {
	if len(o.Positionals) > 0 {
		return usage(fmt.Sprintf("unexpected argument '%s' — %s", o.Positionals[0], hint))
	}
	return nil
}
func MarketHistory(c Context, args []string) error {
	if c.Offline {
		return usage("'dit market history' fetches daily closes — --offline refuses the network")
	}
	o, err := ParseOptions(args, setOf("from", "to"), setOf("all", "rebuild"))
	if err != nil {
		return err
	}
	if err = marketStray(o, "'dit market history' takes only --all / --rebuild / --from / --to (see 'dit help market')"); err != nil {
		return err
	}
	if o.Has("all") && o.Has("rebuild") {
		return usage("--all and --rebuild conflict — --all fills gaps but KEEPS stored closes, --rebuild erases the daily history first (pick one)")
	}
	if _, ok := o.Values["from"]; ok {
		return usage("--from/--to are not wired yet — history currently spans each symbol's full holding window; use 'dit market history --all' to re-verify it or --rebuild to erase and refetch")
	}
	if _, ok := o.Values["to"]; ok {
		return usage("--from/--to are not wired yet — history currently spans each symbol's full holding window; use 'dit market history --all' to re-verify it or --rebuild to erase and refetch")
	}
	return marketHistoryWrite(c, o)
}
func MarketShow(c Context, args []string) error {
	if c.JSON {
		return usage("--json is not supported for 'market show'")
	}
	o, err := ParseOptions(args, setOf("symbol", "days"), nil)
	if err != nil {
		return err
	}
	if err = marketStray(o, "filter both tables with --symbol (see 'dit help market')"); err != nil {
		return err
	}
	_, ms, err := marketReadStores(c)
	if err != nil {
		return err
	}
	payload, err := ms.Load("market")
	if err != nil {
		return err
	}
	data := readMarketCache(payload)
	symbol := model.NormalizeSymbol(o.Value("symbol"))
	tail := 0
	if raw, ok := o.Values["days"]; ok {
		tail, err = strconv.Atoi(raw)
		if err != nil || tail <= 0 {
			return usage(fmt.Sprintf("--days needs a positive number (got '%s')", raw))
		}
	}
	c.printf("Market data — %s\n", marketLocation(c))
	if len(data.LatestQuotes) == 0 && len(data.LatestRates) == 0 && len(data.Series) == 0 {
		c.printf("  empty — run 'dit market latest' (current prices) and 'dit market history' (daily closes) to fill it\n")
		return nil
	}
	c.printf("  updated: %s\n", marketStamp(data.UpdatedAt, false))
	keys := []string{}
	for k := range data.Series {
		if symbol == "" || k == symbol {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	quotes := append([]model.MarketQuote{}, data.LatestQuotes...)
	rates := append([]model.ExchangeRate{}, data.LatestRates...)
	sort.Slice(quotes, func(i, j int) bool { return quotes[i].Symbol < quotes[j].Symbol })
	sort.SliceStable(rates, func(i, j int) bool { return rates[i].Base < rates[j].Base })
	rows := [][]string{}
	for _, q := range quotes {
		if symbol != "" && symbol != q.Symbol {
			continue
		}
		ccy := string(q.Currency)
		if q.Currency == model.Unknown {
			ccy = "?"
		}
		rows = append(rows, []string{q.Symbol, text.Quantity(q.Price), ccy, marketStamp(q.AsOf, true)})
	}
	for _, r := range rates {
		key := string(r.Base) + "/" + string(r.Quote)
		if symbol != "" && symbol != key {
			continue
		}
		rows = append(rows, []string{key, text.Quantity(r.Rate), string(r.Quote), marketStamp(r.AsOf, true)})
	}
	if symbol != "" && len(rows) == 0 && len(keys) == 0 {
		c.printf("  nothing stored for '%s' — 'dit market latest' / 'dit market history' fill this store\n", symbol)
		return nil
	}
	if len(rows) > 0 {
		c.printf("\nLatest (one per symbol, overwritten by 'dit market latest'):\n")
		marketTable(c, []string{"Symbol", "Price", "Ccy", "As of (local)"}, rows, 0)
	}
	if len(keys) == 0 {
		return nil
	}
	c.printf("\nHistory (%d series):\n", len(keys))
	rows = [][]string{}
	for _, key := range keys {
		s := data.Series[key]
		source := "observed"
		derived := 0
		label := ""
		first, last := "—", "—"
		for _, p := range s.Points {
			if p.Via != "" {
				derived++
				if label == "" {
					label = p.Via
				}
			}
		}
		if derived > 0 {
			source = fmt.Sprintf("%s — %d/%d pts", label, derived, len(s.Points))
		}
		if len(s.Points) > 0 {
			first = s.Points[0].Day.String()
			last = s.Points[len(s.Points)-1].Day.String()
		}
		ccy := string(s.Currency)
		if s.Currency == model.Unknown || ccy == "" {
			ccy = "?"
		}
		rows = append(rows, []string{key, ccy, strconv.Itoa(len(s.Points)), first, last, source})
	}
	marketTable(c, []string{"Symbol", "Ccy", "Points", "First", "Last", "Source"}, rows, 0, 1, 3, 4, 5)
	if s := data.Series[symbol]; s != nil && tail > 0 {
		n := tail
		if n > len(s.Points) {
			n = len(s.Points)
		}
		c.printf("\n  last %d close(s) for %s:\n", n, symbol)
		for _, p := range s.Points[len(s.Points)-n:] {
			suffix := ""
			if p.Via != "" {
				suffix = "   (derived)"
			}
			c.printf("    %s  %s%s\n", p.Day.String(), text.Quantity(p.Price), suffix)
		}
	}
	return nil
}
func marketCSV(raw string) []string {
	out := []string{}
	for _, v := range strings.Split(raw, ",") {
		if v = strings.TrimSpace(v); v != "" {
			out = append(out, v)
		}
	}
	return out
}
func coverageAccount(raw string, p model.Portfolio) (model.Account, error) {
	query := strings.TrimSpace(raw)
	if query == "" {
		return model.Account{}, usage("an account name or UUID is required")
	}
	matches := []model.Account{}
	hexQuery := strings.ToUpper(strings.ReplaceAll(query, "-", ""))
	looksHex := len(hexQuery) >= 4
	for _, c := range hexQuery {
		if !strings.ContainsRune("0123456789ABCDEF", c) {
			looksHex = false
		}
	}
	if looksHex {
		for _, a := range p.Accounts {
			id := strings.ToUpper(strings.ReplaceAll(a.ID, "-", ""))
			if id == hexQuery {
				return a, nil
			}
			if strings.HasPrefix(id, hexQuery) {
				matches = append(matches, a)
			}
		}
	}
	if len(matches) == 0 {
		for _, a := range p.Accounts {
			if a.Name != nil && strings.EqualFold(strings.TrimSpace(*a.Name), query) {
				matches = append(matches, a)
			}
		}
	}
	if len(matches) == 1 {
		return matches[0], nil
	}
	if len(matches) > 1 {
		names := []string{}
		for _, a := range matches {
			names = append(names, DisplayName(a))
		}
		return model.Account{}, Runtime(fmt.Sprintf("'%s' is ambiguous — it matches: %s. Use a longer name or the full UUID.", query, strings.Join(names, ", ")))
	}
	if len([]rune(query)) >= 2 {
		lower := strings.ToLower(query)
		prefix := string([]rune(lower)[:2])
		best := ""
		score := 0
		for _, a := range p.Accounts {
			name := DisplayName(a)
			lowered := strings.ToLower(name)
			n := 0
			if strings.Contains(lowered, lower) || strings.Contains(lower, lowered) {
				n = 2
				if len([]rune(name)) <= 16 {
					n = 3
				}
			} else if strings.HasPrefix(lowered, prefix) {
				n = 1
			}
			if n > score {
				score = n
				best = name
			}
		}
		if best != "" {
			return model.Account{}, Runtime(fmt.Sprintf("no account matches '%s' — did you mean '%s'? — use the exact name (see 'dit accounts') or a UUID prefix", query, best))
		}
	}
	return model.Account{}, Runtime(fmt.Sprintf("no account matches '%s' — use the exact name (see 'dit accounts') or a UUID prefix; if this portfolio should have one, start with 'dit account add'", query))
}
func MarketCoverage(c Context, args []string) error {
	o, err := ParseOptions(args, setOf("from", "to", "account", "tickers", "reporting-ccy"), setOf("strict"))
	if err != nil {
		return err
	}
	if err = marketStray(o, "'dit market coverage' filters with --account/--tickers/--from/--to (see 'dit help market')"); err != nil {
		return err
	}
	var from, to *model.Day
	for _, key := range []string{"from", "to"} {
		if raw, ok := o.Values[key]; ok {
			d, e := model.ParseDay(raw)
			if e != nil || len(raw) != 10 || d.String() != raw {
				return usage(fmt.Sprintf("invalid date '%s' — expected YYYY-MM-DD", raw))
			}
			if key == "from" {
				from = &d
			} else {
				to = &d
			}
		}
	}
	if from != nil && to != nil && *to < *from {
		return usage(fmt.Sprintf("--to '%s' is before --from '%s'", o.Value("to"), o.Value("from")))
	}
	ledger, ms, err := marketReadStores(c)
	if err != nil {
		return err
	}
	p, err := store.LoadPortfolio(ledger)
	if err != nil {
		return err
	}
	envelope := func(data map[string]any) error {
		return c.WriteJSON(map[string]any{"data": data, "ok": true, "schema": "coverage/1"})
	}
	if p == nil {
		if c.JSON {
			return envelope(map[string]any{"empty": true, "note": "no portfolio found — add accounts and transactions first", "store": c.Layout.PortfolioDir})
		}
		c.printf("No portfolio found (store: %s at %s).\nNothing to check — add accounts and transactions first.\n", c.Layout.Backend, c.Layout.PortfolioDir)
		return nil
	}
	accounts := p.Accounts
	if raw, ok := o.Values["account"]; ok {
		names := marketCSV(raw)
		if len(names) == 0 {
			return usage("--account needs at least one account name (see 'dit accounts')")
		}
		accounts = []model.Account{}
		seen := map[string]bool{}
		for _, name := range names {
			a, e := coverageAccount(name, *p)
			if e != nil {
				return e
			}
			if !seen[a.ID] {
				accounts = append(accounts, a)
				seen[a.ID] = true
			}
		}
	}
	filter := map[string]bool{}
	if raw, ok := o.Values["tickers"]; ok {
		names := marketCSV(raw)
		if len(names) == 0 {
			return usage("--tickers needs at least one symbol")
		}
		for _, s := range names {
			filter[model.NormalizeSymbol(s)] = true
		}
	}
	data := model.MarketData{}
	notes := []string{}
	payload, e := ms.Load("market")
	if e != nil {
		notes = append(notes, fmt.Sprintf("market store unreadable (%s) — every row below reports NO DATA", e))
	} else {
		data = readMarketCache(payload)
	}
	reporting := c.Display
	if raw, ok := o.Values["reporting-ccy"]; ok {
		reporting = model.Currency(strings.ToUpper(raw))
		valid := false
		for _, ccy := range model.KnownCurrencies() {
			if reporting == ccy {
				valid = true
			}
		}
		if !valid {
			return usage(fmt.Sprintf("unknown currency '%s' for --reporting-ccy — use e.g. CAD, USD, JPY, or GBp", raw))
		}
	}
	asOf := model.Day(model.DayStartUTC(time.Now().Unix()))
	if to != nil {
		asOf = *to
	}
	r := market.Report(*p, accounts, asOf, from, reporting, data)
	filterNote := ""
	if len(filter) > 0 {
		shown := []market.SymbolCoverage{}
		unmatched := map[string]bool{}
		for s := range filter {
			unmatched[s] = true
		}
		for _, s := range r.Symbols {
			if filter[s.Symbol] {
				shown = append(shown, s)
				delete(unmatched, s.Symbol)
			}
		}
		r.Symbols = shown
		if len(unmatched) > 0 {
			list := []string{}
			for s := range unmatched {
				list = append(list, s)
			}
			sort.Strings(list)
			filterNote = "nothing held at the audit date matches --tickers " + strings.Join(list, ", ") + " (filters narrow, they never guess)"
		}
	}
	names := []string{}
	for _, a := range accounts {
		names = append(names, DisplayName(a))
	}
	if c.JSON {
		prices := []any{}
		fx := []any{}
		for _, s := range r.Symbols {
			row := map[string]any{"accounts": s.Accounts, "currency": s.Currency, "status": s.Status(), "symbol": s.Symbol, "derived": s.Derived, "points": s.PointsInWindow}
			if s.LastClose != nil {
				row["lastClose"] = s.LastClose.String()
				row["staleDays"] = *s.StaleDays
			}
			if g := s.LongestGap; g != nil {
				row["longestGap"] = map[string]any{"days": g.Days, "from": g.From.String(), "to": g.To.String()}
			}
			prices = append(prices, row)
		}
		for _, f := range r.FX {
			label := f.ChainLabel
			if label == "" {
				label = "none"
			}
			row := map[string]any{"chain": label, "from": f.From, "to": f.To, "usableNow": f.UsableNow, "boundariesMissing": f.BoundariesMissing, "boundariesTotal": f.BoundariesTotal}
			if f.LastAsOf != nil {
				row["lastClose"] = f.LastAsOf.String()
				row["staleDays"] = *f.StaleDays
			}
			if strings.HasPrefix(f.ChainLabel, "derived") {
				row["approx"] = true
			}
			fx = append(fx, row)
		}
		var scope any = names
		if len(accounts) == len(p.Accounts) && len(accounts) > 1 {
			scope = "all accounts"
		}
		doc := map[string]any{"auditDate": r.AsOf.String(), "complete": r.Complete(), "fx": fx, "notes": notes, "prices": prices, "reporting": reporting, "scope": scope, "seriesSlicing": r.SeriesGranularity, "window": map[string]any{"from": r.WindowStart.String(), "to": r.AsOf.String()}}
		if r.IsEmpty() {
			doc["empty"] = true
		}
		if filterNote != "" {
			doc["filterNote"] = filterNote
		}
		if err := envelope(doc); err != nil {
			return err
		}
		if o.Has("strict") && !r.Complete() {
			return coverageStrictJSON{}
		}
		return nil
	}
	c.printf("Market coverage — %s\n  audit date %s · window %s … %s · reporting into %s\n", marketLocation(c), r.AsOf.String(), r.WindowStart.String(), r.AsOf.String(), reporting)
	if len(accounts) == len(p.Accounts) {
		c.printf("  scope: all %d account(s)\n", len(accounts))
	} else {
		c.printf("  scope: %s\n", strings.Join(names, ", "))
	}
	for _, n := range notes {
		c.printf("  note: %s\n", n)
	}
	if filterNote != "" {
		c.printf("  %s\n", filterNote)
	}
	if r.IsEmpty() {
		c.printf("\n  Nothing held at the audit date (no open positions, no foreign cash) — nothing to cover.\n")
		return nil
	}
	if len(r.Symbols) > 0 {
		c.printf("\nPrices (per held symbol and its recorded currency):\n")
		rows := [][]string{}
		for _, s := range r.Symbols {
			rows = append(rows, []string{s.Symbol, string(s.Currency), strings.Join(s.Accounts, ", "), coveragePriceCell(s)})
		}
		marketTable(c, []string{"Symbol", "Ccy", "Accounts", "Coverage"}, rows, 0, 1, 2, 3)
	}
	if len(r.FX) > 0 {
		c.printf("\nFX into %s (what combining foreign totals needs):\n", reporting)
		rows := [][]string{}
		for _, f := range r.FX {
			rows = append(rows, []string{string(f.From) + "→" + string(f.To), coverageFXCell(f)})
		}
		marketTable(c, []string{"Chain", "Coverage"}, rows, 0, 1)
	}
	derived, gaps, stale, missing := false, false, false, false
	for _, s := range r.Symbols {
		derived = derived || s.Derived
		gaps = gaps || s.LongestGap != nil
		stale = stale || (s.StaleDays != nil && *s.StaleDays > 7)
		missing = missing || !s.Measurable()
	}
	for _, f := range r.FX {
		derived = derived || strings.HasPrefix(f.ChainLabel, "derived")
		stale = stale || (!f.UsableNow && f.ChainLabel != "")
		missing = missing || f.ChainLabel == ""
	}
	if derived || gaps || stale || missing {
		c.printf("\n")
	}
	if derived {
		c.printf("  * derived price proxy · ~ derived FX chain (inverted/cross) — labelled approximations, NOT missing data\n")
	}
	if gaps {
		c.printf("  GAPS = holes of ≥ 10 missing days; shorter runs are weekend/holiday dust (weekday-sampled data) and stay unlisted\n")
	}
	if stale {
		c.printf("  STALE = last data older than 7 days — FX conversion REFUSES it (dashes); stale prices are still used, labelled\n")
	}
	if missing {
		c.printf("  NO DATA / WRONG CCY / NO CHAIN → 'dit market history' fetches what is missing, 'dit market import FILE' seeds measured data\n")
	}
	if o.Has("strict") && !r.Complete() {
		return Runtime("coverage gaps listed above — 'dit market history' fetches, 'dit market import' seeds")
	}
	return nil
}

// Dispatch must recognize this sentinel as exit 1 without printing another
// document. The audit already describes the strict failure in complete:false.
type coverageStrictJSON struct{}

func (coverageStrictJSON) Error() string { return "coverage incomplete" }

func coveragePriceCell(r market.SymbolCoverage) string {
	parts := []string{}
	switch r.Status() {
	case "no-data":
		if !r.SeriesFound {
			parts = append(parts, fmt.Sprintf("NO DATA — no daily series for %s — P&L dashes, summary values at cost", r.Symbol))
		} else if s := r.SeriesRange; s != nil {
			parts = append(parts, fmt.Sprintf("NO USABLE CLOSES in window — series runs %s…%s", s.First.String(), s.Last.String()))
		} else {
			parts = append(parts, "NO DATA before the audit date")
		}
	case "wrong-currency":
		parts = append(parts, fmt.Sprintf("WRONG CCY — series is %s and a %s position needs %s — NEVER USED", r.SeriesCurrency, r.Currency, r.Currency))
	case "stale":
		parts = append(parts, fmt.Sprintf("STALE — last close %s (%dd before audit)", r.LastClose.String(), *r.StaleDays))
		if g := r.LongestGap; g != nil {
			parts = append(parts, fmt.Sprintf("+ GAPS %dd (%s…%s)", g.Days, g.From.String(), g.To.String()))
		}
		parts = append(parts, fmt.Sprintf("%d closes in window", r.PointsInWindow))
	case "gaps":
		g := r.LongestGap
		parts = append(parts, fmt.Sprintf("GAPS — longest hole %dd (%s…%s)", g.Days, g.From.String(), g.To.String()), fmt.Sprintf("%d closes in window", r.PointsInWindow))
	default:
		parts = append(parts, fmt.Sprintf("ok — %d closes", r.PointsInWindow))
	}
	if s := r.WindowRange; s != nil && r.Status() == "ok" {
		parts = append(parts, s.First.String()+"…"+s.Last.String())
	}
	if r.Derived {
		parts = append(parts, "*derived")
	}
	return strings.Join(parts, ", ")
}
func coverageFXCell(r market.FXChainCoverage) string {
	if r.ChainLabel == "" {
		return fmt.Sprintf("NO CHAIN — no stored path %s→%s; import a %s/%s series or both USD legs (separate totals)", r.From, r.To, r.From, r.To)
	}
	label := r.ChainLabel
	if strings.HasPrefix(label, "derived") || strings.HasPrefix(label, "inverted") {
		label = "~" + label
	}
	if !r.UsableNow {
		result := fmt.Sprintf("%s STALE — chain last answered %s (%dd before audit); conversions dash", label, r.LastAsOf.String(), *r.StaleDays)
		if r.BoundariesMissing > 0 {
			result += fmt.Sprintf(" — missing at %d/%d period ends", r.BoundariesMissing, r.BoundariesTotal)
		}
		return result
	}
	result := fmt.Sprintf("ok — %s, last close %s (%dd)", label, r.LastAsOf.String(), *r.StaleDays)
	if r.BoundariesMissing == 0 && r.BoundariesTotal > 0 {
		result += fmt.Sprintf("; usable at all %d period ends", r.BoundariesTotal)
	}
	if r.BoundariesMissing > 0 {
		example := "?"
		if r.MissingExample != nil {
			example = r.MissingExample.String()
		}
		result += fmt.Sprintf(" — but missing at %d/%d period ends (e.g. %s)", r.BoundariesMissing, r.BoundariesTotal, example)
	}
	return result
}
