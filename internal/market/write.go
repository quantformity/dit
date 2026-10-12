package market

import (
	"dit/internal/decimal"
	"dit/internal/model"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"
)

type Window struct{ Start, End model.Day }

func HoldingWindows(p *model.Portfolio, today model.Day) map[string][]Window {
	raw := map[string][]Window{}
	for _, a := range p.Accounts {
		type state struct {
			shares decimal.Decimal
			start  model.Day
		}
		states := map[string]state{}
		txs := p.TransactionsIn(a.ID)
		sort.SliceStable(txs, func(i, j int) bool { return txs[i].Date < txs[j].Date })
		for _, tx := range txs {
			x := tx.Kind.Stock
			if x == nil {
				continue
			}
			s := states[x.Ticker]
			switch tx.Kind.Type {
			case model.KindStockPurchase:
				if s.shares.Sign() == 0 {
					s.start = tx.Date
				}
				s.shares = s.shares.Add(x.Shares)
			case model.KindStockSale:
				if s.shares.Sign() <= 0 {
					continue
				}
				s.shares = s.shares.Sub(x.Shares)
				if s.shares.Sign() <= 0 {
					raw[x.Ticker] = append(raw[x.Ticker], Window{s.start, tx.Date})
					s = state{}
				}
			}
			states[x.Ticker] = s
		}
		for symbol, s := range states {
			if s.shares.Sign() > 0 {
				raw[symbol] = append(raw[symbol], Window{s.start, today})
			}
		}
	}
	for symbol, ws := range raw {
		sort.Slice(ws, func(i, j int) bool { return ws[i].Start < ws[j].Start })
		merged := []Window{}
		for _, w := range ws {
			n := len(merged)
			if n > 0 && w.Start <= merged[n-1].End+86400 {
				if w.End > merged[n-1].End {
					merged[n-1].End = w.End
				}
			} else {
				merged = append(merged, w)
			}
		}
		raw[symbol] = merged
	}
	return raw
}

// Merge counts incoming additions (including repeated CSV days) like Swift;
// the last incoming observation for a new day wins. Real never replaces real.
func Merge(data *model.MarketData, symbol string, ccy model.Currency, points []model.DailyPrice, through *model.Day) int {
	if data.Series == nil {
		data.Series = map[string]*model.PriceSeries{}
	}
	old := data.Series[symbol]
	if old == nil {
		old = &model.PriceSeries{Symbol: symbol, Currency: ccy, Points: []model.DailyPrice{}}
	}
	existing := map[model.Day]model.DailyPrice{}
	for _, p := range old.Points {
		existing[p.Day] = p
	}
	merged := map[model.Day]model.DailyPrice{}
	for d, p := range existing {
		merged[d] = p
	}
	added := 0
	for _, p := range points {
		p.Day = model.DayFromUnix(int64(p.Day))
		e, ok := existing[p.Day]
		if !ok || (p.Via == "" && e.Via != "") {
			merged[p.Day] = p
			added++
		}
	}
	out := *old
	out.Points = []model.DailyPrice{}
	for _, p := range merged {
		out.Points = append(out.Points, p)
	}
	sort.Slice(out.Points, func(i, j int) bool { return out.Points[i].Day < out.Points[j].Day })
	if through != nil && (out.CoveredThrough == nil || *through > *out.CoveredThrough) {
		d := *through
		out.CoveredThrough = &d
	}
	data.Series[symbol] = &out
	return added
}

type CSVEntry struct {
	Symbol string
	Point  model.DailyPrice
}

func ParseCSV(text string) (entries []CSVEntry, problems []string) {
	lines := strings.FieldsFunc(text, func(r rune) bool { return r == '\n' || r == '\r' })
	for i, raw := range lines {
		line := strings.TrimSpace(raw)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.FieldsFunc(line, func(r rune) bool { return r == ',' })
		for j := range fields {
			fields[j] = strings.TrimSpace(fields[j])
		}
		if len(fields) == 3 && strings.EqualFold(fields[1], "date") {
			continue
		}
		problem := func(s string) { problems = append(problems, fmt.Sprintf("line %d: %s", i+1, s)) }
		if len(fields) != 3 {
			problem(fmt.Sprintf("expected 'SYMBOL,YYYY-MM-DD,PRICE', got '%s'", line))
			continue
		}
		symbol := strings.ToUpper(fields[0])
		valid := true
		for _, r := range symbol {
			if !strings.ContainsRune("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-/", r) {
				valid = false
			}
		}
		if !valid {
			problem(fmt.Sprintf("unreadable symbol '%s'", fields[0]))
			continue
		}
		nums := []int{}
		for _, part := range strings.FieldsFunc(fields[1], func(r rune) bool { return r == '-' }) {
			if n, e := strconv.Atoi(part); e == nil {
				nums = append(nums, n)
			}
		}
		if len(nums) != 3 || nums[1] < 1 || nums[1] > 12 || nums[2] < 1 || nums[2] > 31 {
			problem(fmt.Sprintf("bad date '%s' (want YYYY-MM-DD)", fields[1]))
			continue
		}
		day := model.Day(time.Date(nums[0], time.Month(nums[1]), nums[2], 0, 0, 0, 0, time.UTC).Unix())
		price, err := FoundationDecimal(fields[2])
		if err != nil || price.Sign() <= 0 {
			problem(fmt.Sprintf("bad price '%s'", fields[2]))
			continue
		}
		entries = append(entries, CSVEntry{symbol, model.DailyPrice{Day: day, Price: price}})
	}
	return
}

// Foundation Decimal(string:) accepts a numeric prefix, unlike CLI parsing.
func FoundationDecimal(s string) (decimal.Decimal, error) {
	for n := len(s); n > 0; n-- {
		if d, e := decimal.Parse(s[:n]); e == nil {
			return d, nil
		}
	}
	return decimal.Zero, fmt.Errorf("bad decimal")
}
