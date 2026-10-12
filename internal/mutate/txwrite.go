// Package mutate implements value-in/value-out ledger corrections. No operation
// performs I/O or changes the input portfolio, including on failure.
package mutate

import (
	"dit/internal/decimal"
	"dit/internal/ledger"
	"dit/internal/model"
	"encoding/json"
	"fmt"
	"strings"
)

func Validate(tx model.Transaction) error {
	bad := func(label string, v decimal.Decimal) error { return fmt.Errorf("%s (found %s)", label, v) }
	if tx.Fee != nil && tx.Fee.Sign() < 0 {
		return bad("a fee cannot be negative", *tx.Fee)
	}
	k := tx.Kind
	switch k.Type {
	case model.KindDeposit, model.KindWithdrawal:
		if k.Amount.Sign() <= 0 {
			return bad("amount must be positive", k.Amount)
		}
	case model.KindStockPurchase, model.KindStockSale:
		if k.Stock.Ticker == "" {
			return fmt.Errorf("empty ticker symbol")
		}
		if k.Stock.Shares.Sign() <= 0 {
			return bad("shares must be positive", k.Stock.Shares)
		}
		if k.Stock.Price.Sign() < 0 {
			return bad("price cannot be negative", k.Stock.Price)
		}
	case model.KindDividend:
		if k.Dividend.Ticker == "" {
			return fmt.Errorf("empty ticker symbol")
		}
		if k.Dividend.Amount.Sign() <= 0 {
			return bad("dividend amount must be positive", k.Dividend.Amount)
		}
	case model.KindGICPurchase:
		if k.GIC.Product == "" {
			return fmt.Errorf("empty GIC product name")
		}
		if k.GIC.Principal.Sign() <= 0 {
			return bad("principal must be positive", k.GIC.Principal)
		}
		if k.GIC.Rate.Sign() < 0 {
			return bad("rate cannot be negative", k.GIC.Rate)
		}
	case model.KindGICRedemption:
		if k.Redemption.Proceeds.Sign() < 0 {
			return bad("proceeds cannot be negative", k.Redemption.Proceeds)
		}
	case model.KindFXConversion:
		if k.FX.FromCurrency == tx.Currency {
			return fmt.Errorf("a currency conversion needs two different currencies")
		}
		if k.FX.FromAmount.Sign() <= 0 || k.FX.ToAmount.Sign() <= 0 {
			return fmt.Errorf("both converted amounts must be positive (found %s → %s)", k.FX.FromAmount, k.FX.ToAmount)
		}
	}
	return nil
}

func Deltas(tx model.Transaction) []ledger.Money {
	if tx.Kind.Type == model.KindFXConversion {
		return []ledger.Money{{Currency: tx.Kind.FX.FromCurrency, Amount: tx.Kind.FX.FromAmount.Neg()}, {Currency: tx.Currency, Amount: tx.CashImpact()}}
	}
	if tx.CashImpact().Sign() == 0 {
		return nil
	}
	return []ledger.Money{{Currency: tx.Currency, Amount: tx.CashImpact()}}
}
func Pools(p model.Portfolio, account string) map[model.Currency]decimal.Decimal {
	pools := map[model.Currency]decimal.Decimal{}
	for _, tx := range p.Transactions {
		if tx.AccountID == account {
			for _, d := range Deltas(tx) {
				pools[d.Currency] = pools[d.Currency].Add(d.Amount)
			}
		}
	}
	return pools
}
func Shares(p model.Portfolio, account, symbol string, currency *model.Currency) decimal.Decimal {
	n := decimal.Zero
	for _, tx := range p.Transactions {
		if tx.AccountID != account || tx.TickerSymbol() != symbol || (currency != nil && tx.Currency != *currency) {
			continue
		}
		if tx.Kind.Type == model.KindStockPurchase {
			n = n.Add(tx.Kind.Stock.Shares)
		}
		if tx.Kind.Type == model.KindStockSale {
			n = n.Sub(tx.Kind.Stock.Shares)
		}
	}
	return n
}
func copyPortfolio(p model.Portfolio) model.Portfolio {
	p.Transactions = append([]model.Transaction(nil), p.Transactions...)
	p.Tickers = append([]model.EquityTicker(nil), p.Tickers...)
	return p
}
func Add(p model.Portfolio, tx model.Transaction) (model.Portfolio, []string, error) {
	if p.AccountByID(tx.AccountID) == nil {
		return p, nil, fmt.Errorf("no account with ID %s", tx.AccountID)
	}
	if err := Validate(tx); err != nil {
		return p, nil, err
	}
	if tx.Kind.Redemption != nil {
		found := false
		for _, other := range p.Transactions {
			if other.ID == tx.Kind.Redemption.PurchaseID && other.AccountID == tx.AccountID {
				found = true
			}
		}
		if !found {
			return p, nil, fmt.Errorf("a GIC redemption must reference an existing GIC purchase in the same account (id %s matches none)", tx.Kind.Redemption.PurchaseID)
		}
	}
	out := copyPortfolio(p)
	notes := []string{"added '" + ledger.SummaryLine(tx) + "'"}
	symbol := tx.TickerSymbol()
	if symbol != "" && p.TickerBySymbol(symbol) == nil {
		out.Tickers = append(out.Tickers, model.EquityTicker{Symbol: symbol, Currency: tx.Currency, Tags: []string{}})
		notes = append(notes, "registered ticker '"+symbol+"' — add a name with 'dit ticker edit' if you like")
	}
	pools := Pools(p, tx.AccountID)
	for _, d := range Deltas(tx) {
		if d.Amount.Sign() < 0 {
			pools[d.Currency] = pools[d.Currency].Add(d.Amount)
			if pools[d.Currency].Sign() < 0 {
				notes = append(notes, fmt.Sprintf("warning: %s cash goes negative (%s) — check the account actually had this money", d.Currency, pools[d.Currency]))
			}
		}
	}
	out.Transactions = append(out.Transactions, tx)
	return out, notes, nil
}
func Edit(p model.Portfolio, tx model.Transaction) (model.Portfolio, []string, error) {
	for i, old := range p.Transactions {
		if old.ID != tx.ID {
			continue
		}
		if old.Kind.Type != tx.Kind.Type || old.AccountID != tx.AccountID {
			return p, nil, fmt.Errorf("a correction may not change what a transaction *is* — delete it and add a corrected one (this keeps the ledger honest about the fix)")
		}
		a, _ := json.Marshal(old)
		b, _ := json.Marshal(tx)
		if string(a) == string(b) {
			return p, nil, fmt.Errorf("no changes — every supplied value already matches account %s", tx.ID)
		}
		if err := Validate(tx); err != nil {
			return p, nil, err
		}
		out := copyPortfolio(p)
		out.Transactions[i] = tx
		notes := []string{fmt.Sprintf("corrected '%s %s' → '%s %s'", old.Date, ledger.SummaryLine(old), tx.Date, ledger.SummaryLine(tx))}
		if old.Kind.GIC != nil && old.Kind.GIC.Principal.Cmp(tx.Kind.GIC.Principal) != 0 {
			count := 0
			for _, other := range p.Transactions {
				if other.AccountID == tx.AccountID && other.Kind.Redemption != nil && other.Kind.Redemption.PurchaseID == tx.ID {
					count++
				}
			}
			if count > 0 {
				suffix := ""
				if count != 1 {
					suffix = "s"
				}
				notes = append(notes, fmt.Sprintf("warning: %d linked redemption%s recomputed against the new principal", count, suffix))
			}
		}
		return out, notes, nil
	}
	return p, nil, fmt.Errorf("no transaction with ID %s", tx.ID)
}
func Delete(p model.Portfolio, tx model.Transaction) (model.Portfolio, []string, error) {
	out := copyPortfolio(p)
	found := false
	for i, other := range out.Transactions {
		if other.ID == tx.ID {
			out.Transactions = append(out.Transactions[:i], out.Transactions[i+1:]...)
			found = true
			break
		}
	}
	if !found {
		return p, nil, fmt.Errorf("no transaction with ID %s", tx.ID)
	}
	notes := []string{"removed '" + ledger.SummaryLine(tx) + "'"}
	if tx.Kind.Stock != nil {
		symbol := tx.Kind.Stock.Ticker
		held := Shares(p, tx.AccountID, symbol, &tx.Currency)
		delta := tx.Kind.Stock.Shares
		if tx.Kind.Type == model.KindStockPurchase {
			delta = delta.Neg()
		}
		after := held.Add(delta)
		if after.Sign() == 0 {
			notes = append(notes, "position "+symbol+" closes (0 shares)")
		} else if after.Sign() < 0 {
			notes = append(notes, fmt.Sprintf("warning: position %s would be %s shares — check the ledger around this trade", symbol, after))
		} else {
			notes = append(notes, fmt.Sprintf("%s: %s → %s shares", symbol, held, after))
		}
	}
	if tx.Kind.GIC != nil {
		count := 0
		for _, other := range out.Transactions {
			if other.Kind.Redemption != nil && other.Kind.Redemption.PurchaseID == tx.ID {
				count++
			}
		}
		if count > 0 {
			notes = append(notes, fmt.Sprintf("warning: %d redemption(s) will lose their GIC — their proceeds stay in cash but stop counting toward P&L", count))
		}
	}
	pools := Pools(p, tx.AccountID)
	for _, d := range Deltas(tx) {
		if d.Amount.Sign() != 0 {
			notes = append(notes, fmt.Sprintf("%s cash %s → %s", d.Currency, pools[d.Currency], pools[d.Currency].Sub(d.Amount)))
		}
	}
	return out, notes, nil
}
func FindGIC(p model.Portfolio, account, raw string) (model.Transaction, error) {
	query := strings.TrimSpace(raw)
	var live, matched []model.Transaction
	for _, tx := range p.Transactions {
		if tx.AccountID == account && tx.Kind.GIC != nil {
			live = append(live, tx)
			if strings.EqualFold(tx.Kind.GIC.Product, query) {
				matched = append(matched, tx)
			}
		}
	}
	describe := func(txs []model.Transaction) string {
		var labels []string
		for i, tx := range txs {
			if i == 4 {
				break
			}
			labels = append(labels, "'"+ledger.SummaryLine(tx)+"' ["+ledger.ShortID(tx.ID)+"]")
		}
		return strings.Join(labels, " | ")
	}
	if len(matched) == 1 {
		return matched[0], nil
	}
	if len(matched) > 1 {
		return model.Transaction{}, fmt.Errorf("'%s' matches %d GICs in that account — refer to one by its transaction id: %s", query, len(matched), describe(matched))
	}
	hex := strings.ToUpper(strings.ReplaceAll(query, "-", ""))
	if len(hex) >= 4 && strings.Trim(hex, "0123456789ABCDEF") == "" {
		for _, tx := range live {
			if strings.HasPrefix(strings.ToUpper(strings.ReplaceAll(tx.ID, "-", "")), hex) {
				matched = append(matched, tx)
			}
		}
	}
	if len(matched) == 1 {
		return matched[0], nil
	}
	if len(matched) > 1 {
		return model.Transaction{}, fmt.Errorf("'%s' matches %d GICs — use a longer id: %s", query, len(matched), describe(matched))
	}
	if len(live) == 0 {
		return model.Transaction{}, fmt.Errorf("no GIC purchase found in that account — record the GIC first ('dit tx gic'), then redeem it")
	}
	return model.Transaction{}, fmt.Errorf("no GIC matches '%s' — in that account: %s", query, describe(live))
}
