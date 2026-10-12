package bundle_test

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"dit/internal/bundle"
	"dit/internal/decimal"
	"dit/internal/model"
	"dit/internal/store"
)

const accountID = "11111111-1111-1111-1111-111111111111"
const transactionID = "AAAAAAAA-0000-0000-0000-000000000001"
const purchaseID = "BBBBBBBB-0000-0000-0000-000000000001"

func name(s string) *string      { return &s }
func day(n int64) model.Day      { return model.Day(model.ReferenceDelta + n*86400) }
func stamp(n int64) *model.Stamp { s := model.Stamp(model.ReferenceDelta + n*86400); return &s }
func ledger() model.Portfolio {
	return model.Portfolio{Accounts: []model.Account{{ID: accountID, Name: name("TFSA"), ReportingCurrency: model.CAD, Taxable: true}}, Transactions: []model.Transaction{{ID: transactionID, AccountID: accountID, Date: day(1), Currency: model.CAD, Kind: model.Kind{Type: model.KindDeposit, Amount: decimal.MustParse("12000.000000000000000001")}}}, Tickers: []model.EquityTicker{{Symbol: "AAPL", Currency: model.USD, Tags: []string{}}}}
}
func market(via string, through int64) model.MarketData {
	d := day(through)
	return model.MarketData{LatestQuotes: []model.MarketQuote{}, LatestRates: []model.ExchangeRate{}, Series: map[string]*model.PriceSeries{"AAPL": {Symbol: "AAPL", Currency: model.USD, Points: []model.DailyPrice{{Day: day(1), Price: decimal.MustParse("230.123456789012345678901"), Via: via}}, CoveredThrough: &d}}}
}
func document() bundle.Document {
	p, m := ledger(), market("", 2)
	return bundle.Document{Schema: bundle.Schema, CreatedAt: *stamp(3), Portfolio: &p, Market: &m}
}
func TestRoundTripAndStableEncoding(t *testing.T) {
	d := document()
	raw, err := bundle.Encode(d)
	if err != nil {
		t.Fatal(err)
	}
	again, err := bundle.Encode(d)
	if err != nil || !bytes.Equal(raw, again) {
		t.Fatal("unstable encoding", err)
	}
	got, err := bundle.Decode(raw)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(d, got) {
		t.Fatalf("round trip mismatch\n%s\n%#v", raw, got)
	}
	if !bytes.Contains(raw, []byte("230.123456789012345678901")) {
		t.Fatal("decimal lost precision")
	}
}
func TestRefusals(t *testing.T) {
	for _, tc := range []struct{ json, path string }{
		{`{"accounts":[]}`, "dit store import"},
		{`{"schema":"bundle/2","createdAt":0}`, "unsupported bundle schema 'bundle/2'"},
		{`{"schema":"bundle/1","createdAt":0,"market":{"series":{"AAPL":{"symbol":"AAPL","points":[{"day":0,"price":"oops"}]}}}}`, "market.series.AAPL.points[0].price"},
		{`{"schema":"bundle/1","createdAt":0,"market":{"series":{"AAPL":{"symbol":"AAPL","points":[{"price":230}]}}}}`, "market.series.AAPL.points[0].day"},
		{`{"schema":"bundle/1","createdAt":0,"market":{"series":[1,2]}}`, "market.series"},
		{`{"schema":"bundle/1","createdAt":0,"market":{"series":{"AAPL":{"symbol":"AAPL"}}}}`, "market.series.AAPL.points"},
		{`{"schema":"bundle/1","createdAt":0,"market":{"latestQuotes":[{"symbol":"AAPL"}]}}`, "market.latestQuotes[0].price"},
		{`{"schema":"bundle/1","createdAt":0,"market":{"latestRates":[{"base":"USD","rate":1.4}]}}`, "market.latestRates[0].quote"},
		{`{"schema":"bundle/1","market":{}}`, "createdAt"},
		{`{"schema":"bundle/1","createdAt":0,"portfolio":{"transactions":[{"id":"AAAAAAAA-0000-0000-0000-000000000001","accountID":"11111111-1111-1111-1111-111111111111","currency":"CAD","kind":{"deposit":{"amount":2}}}]}}`, "portfolio.transactions[0].date"},
	} {
		t.Run(tc.path, func(t *testing.T) {
			_, err := bundle.Decode([]byte(tc.json))
			if err == nil || !strings.Contains(err.Error(), tc.path) {
				t.Fatalf("got %v, want refusal naming %s", err, tc.path)
			}
		})
	}
}
func TestEmptyAndSkippedSections(t *testing.T) {
	p, m := ledger(), market("", 2)
	for _, raw := range []string{`{"schema":"bundle/1","createdAt":0}`, `{"schema":"bundle/1","createdAt":0,"portfolio":{},"market":{}}`, `{"schema":"bundle/1","createdAt":0,"portfolio":{"tickers":[{"symbol":"AAPL"}]},"market":{"series":{"AAPL":{"symbol":"AAPL","points":[]}}}}`} {
		d, err := bundle.Decode([]byte(raw))
		if err != nil {
			t.Fatal(err)
		}
		if _, err = bundle.Apply(d, p, m, bundle.Replace); err != bundle.ErrEmpty {
			t.Fatalf("empty bundle: %v", err)
		}
	}
	incoming := market("", 1)
	empty := model.Portfolio{}
	got, err := bundle.Apply(bundle.Document{Portfolio: &empty, Market: &incoming}, p, m, bundle.Replace)
	if err != nil {
		t.Fatal(err)
	}
	if got.WritesPortfolio || !got.WritesMarket || !reflect.DeepEqual(got.Portfolio, p) {
		t.Fatal("empty ledger erased facts")
	}
	if !strings.Contains(strings.Join(got.Notes, " "), "ledger section is empty") {
		t.Fatal(got.Notes)
	}
	got, err = bundle.Apply(bundle.Document{Portfolio: &p}, p, m, bundle.Replace)
	if err != nil || got.WritesMarket || !reflect.DeepEqual(got.Market, m) {
		t.Fatal("ledger-only touched prices", err)
	}
	got, err = bundle.Apply(bundle.Document{Market: &incoming}, p, m, bundle.Replace)
	if err != nil || got.WritesPortfolio || !reflect.DeepEqual(got.Portfolio, p) {
		t.Fatal("market-only touched ledger", err)
	}
}
func TestReplaceRestoresWatermarkMergeDoesNot(t *testing.T) {
	p, m := ledger(), market("", 2)
	incoming := market("", 10)
	s := incoming.Series["AAPL"]
	s.Points = append(s.Points, model.DailyPrice{Day: day(3), Price: decimal.MustParse("250")})
	d := bundle.Document{Portfolio: &p, Market: &incoming}
	replaced, err := bundle.Apply(d, model.Portfolio{}, store.EmptyMarket(), bundle.Replace)
	if err != nil {
		t.Fatal(err)
	}
	if *replaced.Market.Series["AAPL"].CoveredThrough != day(10) || !replaced.WritesPortfolio || !replaced.WritesMarket {
		t.Fatal("replace failed")
	}
	merged, err := bundle.Apply(d, p, m, bundle.Merge)
	if err != nil {
		t.Fatal(err)
	}
	if *merged.Market.Series["AAPL"].CoveredThrough != day(2) || len(merged.Market.Series["AAPL"].Points) != 2 || len(merged.Portfolio.Transactions) != 1 {
		t.Fatal("merge adopted watermark or duplicated transaction")
	}
	fresh, err := bundle.Apply(d, model.Portfolio{}, store.EmptyMarket(), bundle.Merge)
	if err != nil {
		t.Fatal(err)
	}
	if fresh.Market.Series["AAPL"].CoveredThrough != nil || !strings.Contains(strings.Join(fresh.Notes, " "), "run 'dit update' to verify") {
		t.Fatal("new series trusted foreign watermark")
	}
	if len(m.Series["AAPL"].Points) != 1 || *incoming.Series["AAPL"].CoveredThrough != day(10) {
		t.Fatal("apply mutated its arguments")
	}
}
func TestMergeRealClosesRetireGuesses(t *testing.T) {
	incoming := market("", 10)
	incoming.Series["AAPL"].Points[0].Price = decimal.MustParse("400")
	for _, via := range []string{"", "derived via something"} {
		stored := market(via, 2)
		got, err := bundle.Apply(bundle.Document{Market: &incoming}, model.Portfolio{}, stored, bundle.Merge)
		if err != nil {
			t.Fatal(err)
		}
		want := stored.Series["AAPL"].Points[0].Price
		if via != "" {
			want = decimal.MustParse("400")
		}
		if got.Market.Series["AAPL"].Points[0].Price.String() != want.String() {
			t.Fatal("wrong real/derived preference")
		}
	}
	guessed := market("derived", 10)
	measured := market("", 2)
	got, err := bundle.Apply(bundle.Document{Market: &guessed}, model.Portfolio{}, measured, bundle.Merge)
	if err != nil || !reflect.DeepEqual(got.Market, measured) {
		t.Fatal("guess overwrote observation", err)
	}
}
func TestMergeLedgerAndValidation(t *testing.T) {
	p := ledger()
	in := ledger()
	in.Accounts = append(in.Accounts, model.Account{ID: purchaseID, Name: name("Other"), ReportingCurrency: model.USD})
	in.Transactions = append(in.Transactions, model.Transaction{ID: purchaseID, AccountID: purchaseID, Date: day(2), Currency: model.USD, Kind: model.Kind{Type: model.KindDeposit, Amount: decimal.MustParse("200")}})
	in.Tickers = append(in.Tickers, model.EquityTicker{Symbol: "SHOP.TO", Currency: model.CAD})
	got, err := bundle.Apply(bundle.Document{Portfolio: &in}, p, store.EmptyMarket(), bundle.Merge)
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Portfolio.Transactions) != 2 || len(got.Portfolio.Accounts) != 2 || len(got.Portfolio.Tickers) != 2 {
		t.Fatal(got)
	}
	for _, phrase := range []string{"1 new transaction(s)", "1 already present (skipped)", "1 new account(s)", "1 new ticker(s)"} {
		if !strings.Contains(got.Notes[0], phrase) {
			t.Fatal(got.Notes)
		}
	}
	partial := model.Portfolio{Transactions: p.Transactions}
	if _, err = bundle.Apply(bundle.Document{Portfolio: &partial}, p, store.EmptyMarket(), bundle.Merge); err != nil {
		t.Fatal("known account refused", err)
	}
	if _, err = bundle.Apply(bundle.Document{Portfolio: &partial}, p, store.EmptyMarket(), bundle.Replace); err == nil || !strings.Contains(err.Error(), accountID) {
		t.Fatal("orphan accepted", err)
	}
	red := ledger()
	red.Transactions[0].Kind = model.Kind{Type: model.KindGICRedemption, Redemption: &model.GICRedemptionDetails{PurchaseID: purchaseID, Proceeds: decimal.MustParse("10410")}}
	if _, err = bundle.Apply(bundle.Document{Portfolio: &red}, p, store.EmptyMarket(), bundle.Replace); err == nil || !strings.Contains(err.Error(), purchaseID) {
		t.Fatal("dangling GIC accepted", err)
	}
	p.Transactions[0].ID = purchaseID
	p.Transactions[0].Kind = model.Kind{Type: model.KindGICPurchase, GIC: &model.GICDetails{}}
	if _, err = bundle.Apply(bundle.Document{Portfolio: &red}, p, store.EmptyMarket(), bundle.Merge); err != nil {
		t.Fatal("known GIC refused", err)
	}
}
func TestLatestSnapshotUsesNewerObservation(t *testing.T) {
	m := store.EmptyMarket()
	m.LatestQuotes = []model.MarketQuote{{Symbol: "AAPL", Currency: model.USD, Price: decimal.MustParse("240"), AsOf: stamp(10)}}
	m.LatestRates = []model.ExchangeRate{{Base: model.USD, Quote: model.CAD, Rate: decimal.MustParse("1.4"), AsOf: stamp(10)}}
	for _, when := range []int64{1, 11} {
		in := store.EmptyMarket()
		in.LatestQuotes = []model.MarketQuote{{Symbol: "AAPL", Currency: model.USD, Price: decimal.MustParse("250"), AsOf: stamp(when)}}
		in.LatestRates = []model.ExchangeRate{{Base: model.USD, Quote: model.CAD, Rate: decimal.MustParse("1.5"), AsOf: stamp(when)}}
		got, err := bundle.Apply(bundle.Document{Market: &in}, model.Portfolio{}, m, bundle.Merge)
		if err != nil {
			t.Fatal(err)
		}
		wantQ, wantR := "240", "1.4"
		if when > 10 {
			wantQ, wantR = "250", "1.5"
		}
		if got.Market.LatestQuotes[0].Price.String() != wantQ || got.Market.LatestRates[0].Rate.String() != wantR {
			t.Fatal("older snapshot won")
		}
	}
}

// This exercises the actual import CLI when a registry-wired verification
// binary is supplied; the codec-only build still checks the pure refusal path.
func TestRefusedFileLeavesBothStoresByteIdentical(t *testing.T) {
	dir := t.TempDir()
	ledgerStore, _ := store.NewFileStore(dir)
	marketStore, _ := store.NewFileStore(filepath.Join(dir, "market"))
	p, m := ledger(), market("", 2)
	if err := store.SavePortfolio(ledgerStore, &p); err != nil {
		t.Fatal(err)
	}
	if err := store.SaveMarket(marketStore, &m); err != nil {
		t.Fatal(err)
	}
	beforeP, _ := ledgerStore.Load(store.PortfolioKey)
	beforeM, _ := marketStore.Load(store.MarketKey)
	bad := []byte(`{"schema":"bundle/1","createdAt":0,"portfolio":{},"market":{"series":{"AAPL":{"symbol":"AAPL","points":[{"day":0,"price":"oops"}]}}}}`)
	if _, err := bundle.Decode(bad); err == nil {
		t.Fatal("damaged file accepted")
	}
	d := document()
	d.Portfolio.Transactions[0].AccountID = purchaseID
	if _, err := bundle.Apply(d, p, m, bundle.Replace); err == nil {
		t.Fatal("orphan accepted")
	}
	if binary := os.Getenv("DIT_TRANSFER_TEST_BINARY"); binary != "" {
		raw, _ := bundle.Encode(d)
		for _, bad := range [][]byte{bad, raw, []byte(`{"schema":"bundle/2","createdAt":0}`), []byte(`{"schema":"bundle/1","createdAt":0,"portfolio":{}}`)} {
			file := filepath.Join(t.TempDir(), "bad.json")
			if err := os.WriteFile(file, bad, 0600); err != nil {
				t.Fatal(err)
			}
			out, err := exec.Command(binary, "--backend", "file", "--store", dir, "import", file, "--yes").CombinedOutput()
			if exit, ok := err.(*exec.ExitError); !ok || exit.ExitCode() != 2 {
				t.Fatalf("want usage refusal, got %v: %s", err, out)
			}
		}
		backups, _ := filepath.Glob(dir + ".bak-*")
		if len(backups) != 0 {
			t.Fatal("refusal took backup", backups)
		}
	}
	afterP, _ := ledgerStore.Load(store.PortfolioKey)
	afterM, _ := marketStore.Load(store.MarketKey)
	if !bytes.Equal(beforeP, afterP) || !bytes.Equal(beforeM, afterM) {
		t.Fatal("refusal touched a store")
	}
}

func TestCLIHalfFilesAndBackups(t *testing.T) {
	binary := os.Getenv("DIT_TRANSFER_TEST_BINARY")
	if binary == "" {
		t.Skip("set DIT_TRANSFER_TEST_BINARY to a registry-wired binary")
	}
	base := t.TempDir()
	target := filepath.Join(base, "store")
	p, m := ledger(), market("", 2)
	ps, _ := store.NewFileStore(target)
	ms, _ := store.NewFileStore(filepath.Join(target, "market"))
	_ = store.SavePortfolio(ps, &p)
	_ = store.SaveMarket(ms, &m)
	before, _ := ms.Load(store.MarketKey)
	raw, _ := bundle.Encode(bundle.Document{Schema: bundle.Schema, CreatedAt: *stamp(3), Portfolio: &p})
	file := filepath.Join(base, "half.json")
	_ = os.WriteFile(file, raw, 0600)
	out, err := exec.Command(binary, "--backend", "file", "--store", target, "import", file, "--yes").CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	after, _ := ms.Load(store.MarketKey)
	if !bytes.Equal(before, after) {
		t.Fatal("ledger-only import rewrote prices")
	}
	copies, _ := filepath.Glob(target + ".bak-*")
	if len(copies) != 1 {
		t.Fatal("expected one location backup", copies)
	}
	backedUp, err := os.ReadFile(filepath.Join(copies[0], "market", "market.dat"))
	if err != nil || !bytes.Equal(backedUp, before) {
		t.Fatal("backup did not carry nested market", err)
	}
	nested, _ := filepath.Glob(filepath.Join(target, "market.bak-*"))
	if len(nested) != 0 {
		t.Fatal("market backup was nested inside ledger", nested)
	}
	beforeLedger, _ := ps.Load(store.PortfolioKey)
	raw, _ = bundle.Encode(bundle.Document{Schema: bundle.Schema, CreatedAt: *stamp(3), Market: &m})
	_ = os.WriteFile(file, raw, 0600)
	out, err = exec.Command(binary, "--backend", "file", "--store", target, "import", file, "--yes", "--force").CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	afterLedger, _ := ps.Load(store.PortfolioKey)
	if !bytes.Equal(beforeLedger, afterLedger) {
		t.Fatal("market-only import rewrote ledger")
	}
}

func TestSQLiteRefusalKeepsDatabaseBytes(t *testing.T) {
	binary := os.Getenv("DIT_TRANSFER_TEST_BINARY")
	if binary == "" {
		t.Skip("set DIT_TRANSFER_TEST_BINARY to a registry-wired binary")
	}
	dir := t.TempDir()
	target := filepath.Join(dir, "portfolio.sqlite")
	file := filepath.Join(dir, "bundle.json")
	raw, _ := bundle.Encode(document())
	_ = os.WriteFile(file, raw, 0600)
	out, err := exec.Command(binary, "--backend", "sqlite", "--store", target, "import", file, "--yes", "--force").CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	beforeP, _ := os.ReadFile(target)
	beforeM, _ := os.ReadFile(filepath.Join(dir, "market.sqlite"))
	broken := document()
	broken.Portfolio.Transactions[0].AccountID = purchaseID
	raw, _ = bundle.Encode(broken)
	_ = os.WriteFile(file, raw, 0600)
	out, err = exec.Command(binary, "--backend", "sqlite", "--store", target, "import", file, "--yes").CombinedOutput()
	if exit, ok := err.(*exec.ExitError); !ok || exit.ExitCode() != 2 {
		t.Fatalf("want refusal, got %v: %s", err, out)
	}
	afterP, _ := os.ReadFile(target)
	afterM, _ := os.ReadFile(filepath.Join(dir, "market.sqlite"))
	if !bytes.Equal(beforeP, afterP) || !bytes.Equal(beforeM, afterM) {
		t.Fatal("refusal changed database bytes")
	}
	backups, _ := filepath.Glob(filepath.Join(dir, "*.bak-*"))
	if len(backups) != 0 {
		t.Fatal("refusal took a backup", backups)
	}
}

func TestSwiftReadsGoBundle(t *testing.T) {
	swift := "/opt/homebrew/bin/dit"
	if _, err := os.Stat(swift); err != nil {
		t.Skip("Swift oracle unavailable")
	}
	dir := t.TempDir()
	raw, err := bundle.Encode(document())
	if err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(dir, "bundle.json")
	if err = os.WriteFile(file, raw, 0600); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(dir, "restored")
	out, err := exec.Command(swift, "--backend", "file", "--store", target, "import", file, "--yes", "--force").CombinedOutput()
	if err != nil {
		t.Fatalf("Swift refuses Go bundle: %v\n%s\n%s", err, out, raw)
	}
	pRaw, err := os.ReadFile(filepath.Join(target, "portfolio.dat"))
	if err != nil {
		t.Fatal(err)
	}
	mRaw, err := os.ReadFile(filepath.Join(target, "market", "market.dat"))
	if err != nil {
		t.Fatal(err)
	}
	var p model.Portfolio
	var m model.MarketData
	if err = json.Unmarshal(pRaw, &p); err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(mRaw, &m); err != nil {
		t.Fatal(err)
	}
	want := document()
	if !reflect.DeepEqual(p, *want.Portfolio) || !reflect.DeepEqual(m, *want.Market) {
		t.Fatalf("Swift restored different facts\n%s\n%s", pRaw, mRaw)
	}
	exported := filepath.Join(dir, "swift.json")
	out, err = exec.Command(swift, "--backend", "file", "--store", target, "export", "--to", exported).CombinedOutput()
	if err != nil {
		t.Fatalf("Swift export: %v %s", err, out)
	}
	data, _ := os.ReadFile(exported)
	back, err := bundle.Decode(data)
	if err != nil {
		t.Fatalf("Go refuses Swift bundle: %v\n%s", err, data)
	}
	if !reflect.DeepEqual(back.Portfolio, want.Portfolio) || !reflect.DeepEqual(back.Market, want.Market) {
		t.Fatal("Swift to Go lost facts")
	}
}
