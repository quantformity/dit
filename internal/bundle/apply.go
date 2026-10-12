package bundle

import (
	"fmt"
	"sort"
	"strings"

	"dit/internal/model"
)

type Mode int

const (
	Replace Mode = iota
	Merge
)

type Applied struct {
	Portfolio                     model.Portfolio
	Market                        model.MarketData
	WritesPortfolio, WritesMarket bool
	Notes                         []string
}

func id(s string) string { return strings.ToUpper(s) }

func Validate(incoming, previous model.Portfolio) error {
	accounts := map[string]bool{}
	purchases := map[string]bool{}
	for _, p := range []model.Portfolio{previous, incoming} {
		for _, a := range p.Accounts {
			accounts[id(a.ID)] = true
		}
		for _, t := range p.Transactions {
			if t.Kind.Type == model.KindGICPurchase {
				purchases[id(t.ID)] = true
			}
		}
	}
	for _, t := range incoming.Transactions {
		if !accounts[id(t.AccountID)] {
			count := 0
			for _, other := range incoming.Transactions {
				if id(other.AccountID) == id(t.AccountID) {
					count++
				}
			}
			return fmt.Errorf("%d transaction(s) reference account %s, which neither the file nor the store has — export the whole portfolio, not one account's ledger", count, id(t.AccountID))
		}
	}
	for _, t := range incoming.Transactions {
		if t.Kind.Type == model.KindGICRedemption && t.Kind.Redemption != nil && !purchases[id(t.Kind.Redemption.PurchaseID)] {
			return fmt.Errorf("a GIC redemption references purchase %s, which neither the file nor the store has", id(t.Kind.Redemption.PurchaseID))
		}
	}
	return nil
}

func clonePortfolio(p model.Portfolio) model.Portfolio {
	p.Accounts = append([]model.Account{}, p.Accounts...)
	p.Transactions = append([]model.Transaction{}, p.Transactions...)
	p.Tickers = append([]model.EquityTicker{}, p.Tickers...)
	return p
}
func cloneMarket(m model.MarketData) model.MarketData {
	out := m
	out.LatestQuotes = append([]model.MarketQuote{}, m.LatestQuotes...)
	out.LatestRates = append([]model.ExchangeRate{}, m.LatestRates...)
	out.Series = map[string]*model.PriceSeries{}
	for k, s := range m.Series {
		copy := *s
		copy.Points = append([]model.DailyPrice{}, s.Points...)
		out.Series[k] = &copy
	}
	return out
}

// Apply computes both stores before the caller is allowed to back up or write either.
func Apply(d Document, p model.Portfolio, m model.MarketData, mode Mode) (Applied, error) {
	out := Applied{Portfolio: clonePortfolio(p), Market: cloneMarket(m)}
	ledger := d.Portfolio
	prices := d.Market
	if ledger != nil && len(ledger.Accounts) == 0 && len(ledger.Transactions) == 0 {
		ledger = nil
		out.Notes = append(out.Notes, "the bundle's ledger section is empty — the portfolio store is left as it was")
	}
	if prices != nil && prices.IsEmpty() {
		prices = nil
		out.Notes = append(out.Notes, "the bundle's market section is empty — the market store is left as it was")
	}
	if ledger == nil && prices == nil {
		return Applied{}, ErrEmpty
	}
	if ledger != nil {
		previous := p
		if mode == Replace {
			previous = model.Portfolio{}
		}
		if err := Validate(*ledger, previous); err != nil {
			return Applied{}, err
		}
		out.WritesPortfolio = true
		if mode == Replace {
			out.Portfolio = clonePortfolio(*ledger)
			out.Notes = append(out.Notes, fmt.Sprintf("ledger replaced: %d account(s), %d transaction(s), %d ticker(s) — was %d account(s), %d transaction(s)", len(ledger.Accounts), len(ledger.Transactions), len(ledger.Tickers), len(p.Accounts), len(p.Transactions)))
		} else {
			addedAccounts, addedTickers := 0, 0
			for _, a := range ledger.Accounts {
				if out.Portfolio.AccountByID(a.ID) == nil {
					out.Portfolio.Accounts = append(out.Portfolio.Accounts, a)
					addedAccounts++
				}
			}
			known := map[string]bool{}
			for _, t := range p.Transactions {
				known[id(t.ID)] = true
			}
			fresh, skipped := 0, 0
			for _, t := range ledger.Transactions {
				if known[id(t.ID)] {
					skipped++
					continue
				}
				out.Portfolio.Transactions = append(out.Portfolio.Transactions, t)
				fresh++
			}
			symbols := map[string]bool{}
			for _, t := range p.Tickers {
				symbols[t.Symbol] = true
			}
			for _, t := range ledger.Tickers {
				if !symbols[t.Symbol] {
					out.Portfolio.Tickers = append(out.Portfolio.Tickers, t)
					addedTickers++
				}
			}
			note := fmt.Sprintf("ledger merged: %d new transaction(s)", fresh)
			if skipped > 0 {
				note += fmt.Sprintf(", %d already present (skipped)", skipped)
			}
			if addedAccounts > 0 {
				note += fmt.Sprintf(", %d new account(s)", addedAccounts)
			}
			if addedTickers > 0 {
				note += fmt.Sprintf(", %d new ticker(s)", addedTickers)
			}
			out.Notes = append(out.Notes, note)
		}
	} else if d.Portfolio == nil {
		out.Notes = append(out.Notes, "no ledger in the bundle — the portfolio store is left as it was")
	}
	if prices != nil {
		out.WritesMarket = true
		if mode == Replace {
			out.Market = cloneMarket(*prices)
			out.Notes = append(out.Notes, fmt.Sprintf("market store replaced: %d daily close(s) across %d series — was %d close(s) across %d series", prices.TotalPoints(), len(prices.Series), m.TotalPoints(), len(m.Series)))
		} else {
			added, dropped := 0, 0
			for k, s := range prices.Series {
				existing := out.Market.Series[k]
				if existing == nil {
					taken := *s
					taken.Points = append([]model.DailyPrice{}, s.Points...)
					taken.CoveredThrough = nil
					out.Market.Series[k] = &taken
					added += len(s.Points)
					if s.CoveredThrough != nil {
						dropped++
					}
					continue
				}
				merged, n := MergePoints(*existing, s.Points)
				if n > 0 {
					out.Market.Series[k] = &merged
					added += n
				}
			}
			for _, q := range prices.LatestQuotes {
				index := -1
				for i, old := range m.LatestQuotes {
					if old.Symbol == q.Symbol {
						index = i
						break
					}
				}
				if index < 0 || newer(q.AsOf, m.LatestQuotes[index].AsOf) {
					kept := []model.MarketQuote{}
					for _, old := range out.Market.LatestQuotes {
						if old.Symbol != q.Symbol {
							kept = append(kept, old)
						}
					}
					out.Market.LatestQuotes = append(kept, q)
				}
			}
			for _, r := range prices.LatestRates {
				index := -1
				for i, old := range m.LatestRates {
					if old.Base == r.Base && old.Quote == r.Quote {
						index = i
						break
					}
				}
				if index < 0 || newer(r.AsOf, m.LatestRates[index].AsOf) {
					kept := []model.ExchangeRate{}
					for _, old := range out.Market.LatestRates {
						if old.Base != r.Base || old.Quote != r.Quote {
							kept = append(kept, old)
						}
					}
					out.Market.LatestRates = append(kept, r)
				}
			}
			note := "market data unchanged: nothing new in the bundle"
			if added > 0 {
				note = fmt.Sprintf("market data merged: %d close(s) added (stored real closes kept; imported real closes replace derived ones)", added)
			}
			out.Notes = append(out.Notes, note)
			if dropped > 0 {
				out.Notes = append(out.Notes, "note: imported series arrive without a coverage watermark — run 'dit update' to verify the imported range")
			}
		}
	} else if d.Market == nil {
		out.Notes = append(out.Notes, "no market data in the bundle — the market store is left as it was")
	}
	return out, nil
}
func newer(a, b *model.Stamp) bool {
	if a == nil {
		return false
	}
	return b == nil || *a > *b
}

// MergePoints keeps local observations and watermarks; real closes may retire guesses.
func MergePoints(s model.PriceSeries, in []model.DailyPrice) (model.PriceSeries, int) {
	points := append([]model.DailyPrice{}, s.Points...)
	index := map[model.Day]int{}
	for i, p := range points {
		index[p.Day] = i
	}
	added := 0
	for _, p := range in {
		if i, ok := index[p.Day]; ok {
			if points[i].Via != "" && p.Via == "" {
				points[i] = p
				added++
			}
			continue
		}
		index[p.Day] = len(points)
		points = append(points, p)
		added++
	}
	sort.SliceStable(points, func(i, j int) bool { return points[i].Day < points[j].Day })
	s.Points = points
	return s, added
}
