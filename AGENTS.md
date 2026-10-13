# Project instructions

- `version.txt` records the version of the most recently successful CLI build, in `major.minor.revision` form.
- For every CLI build, increment the revision (third number) by one and update `version.txt` only after the build succeeds. Use `scripts/build.sh`; do not run `go build` directly for a project build. Tests do not count as builds.
- `scripts/build.sh` embeds the version and local build datetime (`YYYYMMDD.HHMMSS`) in the binary and writes `.build/dit`.
