package mutate

import (
	"dit/internal/decimal"
	"dit/internal/model"
	"encoding/json"
	"testing"
)

func TestMutationValueSemantics(t *testing.T) {
	p := model.Portfolio{Accounts: []model.Account{{ID: "A", ReportingCurrency: model.CAD}}, Transactions: make([]model.Transaction, 0, 10), Tickers: make([]model.EquityTicker, 0, 10)}
	tx := model.Transaction{ID: "T", AccountID: "A", Currency: model.CAD, Kind: model.Kind{Type: model.KindStockPurchase, Stock: &model.StockDetails{Ticker: "ABC", Shares: decimal.FromInt(2), Price: decimal.FromInt(10)}}}
	before, _ := json.Marshal(p)
	out, notes, err := Add(p, tx)
	if err != nil {
		t.Fatal(err)
	}
	after, _ := json.Marshal(p)
	if string(before) != string(after) {
		t.Fatal("Add changed input")
	}
	if len(out.Transactions) != 1 || len(out.Tickers) != 1 || len(notes) != 3 {
		t.Fatal(out, notes)
	}
	bad := tx
	bad.Fee = new(decimal.Decimal)
	*bad.Fee = decimal.FromInt(-1)
	before, _ = json.Marshal(out)
	_, _, err = Edit(out, bad)
	if err == nil {
		t.Fatal("accepted negative fee")
	}
	after, _ = json.Marshal(out)
	if string(before) != string(after) {
		t.Fatal("failed Edit changed input")
	}
	next, _, err := Delete(out, tx)
	if err != nil {
		t.Fatal(err)
	}
	if len(next.Transactions) != 0 || len(out.Transactions) != 1 {
		t.Fatal("Delete changed input")
	}
	after, _ = json.Marshal(out)
	if string(before) != string(after) {
		t.Fatal("Delete altered source backing array")
	}
}
