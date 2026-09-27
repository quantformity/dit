#!/usr/bin/env bash
#
# build.sh — compile the dit CLI (release) and install it on the PATH.
#
# Usage:
#   ./scripts/build.sh               build + install to /opt/homebrew/bin
#   ./scripts/build.sh --no-install  build only
#   BIN=~/bin ./scripts/build.sh     install somewhere else
#
set -euo pipefail
cd "$(dirname "$0")/.."

install=true
for arg in "$@"; do
  case "$arg" in
    --no-install) install=false ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "unknown option: $arg (try --help)" >&2
      exit 2
      ;;
  esac
done

echo "→ swift build -c release"
swift build -c release

if [[ "$install" != true ]]; then
  echo "✔ built: $(pwd)/.build/release/dit"
  exit 0
fi

dest="${BIN:-/opt/homebrew/bin}/dit"
dir="$(dirname "$dest")"
if [[ ! -d "$dir" ]]; then
  echo "✘ install directory does not exist: $dir (set BIN=/path/to/dir to choose another)" >&2
  exit 1
fi
if [[ ! -w "$dir" ]]; then
  echo "✘ not writable: $dir (set BIN=/path/to/dir, e.g. BIN=~/bin)" >&2
  exit 1
fi

cp .build/release/dit "$dest"
echo "✔ installed: $dest"
echo "  try: $dest help"
