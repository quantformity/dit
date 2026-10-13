package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"dit/internal/config"
)

func TestConfigSetUpdatesTheUserStorePaths(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	for _, key := range []string{config.BackendEnvKey, config.StoreURLEnvKey, config.MarketURLEnvKey} {
		t.Setenv(key, "")
	}
	var out, errOut bytes.Buffer
	ctx := Context{Out: &out, Err: &errOut}
	if code := Dispatch(ctx, []string{"config", "set", "store", "~/Cloud Portfolio/portfolio.dat"}); code != 0 {
		t.Fatalf("store set exit %d: %s", code, errOut.String())
	}
	if code := Dispatch(ctx, []string{"config", "set", "market", "~/Cloud Portfolio/market.dat"}); code != 0 {
		t.Fatalf("market set exit %d: %s", code, errOut.String())
	}
	layout, err := config.Resolve(nil, "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	wantRoot := filepath.Join(home, "Cloud Portfolio")
	if layout.PortfolioLocation != filepath.Join(wantRoot, "portfolio.dat") || layout.MarketLocation != filepath.Join(wantRoot, "market.dat") {
		t.Fatalf("configured locations = %q, %q", layout.PortfolioLocation, layout.MarketLocation)
	}
	configBytes, err := os.ReadFile(filepath.Join(home, ".dit", "config.json"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"DIT_STORE_URL", "DIT_MARKET_URL", "~/Cloud Portfolio"} {
		if !strings.Contains(string(configBytes), want) {
			t.Fatalf("config is missing %q: %s", want, configBytes)
		}
	}
}

func TestConfigSetRejectsUnknownKeys(t *testing.T) {
	ctx := Context{Out: &bytes.Buffer{}, Err: &bytes.Buffer{}}
	if code := Dispatch(ctx, []string{"config", "set", "bad-key", "/tmp/store"}); code != 2 {
		t.Fatalf("unknown key exit %d, want 2", code)
	}
}
