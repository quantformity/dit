package cli

import (
	"bytes"
	"encoding/json"
	"net"
	"net/http"
	"sort"
	"strings"
	"sync"
	"testing"

	"dit/internal/config"
	"dit/internal/decimal"
	"dit/internal/model"
	"dit/internal/remote"
	"dit/internal/store"
)

// serveLocalPortfolio runs a real remote server on 127.0.0.1:0 seeded with
// the given documents and returns its "127.0.0.1:PORT" address.
func serveLocalPortfolio(t *testing.T, ledgerData, marketData map[string][]byte, immutable bool) string {
	t.Helper()
	if ledgerData == nil {
		ledgerData = map[string][]byte{}
	}
	if marketData == nil {
		marketData = map[string][]byte{}
	}
	mu := &sync.Mutex{}
	mem := func(data map[string][]byte) store.Store {
		return store.Store{
			Location: "test",
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
	handler := remote.NewServer(mem(ledgerData), mem(marketData), "", immutable, "0.0.1-test")
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	server := &http.Server{Handler: handler}
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(func() { _ = server.Close() })
	return listener.Addr().String()
}

// oneAccountPortfolio is a minimal valid ledger document.
func oneAccountPortfolio(t *testing.T) []byte {
	t.Helper()
	p := model.Portfolio{
		Accounts: []model.Account{{ID: "aaaaaaaa-0000-4000-8000-000000000000", ReportingCurrency: model.USD}},
		Transactions: []model.Transaction{{
			ID:        "bbbbbbbb-0000-4000-8000-000000000000",
			AccountID: "aaaaaaaa-0000-4000-8000-000000000000",
			Currency:  model.USD,
			Kind:      model.Kind{Type: model.KindDeposit, Amount: decimal.FromInt(5)},
		}},
	}
	raw, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func TestConnectSavesAndDisconnectClears(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	address := serveLocalPortfolio(t, map[string][]byte{store.PortfolioKey: oneAccountPortfolio(t)}, nil, false)

	var out, errOut bytes.Buffer
	ctx := Context{Out: &out, Err: &errOut}
	if err := connectCommand(ctx, []string{address}); err != nil {
		t.Fatalf("connect: %v", err)
	}
	saved, err := config.LoadRemoteConnection()
	if err != nil {
		t.Fatalf("LoadRemoteConnection: %v", err)
	}
	if saved.URL != address {
		t.Errorf("saved URL = %q, want %s (canonical host:port form)", saved.URL, address)
	}
	if !strings.Contains(out.String(), address) {
		t.Errorf("connect output did not name the address:\n%s", out.String())
	}

	if err := disconnectCommand(ctx, []string{}); err != nil {
		t.Fatalf("disconnect: %v", err)
	}
	saved, err = config.LoadRemoteConnection()
	if err != nil {
		t.Fatal(err)
	}
	if saved.URL != "" || saved.Token != "" {
		t.Errorf("after disconnect, saved = %+v, want empty", saved)
	}
	if !strings.Contains(out.String(), "Disconnected from "+address) {
		t.Errorf("disconnect output:\n%s", out.String())
	}
}

func TestConnectWithoutTargetFailsCleanly(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	ctx := Context{Out: &bytes.Buffer{}, Err: &bytes.Buffer{}}
	err := connectCommand(ctx, []string{})
	if err == nil || !strings.Contains(err.Error(), "no target") {
		t.Errorf("connect with no target: got %v, want a usage error naming the usage", err)
	}
}

func TestDisconnectWhenNotConnectedFailsCleanly(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	ctx := Context{Out: &bytes.Buffer{}, Err: &bytes.Buffer{}}
	err := disconnectCommand(ctx, []string{})
	if err == nil || !strings.Contains(err.Error(), "not connected") {
		t.Errorf("disconnect without a connection: got %v, want 'not connected'", err)
	}
}

// A connected context must open the REMOTE documents through the ordinary
// store interface, so every read command runs against the other machine.
func TestStoresRouteToRemote(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	ledgerRaw := oneAccountPortfolio(t)
	marketRaw := []byte(`{"latestQuotes":[{"id":"q1"}]}`)
	address := serveLocalPortfolio(t,
		map[string][]byte{store.PortfolioKey: ledgerRaw},
		map[string][]byte{store.MarketKey: marketRaw}, false)

	ctx := Context{
		Layout: config.Layout{RemoteTarget: address, Backend: config.File},
		Out:    &bytes.Buffer{}, Err: &bytes.Buffer{},
	}
	ledger, market, err := ctx.Stores()
	if err != nil {
		t.Fatalf("Stores: %v", err)
	}
	got, err := ledger.Load(store.PortfolioKey)
	if err != nil {
		t.Fatalf("Load portfolio: %v", err)
	}
	if !bytes.Equal(got, ledgerRaw) {
		t.Errorf("portfolio document = %q, want the remote's bytes", got)
	}
	gotMarket, err := market.Load(store.MarketKey)
	if err != nil {
		t.Fatalf("Load market: %v", err)
	}
	if !bytes.Equal(gotMarket, marketRaw) {
		t.Errorf("market document = %q, want the remote's bytes", gotMarket)
	}
}

// A write through the transfer helpers must land on the REMOTE server, and a
// stale document must be refused like a local changed-under-you guard.
func TestTransferSaveRoutesToRemote(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	original := oneAccountPortfolio(t)
	address := serveLocalPortfolio(t, map[string][]byte{store.PortfolioKey: original}, nil, false)

	ctx := Context{
		Layout: config.Layout{RemoteTarget: address, Backend: config.File},
		Out:    &bytes.Buffer{}, Err: &bytes.Buffer{},
	}
	// Read first, as every write command does: that is what arms the ETag.
	if _, err := transferRead(ctx, "", store.PortfolioKey); err != nil {
		t.Fatalf("transferRead: %v", err)
	}
	next := &model.Portfolio{}
	if err := json.Unmarshal(original, next); err != nil {
		t.Fatal(err)
	}
	next.Tickers = append(next.Tickers, model.EquityTicker{Symbol: "TEST", Currency: model.USD})
	if err := transferSave(ctx, next, nil); err != nil {
		t.Fatalf("transferSave: %v", err)
	}
	// Verify server-side with a fresh connection (no client cache).
	fresh, err := remote.NewConnection(address, "", false)
	if err != nil {
		t.Fatal(err)
	}
	raw, _, err := fresh.Get(store.PortfolioKey)
	if err != nil {
		t.Fatalf("fresh Get: %v", err)
	}
	var stored model.Portfolio
	if err := json.Unmarshal(raw, &stored); err != nil {
		t.Fatal(err)
	}
	if len(stored.Tickers) != 1 || stored.Tickers[0].Symbol != "TEST" {
		t.Errorf("server-side portfolio after remote save: %+v", stored.Tickers)
	}
}

func TestChangedUnderYouCatchesRemoteDrift(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	original := oneAccountPortfolio(t)
	address := serveLocalPortfolio(t, map[string][]byte{store.PortfolioKey: original}, nil, false)

	ctx := Context{
		Layout: config.Layout{RemoteTarget: address, Backend: config.File},
		Out:    &bytes.Buffer{}, Err: &bytes.Buffer{},
	}
	if err := changedUnderYou(ctx, original, "", store.PortfolioKey, "portfolio"); err != nil {
		t.Fatalf("unchanged remote document: %v", err)
	}
	// Another client commits while we are "confirming".
	driven := &model.Portfolio{}
	if err := json.Unmarshal(original, driven); err != nil {
		t.Fatal(err)
	}
	driven.Tickers = append(driven.Tickers, model.EquityTicker{Symbol: "LATE", Currency: model.USD})
	if err := transferSave(ctx, driven, nil); err != nil {
		t.Fatal(err)
	}
	if err := changedUnderYou(ctx, original, "", store.PortfolioKey, "portfolio"); err == nil || !strings.Contains(err.Error(), "changed") {
		t.Errorf("after remote drift: got %v, want a changed-since error", err)
	}
}

// Clone pulls a remote portfolio into the LOCAL stores, even when a
// (different) connection is saved: clone is a data move, not a pointer.
func TestCloneEndToEnd(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	ledgerRaw := oneAccountPortfolio(t)
	address := serveLocalPortfolio(t, map[string][]byte{store.PortfolioKey: ledgerRaw}, nil, false)

	clientDir := t.TempDir()
	var out, errOut bytes.Buffer
	ctx := Context{
		Layout: config.Layout{Backend: config.File, PortfolioDir: clientDir, MarketDir: clientDir},
		Out:    &out, Err: &errOut,
	}
	if err := cloneCommand(ctx, []string{address, "--yes", "--force"}); err != nil {
		t.Fatalf("clone: %v\nout: %s\nerr: %s", err, out.String(), errOut.String())
	}
	ledger, err := store.NewFileStore(clientDir)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := ledger.Load(store.PortfolioKey)
	if err != nil {
		t.Fatalf("client store Load: %v", err)
	}
	var got model.Portfolio
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("client store document: %v", err)
	}
	if len(got.Accounts) != 1 || len(got.Transactions) != 1 {
		t.Errorf("cloned portfolio = %d account(s), %d transaction(s); want 1 of each", len(got.Accounts), len(got.Transactions))
	}
	if !strings.Contains(out.String(), "Cloned") {
		t.Errorf("clone output:\n%s", out.String())
	}
}

// A clone must write the local stores even when a saved connection points at
// a dead server: the clone target is named on the command line.
func TestCloneIgnoresSavedConnection(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	ledgerRaw := oneAccountPortfolio(t)
	address := serveLocalPortfolio(t, map[string][]byte{store.PortfolioKey: ledgerRaw}, nil, false)

	clientDir := t.TempDir()
	var out, errOut bytes.Buffer
	ctx := Context{
		Layout: config.Layout{
			Backend: config.File, PortfolioDir: clientDir, MarketDir: clientDir,
			RemoteTarget: "http://127.0.0.1:1", // a bogus saved connection
		},
		Out: &out, Err: &errOut,
	}
	if err := cloneCommand(ctx, []string{address, "--yes", "--force"}); err != nil {
		t.Fatalf("clone with a bogus saved connection: %v", err)
	}
	raw, err := store.NewFileStore(clientDir)
	if err != nil {
		t.Fatal(err)
	}
	ledger, err := raw.Load(store.PortfolioKey)
	if err != nil {
		t.Fatal(err)
	}
	var got model.Portfolio
	if err := json.Unmarshal(ledger, &got); err != nil || len(got.Accounts) != 1 {
		t.Errorf("clone did not write the local stores: %d account(s)", len(got.Accounts))
	}
}

func TestCloneWithoutTargetOrConnectionFailsCleanly(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	ctx := Context{
		Layout: config.Layout{Backend: config.File, PortfolioDir: t.TempDir(), MarketDir: t.TempDir()},
		Out:    &bytes.Buffer{}, Err: &bytes.Buffer{},
	}
	err := cloneCommand(ctx, []string{"--yes"})
	if err == nil || !strings.Contains(err.Error(), "no remote to clone") {
		t.Errorf("clone with no target: got %v, want 'no remote to clone'", err)
	}
}

func TestRemoteBannerNamesTheAddress(t *testing.T) {
	var out bytes.Buffer
	ctx := Context{
		Layout: config.Layout{RemoteTarget: "10.0.0.5:8348"},
		Out:    &out, Err: &out,
	}
	ctx.printRemoteBanner()
	line := out.String()
	if !strings.Contains(line, "REMOTE") || !strings.Contains(line, "10.0.0.5:8348") {
		t.Errorf("banner = %q, want REMOTE + address", line)
	}
	if !strings.Contains(line, "mutable") {
		t.Errorf("banner = %q, want the mutation mode", line)
	}

	// No saved connection: no banner at all.
	var quiet bytes.Buffer
	local := Context{Layout: config.Layout{Backend: config.File}, Out: &quiet, Err: &quiet}
	local.printRemoteBanner()
	if quiet.Len() != 0 {
		t.Errorf("banner printed without a connection: %q", quiet.String())
	}
}

func TestStoreLocationLabel(t *testing.T) {
	remoteCtx := Context{Layout: config.Layout{RemoteTarget: "http://10.0.0.5:8348"}, Out: &bytes.Buffer{}, Err: &bytes.Buffer{}}
	if got := remoteCtx.storeLocationLabel(store.PortfolioKey); got != "remote://10.0.0.5:8348/portfolio" {
		t.Errorf("remote portfolio label = %q", got)
	}
	if got := remoteCtx.storeLocationLabel(store.MarketKey); got != "remote://10.0.0.5:8348/market" {
		t.Errorf("remote market label = %q", got)
	}
	localCtx := Context{Layout: config.Layout{Backend: config.File, PortfolioDir: "/tmp/x", MarketDir: "/tmp/y"}, Out: &bytes.Buffer{}, Err: &bytes.Buffer{}}
	if got := localCtx.storeLocationLabel(store.PortfolioKey); !strings.HasSuffix(got, "/tmp/x") {
		t.Errorf("local portfolio label = %q", got)
	}
	if got := localCtx.storeLocationLabel(store.MarketKey); !strings.HasSuffix(got, "/tmp/y") {
		t.Errorf("local market label = %q", got)
	}
}

func TestRemoteBannerExcludedCommands(t *testing.T) {
	excluded := []string{"serve", "connect", "disconnect", "clone", "config", "config set"}
	for _, name := range excluded {
		if !remoteBannerExcluded(name) {
			t.Errorf("remoteBannerExcluded(%q) = false, want true", name)
		}
	}
	for _, name := range []string{"summary", "tx", "account", "pnl", "backup", "rollback", "store"} {
		if remoteBannerExcluded(name) {
			t.Errorf("remoteBannerExcluded(%q) = true, want false", name)
		}
	}
}

// A read-only connection (server running --immutable) refuses writes through
// the ordinary store interface, and the error says why.
func TestReadOnlyRemoteRefusesWrites(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	address := serveLocalPortfolio(t, map[string][]byte{store.PortfolioKey: oneAccountPortfolio(t)}, nil, true)

	ctx := Context{
		Layout: config.Layout{RemoteTarget: address, RemoteReadOnly: true, Backend: config.File},
		Out:    &bytes.Buffer{}, Err: &bytes.Buffer{},
	}
	ledger, _, err := ctx.Stores()
	if err != nil {
		t.Fatal(err)
	}
	err = ledger.Save(store.PortfolioKey, oneAccountPortfolio(t))
	if err == nil || !strings.Contains(err.Error(), "read-only") {
		t.Errorf("Save on a read-only connection: got %v, want a read-only refusal", err)
	}
}
