#!/usr/bin/env bash
# Build the dit CLI.
#
#   scripts/build.sh                     host binary          -> .build/dit
#   scripts/build.sh linux/amd64 ...     cross-compiled       -> .build/dit-<os>-<arch>
#
# Each successful build increments the revision in version.txt once (a
# cross build of several targets counts as one build). The SQLite driver is
# pure Go (modernc.org/sqlite), so CGO is not required.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT/version.txt"
cd "$ROOT"

# Targets: explicit GOOS/GOARCH pairs, or the host platform by default.
HOST_OS="$(go env GOOS)"
HOST_ARCH="$(go env GOARCH)"
targets=()
if [[ $# -gt 0 ]]; then
  for target in "$@"; do
    targets+=("$target")
  done
else
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
next_version="$major.$minor.$((10#$revision + 1))"
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

printf '%s\n' "$next_version" > "$tmp_version"
mv "$tmp_version" "$VERSION_FILE"
for output in "${built[@]}"; do
  printf 'Built dit %s (%s) -> %s\n' "$next_version" "$build_date" "${output#"$ROOT"/}"
done
