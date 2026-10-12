// Package ledger projects recorded events without changing the portfolio.
package ledger

import (
	"fmt"
	"sort"
	"strings"

	"dit/internal/decimal"
	"dit/internal/model"
)

type Money struct {
	Currency model.Currency
	Amount   decimal.Decimal
}
type StatementRow struct {
	Transaction                model.Transaction
	Debits, Credits, CashAfter []Money
}

// ViewOptions carries resolved filters; nil distinguishes an absent filter
// from a filter whose value is empty. Account scope alone keeps statement mode.
type ViewOptions struct {
	AccountID    *string
	Kind         *model.KindType
	Ticker       *string
	Since, Until *model.Day
	Limit        *int
}

func StatementMode(v ViewOptions) bool {
	return v.Kind == nil && v.Ticker == nil && v.Since == nil && v.Until == nil && v.Limit == nil
}

func Ordered(transactions []model.Transaction) []model.Transaction {
	result := append([]model.Transaction(nil), transactions...)
	sort.SliceStable(result, func(i, j int) bool { return result[i].Date < result[j].Date })
	return result
}

func PlainTransactions(p *model.Portfolio, v ViewOptions) []model.Transaction {
	if p == nil {
		return nil
	}
	var result []model.Transaction
	for _, tx := range p.Transactions {
		if v.AccountID != nil && !strings.EqualFold(tx.AccountID, *v.AccountID) {
			continue
		}
		if v.Kind != nil && tx.Kind.Type != *v.Kind {
			continue
		}
		if v.Ticker != nil && tx.TickerSymbol() != *v.Ticker {
			continue
		}
		if v.Since != nil && tx.Date < *v.Since {
			continue
		}
		if v.Until != nil && tx.Date > *v.Until {
			continue
		}
		result = append(result, tx)
	}
	result = Ordered(result)
	if v.Limit != nil && *v.Limit > 0 && len(result) > *v.Limit {
		result = result[len(result)-*v.Limit:]
	}
	return result
}

func AccountRows(transactions []model.Transaction) []StatementRow {
	cash := map[model.Currency]decimal.Decimal{}
	var rows []StatementRow
	for _, tx := range Ordered(transactions) {
		row := StatementRow{Transaction: tx}
		impact := tx.CashImpact()
		if tx.Kind.Type == model.KindFXConversion && tx.Kind.FX != nil {
			fx := tx.Kind.FX
			if fx.FromAmount.Sign() > 0 {
				row.Debits = append(row.Debits, Money{fx.FromCurrency, fx.FromAmount})
			}
			if impact.Sign() > 0 {
				row.Credits = append(row.Credits, Money{tx.Currency, impact})
			}
			// FX has a second purse; CashImpact already accounts for the incoming fee.
			cash[fx.FromCurrency] = cash[fx.FromCurrency].Sub(fx.FromAmount)
		} else if impact.Sign() < 0 {
			row.Debits = append(row.Debits, Money{tx.Currency, impact.Neg()})
		} else if impact.Sign() > 0 {
			row.Credits = append(row.Credits, Money{tx.Currency, impact})
		}
		cash[tx.Currency] = cash[tx.Currency].Add(impact)
		for currency, amount := range cash {
			if amount.Sign() != 0 {
				row.CashAfter = append(row.CashAfter, Money{currency, amount})
			}
		}
		sort.Slice(row.CashAfter, func(i, j int) bool { return row.CashAfter[i].Currency < row.CashAfter[j].Currency })
		rows = append(rows, row)
	}
	return rows
}

func Rows(p *model.Portfolio, v ViewOptions) []StatementRow {
	if p == nil {
		return nil
	}
	if v.AccountID != nil {
		return AccountRows(p.TransactionsIn(*v.AccountID))
	}
	var result []StatementRow
	for _, account := range p.Accounts {
		result = append(result, AccountRows(p.TransactionsIn(account.ID))...)
	}
	// Equal-date rows must retain the order in which their balances were replayed.
	sort.SliceStable(result, func(i, j int) bool { return result[i].Transaction.Date < result[j].Transaction.Date })
	return result
}

func Currencies(rows []StatementRow) []model.Currency {
	seen := map[model.Currency]bool{}
	for _, row := range rows {
		for _, entries := range [][]Money{row.Debits, row.Credits, row.CashAfter} {
			for _, entry := range entries {
				seen[entry.Currency] = true
			}
		}
	}
	result := make([]model.Currency, 0, len(seen))
	for currency := range seen {
		result = append(result, currency)
	}
	sort.Slice(result, func(i, j int) bool { return result[i] < result[j] })
	return result
}

func ShortID(id string) string {
	id = strings.ToUpper(id)
	if len(id) > 8 {
		return id[:8]
	}
	return id
}

// SummaryLine deliberately uses exact, ungrouped decimals: these are recorded
// facts, unlike the rounded money in the statement's cash columns.
func SummaryLine(tx model.Transaction) string {
	var line string
	switch tx.Kind.Type {
	case model.KindDeposit, model.KindWithdrawal:
		line = fmt.Sprintf("%s %s %s", tx.Kind.Type, tx.Kind.Amount, tx.Currency)
	case model.KindStockPurchase, model.KindStockSale:
		if d := tx.Kind.Stock; d != nil {
			verb := "buy"
			if tx.Kind.Type == model.KindStockSale {
				verb = "sell"
			}
			line = fmt.Sprintf("%s %s %s @ %s", verb, d.Shares, d.Ticker, d.Price)
		}
	case model.KindDividend:
		if d := tx.Kind.Dividend; d != nil {
			line = fmt.Sprintf("dividend %s %s %s", d.Ticker, d.Amount, tx.Currency)
		}
	case model.KindGICPurchase:
		if d := tx.Kind.GIC; d != nil {
			line = fmt.Sprintf("GIC '%s' %s %s @ %s%% until %s", d.Product, d.Principal, tx.Currency, d.Rate.Mul(decimal.FromInt(100)), d.MaturityDate)
		}
	case model.KindGICRedemption:
		if d := tx.Kind.Redemption; d != nil {
			line = fmt.Sprintf("GIC redemption %s %s (purchase %s)", d.Proceeds, tx.Currency, ShortID(d.PurchaseID))
		}
	case model.KindFXConversion:
		if d := tx.Kind.FX; d != nil {
			line = fmt.Sprintf("fx %s %s → %s %s", d.FromAmount, d.FromCurrency, d.ToAmount, tx.Currency)
		}
	}
	if tx.Fee != nil && tx.Fee.Sign() != 0 {
		line += " fee " + tx.Fee.String()
	}
	return line
}
