package valuation

import (
	"dit/internal/decimal"
	"dit/internal/model"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
)

func dayTime(d model.Day) time.Time { return time.Unix(int64(d), 0).UTC() }
func timeDay(t time.Time) model.Day { return model.Day(t.Unix()) }

// Calendar shifts clamp the day to the destination month (Go AddDate rolls it).
func calendarBack(end time.Time, months int) time.Time {
	first := time.Date(end.Year(), end.Month(), 1, 0, 0, 0, 0, time.UTC).AddDate(0, -months, 0)
	last := first.AddDate(0, 1, -1).Day()
	day := end.Day()
	if day > last {
		day = last
	}
	return time.Date(first.Year(), first.Month(), day, 0, 0, 0, 0, time.UTC).AddDate(0, 0, 1)
}
func ResolvePnLWindow(horizon *string, from, to *model.Day, now model.Day, ledgerStart *model.Day) (Window, error) {
	end := now
	if to != nil {
		end = *to
	}
	w := Window{End: end}
	if horizon != nil {
		token := *horizon
		lower := strings.ToLower(token)
		w.Label = lower
		t := dayTime(end)
		if lower == "ytd" {
			w.Start = timeDay(time.Date(t.Year(), 1, 1, 0, 0, 0, 0, time.UTC))
			return w, nil
		}
		parts := regexp.MustCompile(`^([0-9]{1,3})([dDwWmMyY])$`).FindStringSubmatch(token)
		if parts != nil {
			n, _ := strconv.Atoi(parts[1])
			if n > 0 {
				switch strings.ToLower(parts[2]) {
				case "d":
					w.Start = end - model.Day(n-1)*86400
				case "w":
					w.Start = end - model.Day(7*n-1)*86400
				case "m":
					w.Start = timeDay(calendarBack(t, n))
				case "y":
					w.Start = timeDay(calendarBack(t, n*12))
				}
				return w, nil
			}
		}
		return w, fmt.Errorf("unknown horizon '%s' — use Nd/Nw/Nm/Ny (e.g. 5d, 2w, 3m, 1y) or 'ytd'", token)
	}
	if from != nil {
		w.Start = *from
		w.Label = "custom"
		if end < *from {
			return w, fmt.Errorf("--to '%s' is before --from '%s' — the window runs empty; swap them", end, *from)
		}
		return w, nil
	}
	w.Start = end
	if ledgerStart != nil {
		w.Start = *ledgerStart
	}
	w.Label = "full history"
	w.FromLedgerStart = true
	return w, nil
}
func PnLGranularity(w Window) string {
	days := (w.End-w.Start)/86400 + 1
	if days > 56 {
		return "monthly"
	}
	if days > 10 {
		return "weekly"
	}
	return "daily"
}

type PnLPoint struct {
	Label      string
	Start, End model.Day
	Report     PnLReport
}
type PnLSeries struct {
	Granularity                           string
	Points                                []PnLPoint
	CollapsedEmpty, CollapsedUnmeasurable int
	Reconciles                            bool
}

func PnLBuckets(w Window, g string) []Window {
	out := []Window{}
	cursor := w.Start
	for cursor <= w.End {
		end := cursor
		full := false
		switch g {
		case "weekly":
			end = cursor + 6*86400
		case "monthly":
			t := dayTime(cursor)
			first := time.Date(t.Year(), t.Month(), 1, 0, 0, 0, 0, time.UTC)
			end = timeDay(first.AddDate(0, 1, -1))
			full = cursor == timeDay(first) && end <= w.End
		}
		if end > w.End {
			end = w.End
		}
		label := cursor.String()
		if full {
			label = dayTime(cursor).Format("2006-01")
		} else if end != cursor {
			label += "…" + end.String()
		}
		out = append(out, Window{Start: cursor, End: end, Label: label})
		cursor = end + 86400
	}
	return out
}
func ComputePnLSeries(p *model.Portfolio, m model.MarketData, w Window, g string, accounts []model.Account, perAccount bool, symbols map[string]bool, ccys map[model.Currency]bool, reporting model.Currency, full PnLReport) PnLSeries {
	s := PnLSeries{Granularity: g, Points: []PnLPoint{}, Reconciles: true}
	sums := Amounts{}
	for _, bucket := range PnLBuckets(w, g) {
		r := ComputePnL(p, m, bucket, accounts, perAccount, symbols, ccys, reporting)
		if len(r.Rows) == 0 {
			unmeasured := false
			for _, n := range r.Notes {
				if strings.HasPrefix(n, "no usable daily history") {
					unmeasured = true
				}
			}
			if unmeasured {
				s.CollapsedUnmeasurable++
				s.Reconciles = false
			} else {
				s.CollapsedEmpty++
			}
			continue
		}
		s.Points = append(s.Points, PnLPoint{bucket.Label, bucket.Start, bucket.End, r})
		for _, t := range r.Totals {
			if t.Total == nil {
				s.Reconciles = false
			} else {
				add(sums, t.Currency, *t.Total)
			}
		}
	}
	halfCent := decimal.MustParse("0.005")
	for c, sum := range sums {
		found := false
		for _, t := range full.Totals {
			if t.Currency == c && t.Total != nil {
				found = true
				diff := sum.Sub(*t.Total)
				if diff.Sign() < 0 {
					diff = diff.Neg()
				}
				if diff.Cmp(halfCent) >= 0 {
					s.Reconciles = false
				}
			}
		}
		if !found {
			s.Reconciles = false
		}
	}
	return s
}
