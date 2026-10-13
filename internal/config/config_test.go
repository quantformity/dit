package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func clearStoreEnvironment(t *testing.T) {
	t.Helper()
	for _, key := range []string{BackendEnvKey, StoreURLEnvKey, MarketURLEnvKey} {
		t.Setenv(key, "")
	}
}

func TestDefaultConfigCreatesSiblingPortfolioAndMarketDocuments(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	clearStoreEnvironment(t)

	layout, err := Resolve(nil, "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	wantRoot := filepath.Join(home, ".dit")
	if layout.PortfolioLocation != filepath.Join(wantRoot, "portfolio.dat") || layout.MarketLocation != filepath.Join(wantRoot, "market.dat") {
		t.Fatalf("locations = %q, %q", layout.PortfolioLocation, layout.MarketLocation)
	}
	if layout.PortfolioDir != wantRoot || layout.MarketDir != wantRoot {
		t.Fatalf("file-store roots = %q, %q; want %q", layout.PortfolioDir, layout.MarketDir, wantRoot)
	}
	data, err := os.ReadFile(filepath.Join(wantRoot, configFileName))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), `"DIT_STORE_URL": "~/.dit/portfolio.dat"`) || !strings.Contains(string(data), `"DIT_MARKET_URL": "~/.dit/market.dat"`) {
		t.Fatalf("config does not retain the default store URLs: %s", data)
	}
}

func TestConfigPrecedenceAndDirectDocumentPaths(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	clearStoreEnvironment(t)
	configDir := filepath.Join(home, ".dit")
	if err := os.MkdirAll(configDir, 0o700); err != nil {
		t.Fatal(err)
	}
	configPath := filepath.Join(configDir, configFileName)
	if err := os.WriteFile(configPath, []byte(`{"DIT_STORE_URL":"~/Cloud/portfolio.dat","DIT_MARKET_URL":"~/Cloud/market.dat"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	layout, err := Resolve(nil, "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	wantRoot := filepath.Join(home, "Cloud")
	if layout.PortfolioLocation != filepath.Join(wantRoot, "portfolio.dat") || layout.MarketLocation != filepath.Join(wantRoot, "market.dat") || layout.PortfolioDir != wantRoot || layout.MarketDir != wantRoot {
		t.Fatalf("config paths resolved unexpectedly: %+v", layout)
	}

	t.Setenv(StoreURLEnvKey, filepath.Join(home, "Env", "portfolio.dat"))
	t.Setenv(MarketURLEnvKey, filepath.Join(home, "Env", "market.dat"))
	layout, err = Resolve(nil, "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	if layout.PortfolioDir != filepath.Join(home, "Env") || layout.MarketDir != filepath.Join(home, "Env") {
		t.Fatalf("environment did not override config: %+v", layout)
	}
	layout, err = Resolve(nil, "", filepath.Join(home, "Flag", "portfolio.dat"), filepath.Join(home, "Flag", "market.dat"))
	if err != nil {
		t.Fatal(err)
	}
	if layout.PortfolioDir != filepath.Join(home, "Flag") || layout.MarketDir != filepath.Join(home, "Flag") {
		t.Fatalf("flags did not override environment/config: %+v", layout)
	}
}

func TestDefaultConfigMigratesLegacyDocumentsWithoutRemovingThem(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	clearStoreEnvironment(t)
	legacy := filepath.Join(home, "Library", "Application Support", defaultStoreName)
	legacyMarket := filepath.Join(legacy, "market")
	if err := os.MkdirAll(legacyMarket, 0o755); err != nil {
		t.Fatal(err)
	}
	for path, contents := range map[string]string{
		filepath.Join(legacy, "portfolio.dat"):    `{"accounts":[]}`,
		filepath.Join(legacyMarket, "market.dat"): `{"series":{}}`,
	} {
		if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	layout, err := Resolve(nil, "", "", "")
	if err != nil {
		t.Fatal(err)
	}
	for destination, original := range map[string]string{
		filepath.Join(home, ".dit", "portfolio.dat"): filepath.Join(legacy, "portfolio.dat"),
		filepath.Join(home, ".dit", "market.dat"):    filepath.Join(legacyMarket, "market.dat"),
	} {
		got, err := os.ReadFile(destination)
		if err != nil {
			t.Fatal(err)
		}
		want, err := os.ReadFile(original)
		if err != nil {
			t.Fatal(err)
		}
		if string(got) != string(want) {
			t.Fatalf("migrated file %s differs from original", destination)
		}
	}
	if layout.PortfolioDir != filepath.Join(home, ".dit") {
		t.Fatalf("unexpected migrated portfolio root: %+v", layout)
	}
	if _, err := os.Stat(filepath.Join(legacy, "portfolio.dat")); err != nil {
		t.Fatalf("legacy portfolio was not preserved: %v", err)
	}
}
