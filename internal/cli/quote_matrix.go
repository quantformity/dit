package cli

import (
	"fmt"
	"time"

	"dit/internal/decimal"
	"dit/internal/model"
)

type quoteFXCell struct {
	rate  *decimal.Decimal
	basis string
	date  string
}

// buildQuoteFX is pure decimal arithmetic; direct observations win, inverses
// retain the source day, and USD triangulation is explicitly derived.
func buildQuoteFX(a, b model.Currency, direct map[string]quoteFXCell) quoteFXCell {
	if a == b {
		one := decimal.FromInt(1)
		return quoteFXCell{rate: &one, basis: "identity"}
	}
	if cell, ok := direct[model.PairKey(a, b)]; ok {
		return cell
	}
	if cell, ok := direct[model.PairKey(b, a)]; ok && cell.rate.Sign() != 0 {
		inverse := decimal.FromInt(1).Div(*cell.rate, 38)
		return quoteFXCell{rate: &inverse, basis: "reciprocal", date: cell.date}
	}
	if a != model.USD && b != model.USD {
		up, across := buildQuoteFX(a, model.USD, direct), buildQuoteFX(model.USD, b, direct)
		if up.rate != nil && up.rate.Sign() != 0 && across.rate != nil {
			rate := up.rate.Mul(*across.rate)
			return quoteFXCell{rate: &rate, basis: "derived"}
		}
	}
	return quoteFXCell{basis: "none"}
}
func quoteMatrix(c Context, currencies []model.Currency, token string, o Options) error {
	var day model.Day
	raw, as := o.Values["as-of"]
	if as {
		var err error
		day, err = quoteDate(raw)
		if err != nil {
			return err
		}
	} else {
		day = model.DayFromUnix(time.Now().Unix())
	}
	storeMode := c.Offline || as
	pairs := [][2]model.Currency{}
	seen := map[string]bool{}
	add := func(a, b model.Currency) {
		if a == b || seen[model.PairKey(a, b)] || seen[model.PairKey(b, a)] {
			return
		}
		seen[model.PairKey(a, b)] = true
		pairs = append(pairs, [2]model.Currency{a, b})
	}
	for _, a := range currencies {
		for _, b := range currencies {
			add(a, b)
		}
	}
	for _, ccy := range currencies {
		add(model.USD, ccy)
	}
	direct := map[string]quoteFXCell{}
	storePath := "yahoo finance"
	if storeMode {
		storePath = c.Layout.MarketDir
		m, err := quoteMarket(c)
		if err != nil {
			return err
		}
		for _, pair := range pairs {
			key := model.PairKey(pair[0], pair[1])
			if p, ok := m.CloseOnOrBefore(key, day); ok {
				price := p.Price
				direct[key] = quoteFXCell{rate: &price, basis: "observed", date: quoteDay(p.Day)}
			}
		}
	} else {
		p := providerForCommand()
		for _, pair := range pairs {
			a, b := pair[0], pair[1]
			if r, err := p.Rate(a, b); err == nil {
				rate := r.Rate
				direct[model.PairKey(a, b)] = quoteFXCell{rate: &rate, basis: "observed"}
			} else if r, err := p.Rate(b, a); err == nil {
				rate := r.Rate
				direct[model.PairKey(b, a)] = quoteFXCell{rate: &rate, basis: "observed"}
			}
		}
	}
	entries := []map[string]any{}
	by := map[string]quoteFXCell{}
	count := 0
	for _, a := range currencies {
		for _, b := range currencies {
			if a == b {
				continue
			}
			cell := buildQuoteFX(a, b, direct)
			by[model.PairKey(a, b)] = cell
			entry := map[string]any{"base": a.Code(), "quote": b.Code(), "basis": cell.basis, "rate": nil}
			if cell.rate != nil {
				count++
				entry["rate"] = quoteFixed(*cell.rate, 6)
			}
			if cell.date != "" {
				entry["date"] = cell.date
			}
			if cell.basis == "derived" {
				entry["via"] = "triangulated via USD"
			}
			entries = append(entries, entry)
		}
	}
	if count == 0 {
		if storeMode {
			return Runtime(fmt.Sprintf("no stored FX rates for %s in the market store — 'dit market latest' fetches them live", token))
		}
		return Runtime(fmt.Sprintf("no FX rates available for %s — check the network, or seed the store with 'dit market import'", token))
	}
	now := time.Now()
	if c.JSON {
		var stamp any
		if storeMode {
			if as {
				stamp = quoteDay(day)
			}
		} else {
			stamp = now.UTC().Format("2006-01-02T15:04:05Z")
		}
		return quoteJSON(c, map[string]any{"mode": "matrix", "asOf": stamp, "query": token, "currencies": currencies, "count": count, "pairCount": len(entries), "rates": entries, "store": storePath})
	}
	c.printf("FX matrix — %s\n  every rate is QUOTE currency (column) per 1 unit of the row BASE\n", token)
	if storeMode {
		label := "latest stored rates"
		if as {
			label = quoteDay(day)
		}
		c.printf("  %s — read from the market store, nothing fetched\n", label)
	} else {
		c.printf("  live from Yahoo Finance at %s\n", quoteClock(now))
	}
	headers := []string{"Base \\ to"}
	for _, ccy := range currencies {
		headers = append(headers, ccy.Code())
	}
	rows := [][]string{}
	for _, a := range currencies {
		row := []string{a.Code()}
		for _, b := range currencies {
			value := "·"
			if a != b {
				cell := by[model.PairKey(a, b)]
				value = "—"
				if cell.rate != nil {
					value = quoteFixed(*cell.rate, 6)
					if cell.basis == "derived" {
						value += "*"
					}
				}
			}
			row = append(row, value)
		}
		rows = append(rows, row)
	}
	c.printf("\n")
	marketTable(c, headers, rows, 0)
	c.printf("\n  · = same currency · — = no rate available · * = triangulated via USD\n    (triangulated rates are approximations from two USD legs, not quotes)\n")
	return nil
}
