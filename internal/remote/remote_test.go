package remote

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sort"
	"strings"
	"sync"
	"testing"

	"dit/internal/store"
)

// memStore is an in-memory store.Store for protocol tests.
var testUUID = []string{
	"aaaaaaaa-0000-4000-8000-000000000000",
	"bbbbbbbb-0000-4000-8000-000000000000",
	"cccccccc-0000-4000-8000-000000000000",
	"dddddddd-0000-4000-8000-000000000000",
	"eeeeeeee-0000-4000-8000-000000000000",
}

func memStore(data map[string][]byte, mu *sync.Mutex) store.Store {
	if data == nil {
		data = map[string][]byte{}
	}
	return store.Store{
		Location: "memory",
		Load: func(key string) ([]byte, error) {
			mu.Lock()
			defer mu.Unlock()
			stored, ok := data[key]
			if !ok {
				return nil, nil
			}
			out := make([]byte, len(stored))
			copy(out, stored)
			return out, nil
		},
		Save: func(key string, payload []byte) error {
			mu.Lock()
			defer mu.Unlock()
			cp := make([]byte, len(payload))
			copy(cp, payload)
			data[key] = cp
			return nil
		},
		Delete: func(key string) error {
			mu.Lock()
			defer mu.Unlock()
			delete(data, key)
			return nil
		},
		Keys: func() ([]string, error) {
			mu.Lock()
			defer mu.Unlock()
			keys := []string{}
			for key := range data {
				keys = append(keys, key)
			}
			sort.Strings(keys)
			return keys, nil
		},
	}
}

type rig struct {
	ledger store.Store
	market store.Store
	srv    *httptest.Server
}

func newRig(t *testing.T, ledgerData, marketData map[string][]byte, token string, immutable bool) (*Connection, *rig) {
	t.Helper()
	mu := &sync.Mutex{}
	ledger := memStore(ledgerData, mu)
	market := memStore(marketData, mu)
	srv := httptest.NewServer(NewServer(ledger, market, token, immutable, "test-version"))
	t.Cleanup(srv.Close)
	conn, err := NewConnection(srv.URL, "", false)
	if err != nil {
		t.Fatalf("NewConnection: %v", err)
	}
	return conn, &rig{ledger: ledger, market: market, srv: srv}
}

// srv.URL is "http://127.0.0.1:PORT"; NewConnection accepts full URLs.
func TestNormalizeTarget(t *testing.T) {
	cases := []struct {
		raw    string
		expect string
	}{
		{"192.168.1.20", "192.168.1.20:8348"},
		{"192.168.1.20:9000", "192.168.1.20:9000"},
		{"http://192.168.1.20:9000", "192.168.1.20:9000"},
		{"  host-1:1234 ", "host-1:1234"},
	}
	for _, c := range cases {
		address, baseURL, err := NormalizeTarget(c.raw)
		if err != nil {
			t.Fatalf("NormalizeTarget(%q): %v", c.raw, err)
		}
		if address != c.expect {
			t.Errorf("NormalizeTarget(%q) address = %q, want %q", c.raw, address, c.expect)
		}
		if want := "http://" + c.expect; baseURL != want {
			t.Errorf("NormalizeTarget(%q) base = %q, want %q", c.raw, baseURL, want)
		}
	}
	bad := []string{"", "https://host:1", "http://host/path", "http://host:99999", "http://host:0"}
	for _, raw := range bad {
		if _, _, err := NormalizeTarget(raw); err == nil {
			t.Errorf("NormalizeTarget(%q) accepted, want error", raw)
		}
	}
}

func TestVerifyChecksProtocol(t *testing.T) {
	notDit := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewEncoder(w).Encode(map[string]any{"schema": "other/1"})
	}))
	t.Cleanup(notDit.Close)
	conn, _ := NewConnection(notDit.URL, "", false)
	if _, err := conn.Verify(); err == nil || !strings.Contains(err.Error(), "not a dit server") {
		t.Fatalf("Verify against a non-dit server: got %v, want protocol mismatch", err)
	}

	conn2, _ := NewConnection("http://127.0.0.1:1", "", false) // nothing listens
	if _, err := conn2.Verify(); err == nil {
		t.Fatal("Verify against a dead port: want connection error")
	}
}

func TestGetAndPutWithETag(t *testing.T) {
	ledger := map[string][]byte{store.PortfolioKey: []byte(`{"accounts":[]}`)}
	conn, _ := newRig(t, ledger, nil, "", false)

	original, etag, err := conn.Get(store.PortfolioKey)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if string(original) != `{"accounts":[]}` || etag == "" {
		t.Fatalf("Get returned %q etag=%q", original, etag)
	}
	if got := ETag(nil); got != `"none"` {
		t.Errorf("ETag(nil) = %q, want %q", got, `"none"`)
	}

	next := []byte(`{"accounts":[{"id":"aaaaaaaa-0000-4000-8000-000000000000"}]}`)
	if err := conn.Put(store.PortfolioKey, next); err != nil {
		t.Fatalf("Put: %v", err)
	}
	again, _, err := conn.Get(store.PortfolioKey) // cached — but verify live too
	if err != nil || !bytes.Equal(again, next) {
		t.Fatalf("Get after Put: %q %v", again, err)
	}

	// A stale If-Match must be refused: the server keeps its own copy.
	req, _ := http.NewRequest(http.MethodPut, conn.BaseURL+"/api/v1/store/"+store.PortfolioKey, bytes.NewReader([]byte(`{}`)))
	req.Header.Set("If-Match", ETag([]byte(`{"accounts":[]}`))) // the OLD document's tag
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusConflict {
		t.Errorf("stale If-Match: got HTTP %d, want 409", res.StatusCode)
	}
}

func TestPutWithoutPriorReadIsStillConditional(t *testing.T) {
	ledger := map[string][]byte{store.PortfolioKey: []byte(`{"accounts":[]}`)}
	conn, _ := newRig(t, ledger, nil, "", false)
	// Fresh connection: never read. Put must read first, then write.
	if err := conn.Put(store.PortfolioKey, []byte(`{"accounts":[{"id":"aaaaaaaa-0000-4000-8000-000000000000"}]}`)); err != nil {
		t.Fatalf("Put after no read: %v", err)
	}
	data, _, err := conn.Get(store.PortfolioKey)
	if err != nil || !strings.Contains(string(data), testUUID[0]) {
		t.Fatalf("document after blind Put: %q %v", data, err)
	}
}

func TestImmutableRejectsWrites(t *testing.T) {
	conn, _ := newRig(t, nil, nil, "", true)
	info, err := conn.Verify()
	if err != nil || !info.Immutable {
		t.Fatalf("Verify: %v %v", info, err)
	}
	if err := conn.Put(store.PortfolioKey, []byte(`{}`)); err == nil || !strings.Contains(err.Error(), "immutable") {
		t.Errorf("Put to immutable server: got %v, want immutable error", err)
	}
	if err := conn.PutDocuments([]byte(`{}`), nil); err == nil {
		t.Error("PutDocuments to immutable server: want error")
	}
	// Reads still work.
	if _, _, err := conn.Get(store.MarketKey); err != nil {
		t.Errorf("Get on immutable server: %v", err)
	}
}

func TestReadOnlyConnectionRefusesWritesLocally(t *testing.T) {
	conn, _ := newRig(t, nil, nil, "", false)
	conn.ReadOnly = true
	if err := conn.Put(store.PortfolioKey, []byte(`{}`)); err == nil || !strings.Contains(err.Error(), "read-only") {
		t.Errorf("read-only Put: got %v, want local refusal", err)
	}
}

func TestTokenAuth(t *testing.T) {
	mu := &sync.Mutex{}
	ledger := map[string][]byte{}
	market := map[string][]byte{}
	srv := httptest.NewServer(NewServer(memStore(ledger, mu), memStore(market, mu), "s3cret", false, ""))
	t.Cleanup(srv.Close)

	open, err := NewConnection(srv.URL, "", false)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := open.Verify(); err == nil {
		t.Fatal("Verify without token: want 401")
	} else if clientErr, ok := err.(*ClientError); !ok || clientErr.Status != http.StatusUnauthorized {
		t.Fatalf("Verify without token: %v (status %v)", err, clientErr)
	}

	authorized, _ := NewConnection(srv.URL, "s3cret", false)
	info, err := authorized.Verify()
	if err != nil || !info.AuthEnabled {
		t.Fatalf("Verify with token: %v %v", info, err)
	}
}

func TestPutDocumentsPairAndConflict(t *testing.T) {
	ledger := map[string][]byte{store.PortfolioKey: []byte(`{"accounts":[]}`)}
	market := map[string][]byte{store.MarketKey: []byte(`{"latestQuotes":[]}`)}
	conn, r := newRig(t, ledger, market, "", false)

	_, pEtag, _ := conn.Get(store.PortfolioKey)
	_, mEtag, _ := conn.Get(store.MarketKey)
	if pEtag == "" || mEtag == "" {
		t.Fatal("expected etags from Get")
	}
	if err := conn.PutDocuments([]byte(`{"accounts":[{"id":"bbbbbbbb-0000-4000-8000-000000000000"}]}`), []byte(`{"latestQuotes":[]}`)); err != nil {
		t.Fatalf("PutDocuments: %v", err)
	}
	updated, err := r.ledger.Load(store.PortfolioKey)
	if err != nil || !bytes.Contains(updated, []byte(`bbbbbbbb-0000-4000-8000-000000000000`)) {
		t.Errorf("portfolio not updated on the server: %q %v", updated, err)
	}
	marketAfter, _ := r.market.Load(store.MarketKey)
	if !bytes.Equal(marketAfter, []byte(`{"latestQuotes":[]}`)) {
		t.Errorf("market document after pair: %q", marketAfter)
	}

	// A paired write with a stale etag must conflict, and leave the store
	// alone.
	body, _ := json.Marshal(map[string]string{
		"portfolio":     `{"accounts":[{"id":"cccccccc-0000-4000-8000-000000000000"}]}`,
		"portfolioEtag": ETag([]byte(`{"accounts":[]}`)), // the pre-pair tag
	})
	req, _ := http.NewRequest(http.MethodPut, conn.BaseURL+"/api/v1/documents", bytes.NewReader(body))
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusConflict {
		t.Errorf("stale paired write: got HTTP %d, want 409", res.StatusCode)
	}
	untouched, _ := r.ledger.Load(store.PortfolioKey)
	if !bytes.Contains(untouched, []byte(`bbbbbbbb-0000-4000-8000-000000000000`)) {
		t.Error("a conflicted paired write must leave the documents alone")
	}
}

func TestPutDocumentsRefreshesCachedETags(t *testing.T) {
	ledger := map[string][]byte{store.PortfolioKey: []byte(`{"accounts":[]}`)}
	conn, r := newRig(t, ledger, nil, "", false)
	if _, _, err := conn.Get(store.PortfolioKey); err != nil {
		t.Fatal(err)
	}
	if err := conn.PutDocuments([]byte(`{"accounts":[{"id":"dddddddd-0000-4000-8000-000000000000"}]}`), nil); err != nil {
		t.Fatalf("PutDocuments: %v", err)
	}
	// The next single-document write must be conditional against the paired
	// write's result, not against the pre-pair document.
	if err := conn.Put(store.MarketKey, []byte(`{"latestQuotes":[]}`)); err != nil {
		t.Fatalf("single Put after pair: %v", err)
	}
	// And a write racing the pair (holding the pre-pair etag) must conflict.
	staleBody, _ := json.Marshal(map[string]string{
		"market":     `{"latestRates":[]}`,
		"marketEtag": ETag(nil), // "none": the pre-pair market was absent
	})
	req, _ := http.NewRequest(http.MethodPut, conn.BaseURL+"/api/v1/documents", bytes.NewReader(staleBody))
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusConflict {
		t.Errorf("racing paired write: got HTTP %d, want 409", res.StatusCode)
	}
	_ = r
}

func TestBundleEndpoint(t *testing.T) {
	ledger := map[string][]byte{store.PortfolioKey: []byte(`{"accounts":[{"id":"eeeeeeee-0000-4000-8000-000000000000","reportingCurrency":"USD"}]}`)}
	market := map[string][]byte{store.MarketKey: []byte(`{"latestQuotes":[{"id":"q1"}]}`)}
	conn, _ := newRig(t, ledger, market, "", false)
	raw, err := conn.Bundle()
	if err != nil {
		t.Fatalf("Bundle: %v", err)
	}
	var doc struct {
		Schema    string `json:"schema"`
		Portfolio struct {
			Accounts []map[string]any `json:"accounts"`
		} `json:"portfolio"`
		Market *struct {
			LatestQuotes []map[string]any `json:"latestQuotes"`
		} `json:"market"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatalf("bundle is not JSON: %v", err)
	}
	if len(doc.Portfolio.Accounts) != 1 || doc.Market == nil || len(doc.Market.LatestQuotes) != 1 {
		t.Errorf("bundle missing documents: %s", raw)
	}
}

func TestEmptyPortfolioBundleIs404(t *testing.T) {
	conn, _ := newRig(t, nil, nil, "", false)
	if _, err := conn.Bundle(); err == nil {
		t.Fatal("Bundle on an empty server: want error")
	}
}

func TestVerifyUnchanged(t *testing.T) {
	original := []byte(`{"accounts":[]}`)
	ledger := map[string][]byte{store.PortfolioKey: original}
	conn, _ := newRig(t, ledger, nil, "", false)
	if err := conn.VerifyUnchanged(store.PortfolioKey, original); err != nil {
		t.Fatalf("unchanged: %v", err)
	}
	_ = conn.Put(store.PortfolioKey, []byte(`{"accounts":[{"id":"aaaaaaaa-0000-4000-8000-000000000000"}]}`))
	if err := conn.VerifyUnchanged(store.PortfolioKey, original); err == nil || !strings.Contains(err.Error(), "changed since") {
		t.Errorf("after a change: got %v, want a changed-since error", err)
	}
}

func TestETagFingerprint(t *testing.T) {
	a := ETag([]byte(`x`))
	b := ETag([]byte(`x`))
	c := ETag([]byte(`y`))
	if a != b || a == c || !strings.HasPrefix(a, `"sha256-`) {
		t.Errorf("ETag: %q %q %q", a, b, c)
	}
	if fmt.Sprint(ETag(nil)) != `"none"` {
		t.Error("absent document must have the none tag")
	}
}
