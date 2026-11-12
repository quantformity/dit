package cli

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestCompareVersions(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"0.0.9", "0.0.16", -1},
		{"0.0.16", "0.0.16", 0},
		{"0.0.16", "0.0.9", 1},
		{"1.2", "1.2.0", 0},
		{"1.2", "1.10", -1},
		{"v1.2.3", "1.2.3", 0},
		{"2.0.0", "1.9.9", 1},
	}
	for _, tc := range cases {
		if got := compareVersions(tc.a, tc.b); got != tc.want {
			t.Errorf("compareVersions(%q, %q) = %d, want %d", tc.a, tc.b, got, tc.want)
		}
	}
}

func TestExtractSemver(t *testing.T) {
	if got, ok := extractSemver("0.0.16 (20261112.155923)"); !ok || got != "0.0.16" {
		t.Errorf("extractSemver full form = %q, %v; want 0.0.16", got, ok)
	}
	if got, ok := extractSemver("dit 1.2.3"); !ok || got != "1.2.3" {
		t.Errorf("extractSemver = %q, %v; want 1.2.3", got, ok)
	}
	if got, ok := extractSemver("not-a-version"); ok {
		t.Errorf("extractSemver(non-semver) = %q, %v; want not found", got, ok)
	}
}

func TestPickAsset(t *testing.T) {
	assets := []releaseAsset{
		{Name: "dit-darwin-arm64", BrowserDownload: "http://x/dit-darwin-arm64"},
		{Name: "dit-linux-amd64", BrowserDownload: "http://x/dit-linux-amd64"},
		{Name: "dit-windows-amd64.exe", BrowserDownload: "http://x/dit-windows-amd64.exe"},
		{Name: "dit.sha256", BrowserDownload: "http://x/dit.sha256"},
	}
	if a, ok := pickAsset(assets, "darwin", "arm64"); !ok || a.BrowserDownload != "http://x/dit-darwin-arm64" {
		t.Errorf("darwin/arm64 pick = %+v, %v", a, ok)
	}
	if a, ok := pickAsset(assets, "windows", "amd64"); !ok || a.Name != "dit-windows-amd64.exe" {
		t.Errorf("windows/amd64 pick = %+v, %v", a, ok)
	}
	if _, ok := pickAsset(assets, "linux", "386"); ok {
		t.Error("linux/386 matched an asset, want none")
	}
}

func TestBackupName(t *testing.T) {
	if got := backupName("dit", "0.0.16"); got != "dit.0.0.16" {
		t.Errorf("backupName(dit) = %q", got)
	}
	if got := backupName("dit.exe", "0.0.16"); got != "dit.0.0.16" {
		t.Errorf("backupName(dit.exe) = %q", got)
	}
}

// Full upgrade flow against a stub release server: the fake "current"
// binary is replaced, the previous bytes are backed up as dit.<old version>,
// and an up-to-date run is a no-op.
func TestUpgradeEndToEnd(t *testing.T) {
	dir := t.TempDir()
	exe := filepath.Join(dir, "dit")
	oldContent := []byte("#!/bin/sh\necho OLD\n")
	if err := os.WriteFile(exe, oldContent, 0o755); err != nil {
		t.Fatal(err)
	}
	newContent := []byte("#!/bin/sh\n[ \"$1\" = \"--version\" ] && echo \"dit 0.0.17 (20261112.000000)\" || echo NEW\n")

	var assetURL string
	mux := http.NewServeMux()
	mux.HandleFunc("/releases/latest", func(w http.ResponseWriter, r *http.Request) {
		asset := "dit-" + runtime.GOOS + "-" + runtime.GOARCH
		fmt.Fprintf(w, `{"tag_name":"v0.0.17","name":"dit 0.0.17","assets":[{"name":%q,"browser_download_url":%q}]}`, asset, assetURL)
	})
	mux.HandleFunc("/download/", func(w http.ResponseWriter, r *http.Request) {
		w.Write(newContent)
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	assetURL = srv.URL + "/download/dit-" + runtime.GOOS + "-" + runtime.GOARCH
	t.Setenv("DIT_RELEASE_API", srv.URL)
	t.Setenv("DIT_UPGRADE_EXE", exe)

	var out bytes.Buffer
	ctx := Context{Out: &out, Err: &bytes.Buffer{}, Version: "0.0.1"}

	if err := upgradeCommand(ctx, []string{"--yes"}); err != nil {
		t.Fatalf("upgrade: %v\n%s", err, out.String())
	}
	// The current binary is now the new one.
	if data, _ := os.ReadFile(exe); !bytes.Equal(data, newContent) {
		t.Errorf("exe not replaced:\n%s", string(data))
	}
	// The old bytes are backed up beside it as dit.<old version>.
	backup := filepath.Join(dir, "dit.0.0.1")
	if data, err := os.ReadFile(backup); err != nil || !bytes.Equal(data, oldContent) {
		t.Errorf("backup %s missing or wrong: %v\n%s", backup, err, string(data))
	}
	if !strings.Contains(out.String(), "dit.0.0.1") {
		t.Errorf("output did not name the backup:\n%s", out.String())
	}

	// Re-running with the current version matching the latest is a no-op.
	out.Reset()
	ctx.Version = "0.0.17 (20261112.000000)"
	if err := upgradeCommand(ctx, []string{"--yes"}); err != nil {
		t.Fatalf("second upgrade: %v", err)
	}
	if !strings.Contains(out.String(), "already the latest") {
		t.Errorf("up-to-date run should be a no-op:\n%s", out.String())
	}

	// --check reports an available update and changes nothing.
	out.Reset()
	ctx.Version = "0.0.1"
	if err := upgradeCommand(ctx, []string{"--check"}); err != nil {
		t.Fatalf("--check: %v", err)
	}
	if !strings.Contains(out.String(), "an update is available") {
		t.Errorf("--check output:\n%s", out.String())
	}
	if data, _ := os.ReadFile(exe); !bytes.Equal(data, newContent) {
		t.Error("--check modified the binary")
	}
}
