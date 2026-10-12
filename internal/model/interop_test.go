package model

import (
	"encoding/json"
	"os"
	"testing"

	"dit/internal/decimal"
)

// The fixtures in testdata/fixtures/richstore were written by the Swift
// binary, not by hand. They are the interop proof: if the Go model cannot read
// what the Swift writer produced, the port is not a port.

func readFixture(t *testing.T, path string) []byte {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Skip("fixture missing:", err)
	}
	return data
}

func TestReadsSwiftPortfolioStore(t *testing.T) {
	data := readFixture(t, "../../testdata/fixtures/richstore/store/portfolio.dat")
	var portfolio Portfolio
	if err := json.Unmarshal(data, &portfolio); err != nil {
		t.Fatalf("the Swift store did not decode: %v", err)
	}
	if len(portfolio.Accounts) != 2 {
		t.Errorf("accounts = %d, want 2", len(portfolio.Accounts))
	}
	if len(portfolio.Tickers) != 1 || portfolio.Tickers[0].Symbol != "SHOP.TO" {
		t.Errorf("tickers = %+v", portfolio.Tickers)
	}
	if len(portfolio.Tickers) == 1 {
		want := []string{"core", "dividends"}
		if len(portfolio.Tickers[0].Tags) != 2 ||
			portfolio.Tickers[0].Tags[0] != want[0] ||
			portfolio.Tickers[0].Tags[1] != want[1] {
			t.Errorf("tags = %v, want %v", portfolio.Tickers[0].Tags, want)
		}
	}
	if len(portfolio.Transactions) != 8 {
		t.Fatalf("transactions = %d, want 8", len(portfolio.Transactions))
	}
	// Every transaction kind has to survive, including the two shapes the
	// Swift encoder uses for associated values.
	kinds := map[KindType]int{}
	for _, transaction := range portfolio.Transactions {
		kinds[transaction.Kind.Type]++
	}
	for _, kind := range []KindType{KindDeposit, KindWithdrawal, KindStockPurchase,
		KindStockSale, KindDividend, KindGICPurchase, KindGICRedemption, KindFXConversion} {
		if kinds[kind] != 1 {
			t.Errorf("kind %s decoded %d times, want 1 (all eight kinds must decode)", kind, kinds[kind])
		}
	}
}

func TestDerivedFiguresMatchSwiftArithmetic(t *testing.T) {
	data := readFixture(t, "../../testdata/fixtures/richstore/store/portfolio.dat")
	var portfolio Portfolio
	if err := json.Unmarshal(data, &portfolio); err != nil {
		t.Fatal(err)
	}
	// Hand-computed from the fixture, and cross-checked against what the
	// Swift binary reports for the same store. If the decimal port drifts by
	// even a cent, one of these stops holding.
	want := map[string]string{
		"deposit":       "25000",
		"withdrawal":    "-1200.5",
		"stockPurchase": "-884.49", // -(10 × 88.25) - 1.99 fee
		"stockSale":     "407.61",  // (4 × 102.40) - 1.99 fee
		"dividend":      "12.34",
		"gicPurchase":   "-5000",
		"gicRedemption": "5210.75",
		"fxConversion":  "1357.8", // the TO leg, fee-free
	}
	got := map[string]string{}
	for _, transaction := range portfolio.Transactions {
		got[string(transaction.Kind.Type)] = transaction.CashImpact().String()
	}
	for kind, expected := range want {
		if got[kind] != expected {
			t.Errorf("cash impact of %s = %s, want %s", kind, got[kind], expected)
		}
	}
	// The trade total is derived from shares × price, never stored.
	buy := findKind(t, portfolio, KindStockPurchase)
	if !buy.Kind.Stock.Amount().Equal(decimal.MustParse("882.5")) {
		t.Errorf("buy amount = %s, want 882.5", buy.Kind.Stock.Amount())
	}
	// Shares held must go through the whole ledger: 10 bought, 4 sold.
	tfsa := portfolio.Accounts[0]
	if held := portfolio.TrackedSharesHeld(tfsa.ID, "SHOP.TO").String(); held != "6" {
		t.Errorf("shares held = %s, want 6", held)
	}
}

func findKind(t *testing.T, portfolio Portfolio, kind KindType) Transaction {
	t.Helper()
	for _, transaction := range portfolio.Transactions {
		if transaction.Kind.Type == kind {
			return transaction
		}
	}
	t.Fatalf("no %s transaction in the fixture", kind)
	return Transaction{}
}

func TestReadsSwiftMarketStore(t *testing.T) {
	data := readFixture(t, "../../testdata/fixtures/richstore/market/market.dat")
	var market MarketData
	if err := json.Unmarshal(data, &market); err != nil {
		t.Fatalf("the Swift market store did not decode: %v", err)
	}
	if len(market.Series) != 2 {
		t.Fatalf("series = %d, want 2 (%v)", len(market.Series), market.Series)
	}
	shop := market.SeriesFor("SHOP.TO")
	if shop == nil || len(shop.Points) != 2 {
		t.Errorf("SHOP.TO series = %+v", shop)
	}
	if shop != nil {
		// The fixture was seeded from a CSV with no currency column, so this
		// series legitimately has no currency: that is absent data, not damage.
		if shop.Currency != Unknown {
			t.Errorf("SHOP.TO currency = %q, want Unknown", shop.Currency)
		}
		if first := shop.Points[0]; Day(first.Day) != Day(DayStartUTC(int64(first.Day))) {
			t.Errorf("days must be normalized to UTC midnight, got %d", first.Day)
		}
	}
	pair := market.SeriesFor("USD/CAD")
	if pair == nil || len(pair.Points) != 1 {
		t.Errorf("USD/CAD series = %+v", pair)
	}
	if market.TotalPoints() != 3 {
		t.Errorf("total points = %d, want 3", market.TotalPoints())
	}
}

func TestRoundTripKeepsEveryFact(t *testing.T) {
	data := readFixture(t, "../../testdata/fixtures/richstore/store/portfolio.dat")
	var first Portfolio
	if err := json.Unmarshal(data, &first); err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(first)
	if err != nil {
		t.Fatalf("re-encoding the Swift store failed: %v", err)
	}
	var second Portfolio
	if err := json.Unmarshal(encoded, &second); err != nil {
		t.Fatalf("the round-tripped document no longer decodes: %v", err)
	}
	if len(second.Transactions) != len(first.Transactions) {
		t.Fatalf("lost transactions: %d → %d", len(first.Transactions), len(second.Transactions))
	}
	for i, transaction := range first.Transactions {
		if !transaction.CashImpact().Equal(second.Transactions[i].CashImpact()) {
			t.Errorf("transaction %d changed cash impact: %s → %s", i,
				transaction.CashImpact(), second.Transactions[i].CashImpact())
		}
	}
	if string(encoded) == string(data) {
		t.Log("note: bytes match, which is luck — Swift writes dictionary keys in hash order")
	}
}

// TestAcceptsSwiftKeyOrder feeds back the same document with its keys in a
// different order. The Swift encoder leaves dictionary (and sometimes struct)
// key order to the process hash seed, so two runs of the same import produce
// three different files. Decoding must not care.
func TestAcceptsSwiftKeyOrder(t *testing.T) {
	data := readFixture(t, "../../testdata/fixtures/richstore/store/portfolio.dat")
	var shuffled []byte
	if err := json.Unmarshal(data, &map[string]any{}); err != nil {
		t.Fatal(err)
	}
	// Re-encode through a generic map to scramble key order, then decode.
	var generic map[string]any
	if err := json.Unmarshal(data, &generic); err != nil {
		t.Fatal(err)
	}
	scrambled, err := json.Marshal(generic)
	if err != nil {
		t.Fatal(err)
	}
	shuffled = scrambled
	var portfolio Portfolio
	if err := json.Unmarshal(shuffled, &portfolio); err != nil {
		t.Fatalf("key order should not matter: %v", err)
	}
	if len(portfolio.Transactions) != 8 {
		t.Errorf("lost transactions through key re-ordering: %d", len(portfolio.Transactions))
	}
}

// TestMissingSectionsDecodeEmpty documents the lenient contract: a document
// saved before a section existed still loads, because the sections are arrays
// that may be absent.
func TestMissingSectionsDecodeEmpty(t *testing.T) {
	var portfolio Portfolio
	if err := json.Unmarshal([]byte(`{"accounts":[]}`), &portfolio); err != nil {
		t.Fatalf("a partial document must load: %v", err)
	}
	if len(portfolio.Transactions) != 0 || len(portfolio.Tickers) != 0 {
		t.Error("missing sections should decode as empty, not nil-filled junk")
	}
	// Taxable defaults to true: assuming the less favourable tax treatment
	// is the only safe default when the file does not say.
	var account Account
	if err := json.Unmarshal([]byte(`{"id":"X","reportingCurrency":"CAD"}`), &account); err != nil {
		t.Fatal(err)
	}
	if !account.Taxable {
		t.Error("an account without a taxable key must default to taxable")
	}
}

// TestBrokenMarketDataDegrades pins the deliberate difference from a bundle
// import: a damaged cache decodes as empty rather than refusing to run.
//
// A file that is not JSON at all is a different case and is left to the store
// layer, where it is covered: encoding/json rejects a syntax error before any
// type gets a say, and the store turns that into "empty cache".
func TestBrokenMarketDataDegrades(t *testing.T) {
	cases := []string{
		`{"series":{"BAD":{"symbol":"BAD","currency":"USD","points":[{"day":"nope","price":5}]}}}`,
		`{"series":null,"latestQuotes":null}`,
		`{"series":{"GOOD":{"symbol":"GOOD","currency":"USD","points":[]}},"latestQuotes":"nonsense"}`,
	}
	for _, payload := range cases {
		var market MarketData
		if err := json.Unmarshal([]byte(payload), &market); err != nil {
			t.Errorf("market data must degrade rather than fail (%.40s): %v", payload, err)
		}
	}
}
