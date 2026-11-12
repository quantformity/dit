// The self-update command: download the latest release from the GitHub
// releases page, verify it runs, back up the current binary as
// dit.<old-version> beside it, and replace the running executable.
//
// The name avoids 'update', which is already the market-data refresh.
package cli

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// releaseAPIBase is the GitHub REST endpoint for the releases. It is
// overridable (and the executable, via DIT_SELF_UPDATE_EXE) so the update
// flow can be exercised in tests against a stub server.
const releaseAPIBase = "https://api.github.com/repos/quantformity/dit"

func selfUpdateCommand(c Context, args []string) error {
	if c.JSON {
		return usage("--json is not supported for 'self-update' — it prints progress text")
	}
	o, err := ParseOptions(args, map[string]bool{"version": true}, setOf("check", "yes"))
	if err != nil {
		return err
	}
	if len(o.Positionals) > 0 {
		return usage("unexpected argument '" + o.Positionals[0] + "' — usage: dit self-update [--check] [--version VERSION] [--yes]")
	}

	exe, err := executablePath()
	if err != nil {
		return Runtime("cannot locate the running dit binary: " + err.Error())
	}

	current := "0.0.0"
	if semver, ok := extractSemver(c.Version); ok {
		current = semver
	}

	if o.Has("check") {
		release, err := fetchRelease("")
		if err != nil {
			return Runtime("cannot fetch the latest release from GitHub: " + err.Error())
		}
		latest := strings.TrimPrefix(release.Tag, "v")
		c.printf("current: %s\n", current)
		c.printf("latest:  v%s (%s)\n", latest, release.Name)
		if compareVersions(latest, current) > 0 {
			c.printf("an update is available — run 'dit self-update' to install it\n")
		} else {
			c.printf("already the latest release — nothing to do\n")
		}
		return nil
	}

	// A pinned --version names a release to install regardless of the
	// ordering (how a downgrade or a pinned upgrade is requested); without
	// it the latest release is fetched and an up-to-date install is a
	// no-op.
	tag := strings.TrimPrefix(o.Value("version"), "v")
	release, err := fetchRelease(tag)
	if err != nil {
		return Runtime("cannot fetch release v" + tag + " from GitHub: " + err.Error())
	}
	latest := strings.TrimPrefix(release.Tag, "v")
	if tag == "" && compareVersions(latest, current) <= 0 {
		c.printf("current: %s — already the latest release, nothing to do\n", current)
		return nil
	}
	c.printf("current: %s\n", current)
	c.printf("installing: v%s\n", latest)

	asset, ok := pickAsset(release.Assets, runtime.GOOS, runtime.GOARCH)
	if !ok {
		return Runtime(fmt.Sprintf("the v%s release has no binary for this platform (%s/%s) — download one from %s",
			latest, runtime.GOOS, runtime.GOARCH, releaseURL(release.Tag)))
	}

	if err := transferConfirm(c, fmt.Sprintf("Replace %s with v%s? The current binary is backed up as %s first.",
		exe, latest, backupName(filepath.Base(exe), current)), o.Has("yes"), false); err != nil {
		return err
	}

	data, err := downloadAsset(asset.BrowserDownload)
	if err != nil {
		return Runtime("download failed: " + err.Error())
	}
	c.printf("downloaded v%s\n", latest)

	// Verify before replacing: the new binary must at least report its own
	// version. A corrupt or wrong-architecture download is thrown away and
	// the running binary is never touched.
	tmp, err := verifiedTempBinary(data, latest)
	if err != nil {
		return Runtime(err.Error())
	}
	defer os.RemoveAll(filepath.Dir(tmp))
	c.printf("verified v%s runs\n", latest)

	backup, err := replaceExecutable(exe, tmp, current)
	if err != nil {
		return Runtime(err.Error())
	}
	c.printf("dit v%s is now installed\n", latest)
	c.printf("previous binary backed up: %s\n", backup)
	return nil
}

// executablePath is the running binary, resolving the location the
// replacement must land on. DIT_SELF_UPDATE_EXE overrides it (tests).
func executablePath() (string, error) {
	if override := os.Getenv("DIT_SELF_UPDATE_EXE"); override != "" {
		return absolute(override), nil
	}
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(exe)
}

type releaseAsset struct {
	Name            string `json:"name"`
	BrowserDownload string `json:"browser_download_url"`
}

// releaseInfo is the subset of the GitHub releases API this command uses.
type releaseInfo struct {
	Tag    string         `json:"tag_name"`
	Name   string         `json:"name"`
	Assets []releaseAsset `json:"assets"`
}

func releaseURL(tag string) string {
	return "https://github.com/quantformity/dit/releases/tag/" + tag
}

// fetchRelease reads a release from the GitHub API: an empty tag means the
// latest release, anything else names a tag.
func fetchRelease(tag string) (releaseInfo, error) {
	base := os.Getenv("DIT_RELEASE_API")
	if base == "" {
		base = releaseAPIBase
	}
	if tag == "" {
		base += "/releases/latest"
	} else {
		base += "/releases/tags/" + tag
	}
	client := &http.Client{Timeout: 30 * time.Second}
	req, err := http.NewRequest(http.MethodGet, base, nil)
	if err != nil {
		return releaseInfo{}, err
	}
	req.Header.Set("User-Agent", "dit-self-update")
	// A private release needs credentials: the first token env var that is
	// set is used (a PAT, or whatever the gh CLI exports).
	for _, name := range []string{"GITHUB_TOKEN", "GH_TOKEN"} {
		if token := os.Getenv(name); token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
			break
		}
	}
	res, err := client.Do(req)
	if err != nil {
		return releaseInfo{}, err
	}
	defer res.Body.Close()
	data, err := readAll(res.Body, 10<<20)
	if err != nil {
		return releaseInfo{}, err
	}
	if res.StatusCode == http.StatusNotFound {
		return releaseInfo{}, fmt.Errorf("the release was not found (the repository may be private — set GITHUB_TOKEN to a personal access token with repo read access, or publish the repository)")
	}
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return releaseInfo{}, fmt.Errorf("GitHub returned HTTP %d", res.StatusCode)
	}
	var info releaseInfo
	if err := json.Unmarshal(data, &info); err != nil {
		return releaseInfo{}, fmt.Errorf("the release metadata is not valid JSON: %v", err)
	}
	if info.Tag == "" {
		return releaseInfo{}, fmt.Errorf("the release metadata has no tag")
	}
	return info, nil
}

func downloadAsset(url string) ([]byte, error) {
	client := &http.Client{Timeout: 5 * time.Minute}
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "dit-self-update")
	for _, name := range []string{"GITHUB_TOKEN", "GH_TOKEN"} {
		if token := os.Getenv(name); token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
			break
		}
	}
	res, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		return nil, fmt.Errorf("the download returned HTTP %d (for a private repository, set GITHUB_TOKEN)", res.StatusCode)
	}
	return readAll(res.Body, 64<<20)
}

func readAll(r io.Reader, max int64) ([]byte, error) {
	data, err := io.ReadAll(io.LimitReader(r, max+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > max {
		return nil, fmt.Errorf("the response is larger than %d bytes", max)
	}
	return data, nil
}

// pickAsset selects the release asset built for this platform.
func pickAsset(assets []releaseAsset, goos, goarch string) (releaseAsset, bool) {
	wanted := "dit-" + goos + "-" + goarch
	if goos == "windows" {
		wanted += ".exe"
	}
	for _, a := range assets {
		if a.Name == wanted && a.BrowserDownload != "" {
			return a, true
		}
	}
	return releaseAsset{}, false
}

// compareVersions orders two version strings: negative when a is older.
// Shorter versions are padded with zeros (1.2 < 1.2.0 < 1.3).
func compareVersions(a, b string) int {
	av, bv := parseSemver(a), parseSemver(b)
	for i := 0; i < 3; i++ {
		if av[i] < bv[i] {
			return -1
		}
		if av[i] > bv[i] {
			return 1
		}
	}
	return 0
}

func parseSemver(v string) [3]int {
	v = strings.TrimPrefix(v, "v")
	out := [3]int{}
	for i, p := range strings.SplitN(v, ".", 3) {
		if i > 2 {
			break
		}
		n, err := strconv.Atoi(strings.TrimSpace(p))
		if err != nil {
			n = 0
		}
		out[i] = n
	}
	return out
}

// extractSemver pulls the version number out of a full --version string
// like "0.0.16 (20261112.155923)": the first field that is a numeric
// major.minor.revision triple (the date stamp is not one).
func extractSemver(s string) (string, bool) {
	for _, f := range strings.Fields(s) {
		parts := strings.Split(strings.TrimPrefix(f, "v"), ".")
		if len(parts) < 3 {
			continue
		}
		digits := true
		for _, p := range parts[:3] {
			if !isAllDigits(p) {
				digits = false
				break
			}
		}
		if digits {
			return strings.Join(parts[:3], "."), true
		}
	}
	return "", false
}

func isAllDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// backupName is the file the old binary is kept as: its own name (without
// extension) plus its version — dit.0.0.16, dit.exe.0.0.16.
func backupName(base, version string) string {
	return strings.TrimSuffix(base, ".exe") + "." + version
}

// verifiedTempBinary writes the downloaded bytes to a private temp directory,
// makes them executable, and runs --version: the candidate must run and
// report the expected version before the working binary is touched.
func verifiedTempBinary(data []byte, version string) (string, error) {
	dir, err := os.MkdirTemp("", "dit-update-")
	if err != nil {
		return "", err
	}
	path := filepath.Join(dir, "dit.tmp-"+sanitizeFilename(version))
	if err := os.WriteFile(path, data, 0o755); err != nil {
		os.RemoveAll(dir)
		return "", err
	}
	out, err := exec.Command(path, "--version").CombinedOutput()
	if err != nil {
		os.RemoveAll(dir)
		return "", fmt.Errorf("the downloaded binary would not run (%v: %s) — the current binary was left in place", err, strings.TrimSpace(string(out)))
	}
	semver, ok := extractSemver(string(out))
	if !ok || compareVersions(semver, version) != 0 {
		os.RemoveAll(dir)
		return "", fmt.Errorf("the downloaded binary reports '%s', not v%s — it was not installed, and the current binary is untouched", strings.TrimSpace(string(out)), version)
	}
	return path, nil
}

// replaceExecutable swaps the new binary into the running location: the old
// binary is backed up beside it first, and the write lands atomically (temp
// file in the same directory, then rename over the target). It returns the
// backup path.
func replaceExecutable(exe, newBinary, oldVersion string) (string, error) {
	exe, err := filepath.Abs(exe)
	if err != nil {
		return "", err
	}
	if _, err := os.Stat(exe); err != nil {
		return "", fmt.Errorf("the current binary %s is no longer there: %v", exe, err)
	}

	backup := filepath.Join(filepath.Dir(exe), backupName(filepath.Base(exe), oldVersion))
	data, err := os.ReadFile(exe)
	if err != nil {
		return "", fmt.Errorf("cannot read the current binary for the backup: %v", err)
	}
	if err := os.WriteFile(backup, data, 0o755); err != nil {
		return "", fmt.Errorf("cannot write the backup %s (the current binary is still in place): %v", backup, err)
	}

	newData, err := os.ReadFile(newBinary)
	if err != nil {
		return "", fmt.Errorf("cannot read the downloaded binary: %v", err)
	}
	dir := filepath.Dir(exe)
	tmp, err := os.CreateTemp(dir, "."+filepath.Base(exe)+".new-")
	if err != nil {
		return "", fmt.Errorf("cannot write into %s (try installing dit into a directory you can write, e.g. /usr/local/bin): %v", dir, err)
	}
	tmpName := tmp.Name()
	defer os.Remove(tmpName) // a no-op after a successful rename
	if _, err := tmp.Write(newData); err != nil {
		tmp.Close()
		return "", fmt.Errorf("cannot write the new binary into %s (try a directory you can write, e.g. /usr/local/bin): %v", dir, err)
	}
	if err := tmp.Close(); err != nil {
		return "", fmt.Errorf("cannot finish writing the new binary: %v", err)
	}
	if err := os.Chmod(tmpName, 0o755); err != nil {
		return "", fmt.Errorf("cannot make the new binary executable: %v", err)
	}
	if err := os.Rename(tmpName, exe); err != nil {
		return "", fmt.Errorf("cannot replace %s (the backup %s is kept either way): %v", exe, backup, err)
	}
	return backup, nil
}

func sanitizeFilename(s string) string {
	return strings.Map(func(r rune) rune {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' || r == '_' {
			return r
		}
		return '_'
	}, s)
}
