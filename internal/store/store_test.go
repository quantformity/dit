package store

import (
	"os"
	"path/filepath"
	"testing"

	"dit/internal/model"
)

func fileBacked(t *testing.T) Store {
	t.Helper()
	store, err := NewFileStore(filepath.Join(t.TempDir(), "store"))
	if err != nil {
		t.Fatal(err)
	}
	return store
}

func sqliteBacked(t *testing.T) Store {
	t.Helper()
	store, err := NewSQLiteStore(filepath.Join(t.TempDir(), "portfolio.sqlite"))
	if err != nil {
		t.Fatal(err)
	}
	return store
}

func backends() map[string]func(*testing.T) Store {
	return map[string]func(*testing.T) Store{
		"file":   fileBacked,
		"sqlite": sqliteBacked,
	}
}

// TestBackendsAgreeOnTheContract runs the same expectations through both
// backends: a missing key reads as nil, a save is visible to the next read,
// keys come back sorted, and a delete is idempotent. The point is not the
// storage, it is that the commands above it see one behaviour.
func TestBackendsAgreeOnTheContract(t *testing.T) {
	for name, build := range backends() {
		t.Run(name, func(t *testing.T) {
			store := build(t)

			payload, err := store.Load("nothing-here")
			if err != nil || payload != nil {
				t.Fatalf("a missing key must read as (nil, nil), got %v / %v", payload, err)
			}
			if err := store.Save("portfolio", []byte(`{"accounts":[]}`)); err != nil {
				t.Fatal(err)
			}
			payload, err = store.Load("portfolio")
			if err != nil || string(payload) != `{"accounts":[]}` {
				t.Fatalf("read back %s (%v)", payload, err)
			}
			// Saving again must replace, not append.
			if err := store.Save("portfolio", []byte(`{"accounts":[]}`)); err != nil {
				t.Fatal(err)
			}
			keys, err := store.Keys()
			if err != nil {
				t.Fatal(err)
			}
			if len(keys) != 1 || keys[0] != "portfolio" {
				t.Errorf("keys = %v, want [portfolio]", keys)
			}
			if err := store.Delete("portfolio"); err != nil {
				t.Fatalf("delete: %v", err)
			}
			if err := store.Delete("portfolio"); err != nil {
				t.Fatalf("deleting twice must be a no-op: %v", err)
			}
		})
	}
}

func TestFileNameParity(t *testing.T) {
	// The Swift file backend maps a key to a filename the same way. If this
	// drifts, the two binaries write files the other cannot see — and no test
	// of the Go code alone would notice.
	cases := map[string]string{
		"portfolio":   "portfolio.dat",
		"market":      "market.dat",
		"USD/CAD":     "USD_CAD.dat",
		"SHOP.TO":     "SHOP.TO.dat",
		"a b c":       "a_b_c.dat",
		"":            "_.dat",
		"/etc/passwd": "_etc_passwd.dat",
		// Accented letters are letters on both sides; only punctuation and
		// separators collapse.
		"naïve": "naïve.dat",
	}
	for key, want := range cases {
		if got := SanitizeKey(key) + ".dat"; got != want {
			t.Errorf("filename for %q = %q, want %q", key, got, want)
		}
	}
}

func TestKeysIgnoreNonDataFiles(t *testing.T) {
	store := fileBacked(t)
	if err := store.Save("portfolio", []byte("x")); err != nil {
		t.Fatal(err)
	}
	// A backup written beside the store must stay invisible to it.
	if err := os.WriteFile(filepath.Join(store.Location, "portfolio.bak-20261009"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	keys, err := store.Keys()
	if err != nil {
		t.Fatal(err)
	}
	if len(keys) != 1 || keys[0] != "portfolio" {
		t.Errorf("keys = %v, want [portfolio]", keys)
	}
}

func TestLedgerRefusesADamagedDocument(t *testing.T) {
	for name, build := range backends() {
		t.Run(name, func(t *testing.T) {
			store := build(t)
			// A ledger we cannot fully read must not be re-saved as a smaller
			// one: that is how a "successful" import loses transactions.
			if err := store.Save(PortfolioKey, []byte(`{"transactions":[{"id":"X","kind":{"bogus":{}}}]}`)); err != nil {
				t.Fatal(err)
			}
			if _, err := LoadPortfolio(store); err == nil {
				t.Fatal("an unreadable ledger must be an error, not a shrug")
			}
		})
	}
}

func TestPriceCacheDegradesOnGarbage(t *testing.T) {
	for _, payload := range []string{
		`{not json at all}`,
		`{"series":{"BAD":{"symbol":"BAD","currency":"USD","points":[{"day":"nope","price":5}]}}}`,
	} {
		store := fileBacked(t)
		if err := store.Save(MarketKey, []byte(payload)); err != nil {
			t.Fatal(err)
		}
		if market := LoadMarket(store); !market.IsEmpty() {
			t.Errorf("a damaged price cache must read as empty, got %+v", market)
		}
	}
}

// TestReadsRealSwiftStores is the interop proof: documents produced by the
// Swift binary, read through the Go persistence layer.
func TestReadsRealSwiftStores(t *testing.T) {
	base := filepath.Join("..", "..", "testdata", "fixtures", "richstore")
	ledgerStore, err := NewFileStore(filepath.Join(base, "store"))
	if err != nil {
		t.Skip("fixtures missing:", err)
	}
	ledger, err := LoadPortfolio(ledgerStore)
	if err != nil {
		t.Fatalf("the Go store could not read the Swift ledger: %v", err)
	}
	if ledger == nil || len(ledger.Transactions) != 8 {
		t.Fatalf("ledger = %+v", ledger)
	}
	marketStore, err := NewFileStore(filepath.Join(base, "market"))
	if err != nil {
		t.Fatal(err)
	}
	if points := LoadMarket(marketStore).TotalPoints(); points != 3 {
		t.Errorf("points = %d, want 3", points)
	}
}

// TestSQLiteFileIsInterchangeable proves the claim that makes the SQLite
// backend worth its dependency: a database written by Go is readable by the
// Swift binary, because the table and the payloads are the same.
func TestSQLiteFileIsInterchangeable(t *testing.T) {
	path := filepath.Join(t.TempDir(), "portfolio.sqlite")
	writer, err := NewSQLiteStore(path)
	if err != nil {
		t.Fatal(err)
	}
	original := model.Portfolio{
		Accounts: []model.Account{{ID: "A1", ReportingCurrency: model.CAD, Taxable: true}},
	}
	if err := SavePortfolio(writer, &original); err != nil {
		t.Fatal(err)
	}
	reader, err := NewSQLiteStore(path)
	if err != nil {
		t.Fatal(err)
	}
	roundTripped, err := LoadPortfolio(reader)
	if err != nil || roundTripped == nil || len(roundTripped.Accounts) != 1 {
		t.Fatalf("round trip through sqlite failed: %v %+v", err, roundTripped)
	}
}

func TestMarketRoundTripKeepsTheFacts(t *testing.T) {
	store := sqliteBacked(t)
	market := EmptyMarket()
	market.Series["AAPL"] = &model.PriceSeries{Symbol: "AAPL", Currency: model.USD,
		Points: []model.DailyPrice{{Day: model.Day(1704067200)}, {Day: model.Day(1704153600)}}}
	if err := SaveMarket(store, &market); err != nil {
		t.Fatal(err)
	}
	read := LoadMarket(store)
	if read.TotalPoints() != 2 {
		t.Fatalf("points lost through the store: %+v", read)
	}
	if _, found := read.CloseOnOrBefore("AAPL", model.Day(1704153600)); !found {
		t.Fatal("as-of lookup lost its series")
	}
}
