package ledger

import (
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"

	"dit/internal/decimal"
	"dit/internal/model"
)

func d(s string) decimal.Decimal { return decimal.MustParse(s) }
func moneyStrings(entries []Money) []string {
	result := make([]string, 0, len(entries))
	for _, entry := range entries {
		result = append(result, string(entry.Currency)+" "+entry.Amount.String())
	}
	return result
}
func wantMoney(t *testing.T, entries []Money, want ...string) {
	t.Helper()
	if got := moneyStrings(entries); !reflect.DeepEqual(got, append([]string{}, want...)) {
		t.Fatalf("money = %v, want %v", got, want)
	}
}
func tx(id string, day model.Day, currency model.Currency, kind model.Kind, fee string) model.Transaction {
	result := model.Transaction{ID: id, Date: day, AccountID: "A", Currency: currency, Kind: kind}
	if fee != "" {
		value := d(fee)
		result.Fee = &value
	}
	return result
}

func TestEveryCashKindAndSnapshots(t *testing.T) {
	transactions := []model.Transaction{
		tx("Z", 1, model.CAD, model.Kind{Type: model.KindDeposit, Amount: d("1000")}, "99"),
		tx("Y", 1, model.CAD, model.Kind{Type: model.KindWithdrawal, Amount: d("10")}, "99"),
		tx("X", 2, model.CAD, model.Kind{Type: model.KindStockPurchase, Stock: &model.StockDetails{Shares: d("2.5"), Price: d("10.1")}}, ".05"),
		tx("W", 3, model.CAD, model.Kind{Type: model.KindStockSale, Stock: &model.StockDetails{Shares: d("1"), Price: d("12")}}, ".01"),
		tx("V", 4, model.CAD, model.Kind{Type: model.KindDividend, Dividend: &model.DividendDetails{Amount: d("1.23456789")}}, ".01"),
		tx("U", 5, model.CAD, model.Kind{Type: model.KindGICPurchase, GIC: &model.GICDetails{Principal: d("100")}}, ".01"),
		tx("T", 6, model.CAD, model.Kind{Type: model.KindGICRedemption, Redemption: &model.GICRedemptionDetails{Proceeds: d("110")}}, ".01"),
		tx("S", 7, model.USD, model.Kind{Type: model.KindFXConversion, FX: &model.FXDetails{FromCurrency: model.CAD, FromAmount: d("100"), ToAmount: d("70")}}, ".1"),
	}
	rows := AccountRows(transactions)
	wantMoney(t, rows[0].Credits, "CAD 1000")
	wantMoney(t, rows[1].Debits, "CAD 10")
	wantMoney(t, rows[2].Debits, "CAD 25.3")
	wantMoney(t, rows[3].Credits, "CAD 11.99")
	wantMoney(t, rows[4].Credits, "CAD 1.22456789")
	wantMoney(t, rows[5].Debits, "CAD 100.01")
	wantMoney(t, rows[6].Credits, "CAD 109.99")
	wantMoney(t, rows[7].Debits, "CAD 100")
	wantMoney(t, rows[7].Credits, "USD 69.9")
	wantMoney(t, rows[7].CashAfter, "CAD 887.89456789", "USD 69.9")
	wantMoney(t, rows[0].CashAfter, "CAD 1000")
	if rows[0].Transaction.ID != "Z" || rows[1].Transaction.ID != "Y" {
		t.Fatal("same-day replay order changed")
	}
}

func TestZeroNegativeAndHistoricalCurrencies(t *testing.T) {
	rows := AccountRows([]model.Transaction{
		tx("1", 1, model.CAD, model.Kind{Type: model.KindDeposit, Amount: d("100")}, ""),
		tx("2", 2, model.USD, model.Kind{Type: model.KindFXConversion, FX: &model.FXDetails{FromCurrency: model.CAD, FromAmount: d("100"), ToAmount: d("70")}}, "70"),
		tx("3", 3, model.CAD, model.Kind{Type: model.KindWithdrawal, Amount: d(".00000001")}, ""),
		tx("4", 4, model.USD, model.Kind{Type: model.KindFXConversion, FX: &model.FXDetails{FromCurrency: model.CAD, FromAmount: d("1"), ToAmount: d("1")}}, "2"),
	})
	wantMoney(t, rows[1].CashAfter)
	wantMoney(t, rows[1].Credits)
	wantMoney(t, rows[2].CashAfter, "CAD -0.00000001")
	wantMoney(t, rows[3].CashAfter, "CAD -1.00000001", "USD -1")
	wantMoney(t, rows[3].Credits)
	if got := Currencies(rows); !reflect.DeepEqual(got, []model.Currency{model.CAD, model.USD}) {
		t.Fatal(got)
	}
}

func TestPortfolioMergeDoesNotSumAccounts(t *testing.T) {
	p := &model.Portfolio{Accounts: []model.Account{{ID: "A"}, {ID: "B"}}}
	first := tx("FFFF", 1, model.CAD, model.Kind{Type: model.KindDeposit, Amount: d("10")}, "")
	second := tx("AAAA", 1, model.CAD, model.Kind{Type: model.KindDeposit, Amount: d("20")}, "")
	second.AccountID = "B"
	third := tx("0000", 1, model.CAD, model.Kind{Type: model.KindWithdrawal, Amount: d("1")}, "")
	p.Transactions = []model.Transaction{second, first, third}
	before, _ := json.Marshal(p)
	rows := Rows(p, ViewOptions{})
	if rows[0].Transaction.ID != "FFFF" || rows[1].Transaction.ID != "0000" || rows[2].Transaction.ID != "AAAA" {
		t.Fatal("merge did not retain account replay order")
	}
	wantMoney(t, rows[1].CashAfter, "CAD 9")
	wantMoney(t, rows[2].CashAfter, "CAD 20")
	after, _ := json.Marshal(p)
	if string(before) != string(after) {
		t.Fatal("projection mutated its input")
	}
	account := "b"
	scoped := Rows(p, ViewOptions{AccountID: &account})
	if len(scoped) != 1 {
		t.Fatal(scoped)
	}
}

func TestFiltersAndMode(t *testing.T) {
	p := &model.Portfolio{Transactions: []model.Transaction{
		tx("1", 3, model.CAD, model.Kind{Type: model.KindDeposit, Amount: d("10")}, ""),
		tx("2", 1, model.CAD, model.Kind{Type: model.KindStockPurchase, Stock: &model.StockDetails{Ticker: "ABC", Shares: d("1"), Price: d("1")}}, ""),
		tx("3", 3, model.CAD, model.Kind{Type: model.KindDeposit, Amount: d("20")}, ""),
	}}
	limit := 1
	account := "A"
	kind := model.KindDeposit
	ticker := "ABC"
	since := model.Day(3)
	until := model.Day(1)
	if !StatementMode(ViewOptions{AccountID: &account}) {
		t.Fatal("account scope disabled statement")
	}
	for _, v := range []ViewOptions{{Kind: &kind}, {Ticker: &ticker}, {Since: &since}, {Until: &until}, {Limit: &limit}} {
		if StatementMode(v) {
			t.Fatal("filter left statement enabled")
		}
	}
	got := PlainTransactions(p, ViewOptions{Kind: &kind, Since: &since, Limit: &limit})
	if len(got) != 1 || got[0].ID != "3" {
		t.Fatal(got)
	}
	got = PlainTransactions(p, ViewOptions{Ticker: &ticker, Until: &until})
	if len(got) != 1 || got[0].ID != "2" {
		t.Fatal(got)
	}
	if Rows(nil, ViewOptions{}) != nil || PlainTransactions(nil, ViewOptions{}) != nil {
		t.Fatal("nil portfolio")
	}
}

func TestSwiftFixtureExactDetails(t *testing.T) {
	data, err := os.ReadFile("../../testdata/ledger/portfolio.json")
	if err != nil {
		t.Fatal(err)
	}
	var p model.Portfolio
	if err := json.Unmarshal(data, &p); err != nil {
		t.Fatal(err)
	}
	for _, tx := range p.Transactions {
		golden, err := os.ReadFile("../../testdata/ledger/show-" + ShortID(tx.ID) + ".txt")
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(golden), "  Details:   "+SummaryLine(tx)+"\n") {
			t.Fatalf("summary differs from Swift: %s", SummaryLine(tx))
		}
	}
	rows := Rows(&p, ViewOptions{})
	if len(rows) != 9 {
		t.Fatal(len(rows))
	}
	wantMoney(t, rows[2].CashAfter, "USD 10000")
	wantMoney(t, rows[3].Credits, "USD 1399.67")
}
