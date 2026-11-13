package remote_test

// End-to-end tests for the run endpoint (POST /api/v1/run): a real server
// with real file stores serving the fixtures, the real in-process runner from
// internal/cli, and an HTTP client on the other side. This is the path the
// iPhone client walks.

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"dit/internal/cli"
	"dit/internal/config"
	"dit/internal/remote"
	"dit/internal/store"
)

// fixtureDir copies the market fixtures into a writable temp directory.
func runFixtureDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for _, name := range []string{"portfolio.dat", "market.dat"} {
		data, err := os.ReadFile(filepath.Join("..", "..", "testdata", "market", name))
		if err != nil {
			t.Fatalf("reading fixture %s: %v", name, err)
		}
		if err := os.WriteFile(filepath.Join(dir, name), data, 0644); err != nil {
			t.Fatalf("writing fixture %s: %v", name, err)
		}
	}
	return dir
}

func runLayout(dir string) config.Layout {
	return config.Layout{
		Backend:           config.File,
		PortfolioLocation: dir,
		MarketLocation:    dir,
		PortfolioDir:      dir,
		MarketDir:         dir,
	}
}

func newRunServer(t *testing.T, immutable bool) *httptest.Server {
	t.Helper()
	dir := runFixtureDir(t)
	ledger, err := store.NewFileStore(dir)
	if err != nil {
		t.Fatalf("ledger store: %v", err)
	}
	market, err := store.NewFileStore(dir)
	if err != nil {
		t.Fatalf("market store: %v", err)
	}
	srv := remote.NewServer(ledger, market, "tok", immutable, "test")
	srv.SetRunner(cli.NewServeRunner(ledger, market, runLayout(dir), immutable, "test"))
	ts := httptest.NewServer(srv)
	t.Cleanup(ts.Close)
	return ts
}

func postRun(t *testing.T, ts *httptest.Server, token string, args ...string) (int, string) {
	t.Helper()
	body, _ := json.Marshal(map[string]any{"args": args})
	req, err := http.NewRequest(http.MethodPost, ts.URL+"/api/v1/run", bytes.NewReader(body))
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	req.Header.Set("Content-Type", "application/json")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST run: %v", err)
	}
	defer res.Body.Close()
	var buf [1 << 20]byte
	var out []byte
	for {
		n, err := res.Body.Read(buf[:])
		if n > 0 {
			out = append(out, buf[:n]...)
		}
		if err != nil {
			break
		}
	}
	return res.StatusCode, string(out)
}

func bodyReader(b []byte) *bytes.Reader {
	return bytes.NewReader(b)
}

type envelope struct {
	OK     bool            `json:"ok"`
	Kind   string          `json:"kind"`
	Error  string          `json:"error"`
	Schema string          `json:"schema"`
	Data   json.RawMessage `json:"data"`
}

func TestRunInfoAdvertisesRun(t *testing.T) {
	ts := newRunServer(t, false)
	req, _ := http.NewRequest(http.MethodGet, ts.URL+"/api/v1/info", nil)
	req.Header.Set("Authorization", "Bearer tok")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("info: %v", err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", res.StatusCode)
	}
	var info remote.Info
	if err := json.NewDecoder(res.Body).Decode(&info); err != nil {
		t.Fatalf("decode info: %v", err)
	}
	if !info.Run {
		t.Errorf("info.run = false, want true (the runner is installed)")
	}
}

func TestRunSummaryOffline(t *testing.T) {
	ts := newRunServer(t, false)
	status, body := postRun(t, ts, "tok", "summary", "--offline")
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", status, body)
	}
	var env envelope
	if err := json.Unmarshal([]byte(body), &env); err != nil {
		t.Fatalf("envelope is not JSON: %v: %s", err, body[:min(len(body), 200)])
	}
	if !env.OK {
		t.Fatalf("envelope not ok: %s", body[:min(len(body), 300)])
	}
	if env.Schema != "summary/1" {
		t.Errorf("schema = %q, want summary/1", env.Schema)
	}
	var data struct {
		Holdings []map[string]any `json:"holdings"`
		Totals   map[string]any   `json:"totals"`
		Offline  *bool            `json:"offline"`
	}
	if err := json.Unmarshal(env.Data, &data); err != nil {
		t.Fatalf("data: %v", err)
	}
	if len(data.Holdings) == 0 {
		t.Errorf("no holdings in the fixture summary: %s", env.Data)
	}
	if data.Offline == nil || !*data.Offline {
		t.Errorf("offline flag not true in the document")
	}
}

func TestRunAccountShow(t *testing.T) {
	ts := newRunServer(t, false)
	status, body := postRun(t, ts, "tok", "account", "show", "Oracle USD", "--history")
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200: %s", status, body)
	}
	var env envelope
	if err := json.Unmarshal([]byte(body), &env); err != nil {
		t.Fatalf("envelope: %v", err)
	}
	if !env.OK || env.Schema != "account/1" {
		t.Fatalf("envelope = ok:%v schema:%s: %.300s", env.OK, env.Schema, body)
	}
}

func TestRunRefusesLedgerWrite(t *testing.T) {
	ts := newRunServer(t, false)
	status, body := postRun(t, ts, "tok", "tx", "deposit", "--account", "Oracle USD", "--amount", "100", "--date", "2026-01-02")
	if status != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400 (ledger writes are not on the endpoint): %s", status, body)
	}
	var env envelope
	if err := json.Unmarshal([]byte(body), &env); err != nil {
		t.Fatalf("refusal is not JSON: %s", body)
	}
	if env.OK {
		t.Errorf("refusal envelope says ok:true")
	}
	if env.Kind != "usage" {
		t.Errorf("kind = %q, want usage", env.Kind)
	}
}

func TestRunRefusesMarketWriteWhenImmutable(t *testing.T) {
	ts := newRunServer(t, true)
	status, body := postRun(t, ts, "tok", "update")
	if status != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400 (immutable refuses market writes): %s", status, body)
	}
	var env envelope
	if err := json.Unmarshal([]byte(body), &env); err != nil {
		t.Fatalf("refusal: %v", err)
	}
	if env.Kind != "runtime" {
		t.Errorf("kind = %q, want runtime", env.Kind)
	}
}

func TestRunRequiresToken(t *testing.T) {
	ts := newRunServer(t, false)
	status, body := postRun(t, ts, "", "summary")
	if status != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401: %s", status, body)
	}
}

func TestRunMalformedBody(t *testing.T) {
	ts := newRunServer(t, false)
	req, _ := http.NewRequest(http.MethodPost, ts.URL+"/api/v1/run", bodyReader([]byte("not json")))
	req.Header.Set("Authorization", "Bearer tok")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", res.StatusCode)
	}
}
