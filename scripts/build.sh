#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$ROOT/version.txt"
OUTPUT="$ROOT/.build/dit"
cd "$ROOT"

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
mkdir -p "$(dirname "$OUTPUT")"
tmp_binary="$(mktemp "$ROOT/.build/dit.XXXXXXXX")"
tmp_version="$ROOT/version.txt.tmp.$$"
trap 'rm -f "$tmp_binary" "$tmp_version"' EXIT

go build -trimpath \
  -ldflags "-X main.version=$next_version -X main.buildDate=$build_date" \
  -o "$tmp_binary" ./cmd/dit
mv "$tmp_binary" "$OUTPUT"
printf '%s\n' "$next_version" > "$tmp_version"
mv "$tmp_version" "$VERSION_FILE"
printf 'Built dit %s (%s) -> .build/dit\n' "$next_version" "$build_date"
