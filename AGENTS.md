# Project instructions

- `version.txt` records the version of the most recent *published* CLI build, in `major.minor.revision` form.
- Builds use `scripts/build.sh`; do not run `go build` directly for a project build. Tests do not count as builds. By default the script stamps the binary with the version currently in `version.txt` and does not touch it; pass `--inc-version` for a build that will be published (e.g. a GitHub release) to increment the revision, which is written only after the build succeeds.
