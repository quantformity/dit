package cli

import (
	"dit/internal/decimal"
	"dit/internal/market"
	"dit/internal/model"
	"dit/internal/text"
	"fmt"
	"sort"
	"strings"
	"time"
)

func backfillSymbol(raw string) (string, error) {
	s := strings.ToUpper(strings.TrimSpace(raw))
	if s == "" {
		return "", usage("--ticker cannot be empty")
	}
	return s, nil
}
func MarketBackfill(c Context, args []string) error {
	o, e := ParseOptions(args, setOf("from", "ratio"), setOf("dry-run"))
	if e != nil {
		return e
	}
	if len(o.Positionals) != 1 {
		return usage("usage: dit market backfill <target> --from <source> [--ratio R] [--dry-run]")
	}
	if _, ok := o.Values["from"]; !ok {
		return usage("backfill needs --from SOURCE — e.g. 'dit market backfill TSLA.NE --from TSLA'")
	}
	var override *decimal.Decimal
	if raw, ok := o.Values["ratio"]; ok {
		v, e := backfillRatio(raw)
		if e != nil {
			return e
		}
		override = &v
	}
	target, e := backfillSymbol(o.Positionals[0])
	if e != nil {
		return e
	}
	source, e := backfillSymbol(o.Values["from"])
	if e != nil {
		return e
	}
	p, d, e := loadWriteMarket(c)
	if e != nil {
		return e
	}
	if p == nil {
		return Runtime(fmt.Sprintf("no portfolio found at %s", c.Layout.PortfolioDir))
	}
	if target == source {
		return Runtime(fmt.Sprintf("'%s' cannot be derived from itself", target))
	}
	t, s := p.TickerBySymbol(target), p.TickerBySymbol(source)
	if t == nil {
		return Runtime(fmt.Sprintf("no registry entry for '%s' — backfill takes the trading currency from the registry ('dit ticker add %s --currency …' first)", target, target))
	}
	if s == nil {
		return Runtime(fmt.Sprintf("no registry entry for '%s' — the source ticker needs a known trading currency ('dit ticker add %s --currency USD')", source, source))
	}
	now := time.Now()
	today := model.DayFromUnix(now.Unix())
	ws := market.HoldingWindows(p, today)[target]
	if len(ws) == 0 {
		return Runtime(fmt.Sprintf("'%s' was never held in any account — there is no holding window to backfill", target))
	}
	tc, sc := t.Currency, s.Currency
	if !tc.IsKnown() {
		if q := d.LatestQuoteFor(target); q != nil && q.Currency.IsKnown() {
			tc = q.Currency
		}
	}
	if !sc.IsKnown() {
		if v := d.Series[source]; v != nil && v.Currency.IsKnown() {
			sc = v.Currency
		}
	}
	if !tc.IsKnown() || !sc.IsKnown() {
		return Runtime(fmt.Sprintf("cannot tell which currencies '%s' and '%s' trade in — set them with 'dit ticker edit … --currency …'", target, source))
	}
	notes, warnings := []string{}, []string{}
	prov := providerForCommand()
	if d.Series[source] == nil {
		if c.Offline {
			return Runtime(fmt.Sprintf("no stored daily history for '%s' and the network is off — run 'dit market history' (or drop --offline) first", source))
		}
		v, e := seriesFetch(prov, source, ws[0].Start, today)
		if e != nil {
			return e
		}
		if len(v.Points) == 0 {
			return Runtime(fmt.Sprintf("the provider has no daily history for '%s' — nothing to derive '%s' from", source, target))
		}
		ccy := v.Currency
		if !ccy.IsKnown() {
			ccy = sc
		}
		market.Merge(&d, source, ccy, v.Points, &today)
		notes = append(notes, fmt.Sprintf("fetched %d daily closes for '%s' (derivation source)", len(v.Points), source))
	}
	fxLabel := ""
	if sc != tc {
		fxLabel = sc.Code() + "/" + tc.Code()
		if d.Series[fxLabel] == nil {
			if c.Offline {
				return Runtime(fmt.Sprintf("no stored daily %s rates and the network is off — run 'dit market history' (or drop --offline) first", fxLabel))
			}
			v, e := seriesFetch(prov, fxTicker(sc, tc), ws[0].Start, today)
			if e != nil {
				return e
			}
			if len(v.Points) == 0 {
				return Runtime(fmt.Sprintf("the provider has no daily %s rates — cannot convert %s prices to %s", fxLabel, sc, tc))
			}
			market.Merge(&d, fxLabel, tc, v.Points, &today)
			notes = append(notes, fmt.Sprintf("fetched %d daily %s rates (derivation source)", len(v.Points), fxLabel))
		}
	}
	closeOn := func(day model.Day) (decimal.Decimal, bool) {
		for _, p := range d.Series[source].Points {
			if p.Day == day {
				return p.Price, true
			}
		}
		return decimal.Zero, false
	}
	fxOn := func(day model.Day) (decimal.Decimal, bool) {
		if sc == tc {
			return decimal.FromInt(1), true
		}
		v, ok := d.CloseOnOrBefore(fxLabel, day)
		return v.Price, ok && day-v.Day <= 3*86400
	}
	old := d.Series[target]
	ratio := decimal.Zero
	ratioString := ""
	if override != nil {
		ratio = *override
		ratioString = text.Quantity(ratio)
		notes = append(notes, fmt.Sprintf("ratio override: 1 '%s' unit ≈ 1 '%s' unit ÷ %s (calibration skipped)", target, source, ratioString))
	} else {
		type anchor struct {
			label string
			ratio decimal.Decimal
		}
		anchors := []anchor{}
		used := map[model.Day]bool{}
		skipped := 0
		add := func(day model.Day, price decimal.Decimal, label string) bool {
			close, ok := closeOn(day)
			fx, yes := fxOn(day)
			if price.Sign() <= 0 || !ok || !yes {
				return false
			}
			anchors = append(anchors, anchor{label, close.Mul(fx).Div(price, 38)})
			return true
		}
		if old != nil {
			for _, p := range old.Points {
				if p.Via == "" {
					used[p.Day] = true
					if !add(p.Day, p.Price, p.Day.String()) {
						skipped++
					}
				}
			}
		}
		if q := d.LatestQuoteFor(target); q != nil && q.Currency == tc && q.AsOf != nil && q.Price.Sign() > 0 {
			day := q.AsOf.AsDay()
			if !used[day] {
				add(day, q.Price, day.String()+" (live quote)")
			}
		}
		if len(anchors) == 0 {
			return Runtime(fmt.Sprintf("no common days where '%s' was really quoted next to '%s' — seed real closes ('dit market import') or pass --ratio R", target, source))
		}
		sum := decimal.Zero
		labels := []string{}
		min, max := anchors[0].ratio, anchors[0].ratio
		for _, a := range anchors {
			sum = sum.Add(a.ratio)
			labels = append(labels, a.label+" "+text.Quantity(a.ratio))
			if a.ratio.Cmp(min) < 0 {
				min = a.ratio
			}
			if a.ratio.Cmp(max) > 0 {
				max = a.ratio
			}
		}
		mean := sum.Div(decimal.FromInt(int64(len(anchors))), 38)
		ratio = mean.Round(6)
		ratioString = text.Quantity(ratio)
		fx := fxLabel
		if fx == "" {
			fx = "1:1"
		}
		notes = append(notes, fmt.Sprintf("ratio calibrated on %d common day(s): %s", len(anchors), strings.Join(labels, ", ")), fmt.Sprintf("mean ratio = %s ('%s' price = '%s' × %s ÷ ratio)", ratioString, target, source, fx))
		if skipped > 0 {
			rate := "no"
			if fxLabel != "" {
				rate = fxLabel + " "
			}
			notes = append(notes, fmt.Sprintf("(%d real observation(s) skipped — no same-day '%s' close or %srate)", skipped, source, rate))
		}
		if len(anchors) >= 2 {
			spread := max.Sub(min).Div(mean, 38)
			if spread.Cmp(decimal.MustParse("0.02")) > 0 {
				warnings = append(warnings, fmt.Sprintf("calibration spread is %s%% of the mean — '%s' has been de-coupling from '%s'; the derived history will drift with it", spread.Mul(decimal.FromInt(100)).Round(1).String(), target, source))
			}
		}
	}
	ratio = ratio.Round(6)
	if ratio.Sign() == 0 {
		return Runtime("calibrated ratio rounds to zero")
	}
	byDay := map[model.Day]model.DailyPrice{}
	previous := map[model.Day]model.DailyPrice{}
	if old != nil {
		for _, v := range old.Points {
			previous[v.Day] = v
			if v.Via == "" {
				byDay[v.Day] = v
			}
		}
	}
	kept := len(byDay)
	filled, unchanged, empty := 0, 0, 0
	for _, w := range ws {
		end := w.End
		if end > today {
			end = today
		}
		for day := w.Start; day <= end; day += 86400 {
			weekday := day.DayTime().Weekday()
			if weekday == time.Saturday || weekday == time.Sunday {
				continue
			}
			if _, ok := byDay[day]; ok {
				continue
			}
			close, ok := closeOn(day)
			fx, yes := fxOn(day)
			if !ok || !yes {
				empty++
				continue
			}
			price := close.Mul(fx).Div(ratio, 38).Round(4)
			if v, ok := previous[day]; ok && v.Via != "" && v.Price.Cmp(price) == 0 {
				unchanged++
			} else {
				filled++
			}
			byDay[day] = model.DailyPrice{Day: day, Price: price, Via: "derived via " + source + " ÷ " + ratioString}
		}
	}
	points := []model.DailyPrice{}
	for _, p := range byDay {
		points = append(points, p)
	}
	sort.Slice(points, func(i, j int) bool { return points[i].Day < points[j].Day })
	ns := &model.PriceSeries{Symbol: target, Currency: tc, Points: points}
	if old != nil {
		ns.CoveredThrough = old.CoveredThrough
	}
	d.Series[target] = ns
	writeNow(&d, now)
	line := fmt.Sprintf("backfilled %d day(s) of '%s' from '%s'", filled, target, source)
	if fxLabel != "" {
		line += " × " + fxLabel
	}
	line += fmt.Sprintf(" ÷ %s — %d real close(s) kept", ratioString, kept)
	if unchanged > 0 {
		line += fmt.Sprintf(", %d derived value(s) unchanged", unchanged)
	}
	if empty > 0 {
		line += fmt.Sprintf(", %d weekday(s) had no same-day source data (left empty)", empty)
	}
	notes = append(notes, line)
	if o.Has("dry-run") {
		notes = append(notes, "dry run — nothing written")
	} else {
		if e = saveWriteMarket(c, d); e != nil {
			return e
		}
	}
	c.printf("Derived history — %s\n", marketLocation(c))
	for _, n := range notes {
		c.printf("  %s\n", n)
	}
	for _, w := range warnings {
		fmt.Fprintln(c.Err, "warning:", w)
	}
	return nil
}
