#!/usr/bin/env bash
# Build the dit CLI.
#
#   scripts/build.sh                      host binary, keeps the current version
#   scripts/build.sh linux/amd64 ...      cross-compiled binaries
#   scripts/build.sh --inc-version [TARGETS]
#                                         also increment the revision in version.txt
#
# The version in version.txt is left untouched by default: dev and
# cross builds stamp the version as-is. Pass --inc-version for a build
# that is being published (e.g. a GitHub release); the revision is
# incremented once, and only after all targets build successfully.
#
# Targets are GOOS/GOARCH pairs (default: the host platform); non-host
# binaries go to .build/dit-<os>-<arch>. The SQLite driver is pure Go
# (modernc.org/sqlite), so CGO is not required.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT/version.txt"
cd "$ROOT"

inc_version=false
targets=()
for arg in "$@"; do
  case "$arg" in
    --inc-version) inc_version=true ;;
    *) targets+=("$arg") ;;
  esac
done

# Targets: explicit GOOS/GOARCH pairs, or the host platform by default.
HOST_OS="$(go env GOOS)"
HOST_ARCH="$(go env GOARCH)"
if [[ ${#targets[@]} -eq 0 ]]; then
  targets+=("$HOST_OS/$HOST_ARCH")
fi

current="$(tr -d '\r\n' < "$VERSION_FILE")"
if [[ ! "$current" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "invalid version in version.txt: $current (expected major.minor.revision)" >&2
  exit 1
fi
major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
revision="${BASH_REMATCH[3]}"
if $inc_version; then
  next_version="$major.$minor.$((10#$revision + 1))"
else
  next_version="$current"
fi
build_date="$(date +%Y%m%d.%H%M%S)"
mkdir -p "$ROOT/.build"
# Set before the loop so the trap is valid; reassigned per target.
tmp_binary=""
tmp_version="$ROOT/version.txt.tmp.$$"
trap 'rm -f "$tmp_binary" "$tmp_version"' EXIT

built=()
for target in "${targets[@]}"; do
  os="${target%/*}"
  arch="${target#*/}"
  [[ "$os" == "$target" || "$arch" == "$target" ]] && {
    echo "invalid target '$target' (expected GOOS/GOARCH, e.g. linux/amd64)" >&2
    exit 1
  }
  output="$ROOT/.build/dit"
  [[ "$os/$arch" != "$HOST_OS/$HOST_ARCH" ]] && output="$ROOT/.build/dit-$os-$arch"
  tmp_binary="$(mktemp "$ROOT/.build/.dit.XXXXXXXX")"
  if ! GOOS="$os" GOARCH="$arch" CGO_ENABLED=0 go build -trimpath \
    -ldflags "-X main.version=$next_version -X main.buildDate=$build_date" \
    -o "$tmp_binary" ./cmd/dit; then
    rm -f "$tmp_binary"
    echo "build failed for $target — nothing was published, version unchanged" >&2
    exit 1
  fi
  mv "$tmp_binary" "$output"
  built+=("$output")
done

if $inc_version; then
  printf '%s\n' "$next_version" > "$tmp_version"
  mv "$tmp_version" "$VERSION_FILE"
fi
for output in "${built[@]}"; do
  printf 'Built dit %s (%s) -> %s\n' "$next_version" "$build_date" "${output#"$ROOT"/}"
done
