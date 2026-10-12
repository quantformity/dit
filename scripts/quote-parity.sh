#!/usr/bin/env bash
# Test the quote lane without editing parent-owned registry/dispatch files.
# A Go build overlay applies exactly the two requested shared-seam changes.
set -eu
cd "$(dirname "$0")/.."
ROOT="$PWD"
mkdir -p .build
WORK="$(mktemp -d /tmp/dit-quote-overlay.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
python3 - "$ROOT" "$WORK" <<'PY'
import json,pathlib,sys
root,work=map(pathlib.Path,sys.argv[1:])
replacements={
 'internal/cli/table.go':('return mergeLayers(registry, summarySpecs, txListSpecs, marketSpecs, transferSpecs)', 'return mergeLayers(registry, summarySpecs, txListSpecs, marketSpecs, transferSpecs, quoteSpecs)'),
 'internal/cli/dispatch.go':('name, spec := registry.Lookup(group, sub)\n\treturn name, spec, rest', 'name, spec := registry.Lookup(group, sub)\n\tif group == "quote" && rawSub != "" { rest = append([]string{rawSub}, rest...) }\n\treturn name, spec, rest')}
overlay={}
for rel,(old,new) in replacements.items():
 source=root/rel;dest=work/source.name;text=source.read_text();assert text.count(old)==1
 dest.write_text(text.replace(old,new));overlay[str(source)]=str(dest)
(work/'overlay.json').write_text(json.dumps({'Replace':overlay}))
lines=(root/'scripts/twin-run.sh').read_text().splitlines()
(work/'probes').write_text('\n'.join(line.strip()[1:-1] for line in lines if line.strip().startswith('"quote'))+'\n')
PY
PROBES=()
while IFS= read -r probe; do PROBES+=("$probe"); done < "$WORK/probes"
go build -o .build/ditgo-quote-before ./cmd/dit
printf '\nBefore shared wiring:\n'
GO="$ROOT/.build/ditgo-quote-before" scripts/twin-run.sh "${PROBES[@]}" || true
go build -overlay "$WORK/overlay.json" -o .build/ditgo-quote ./cmd/dit
printf '\nAfter overlay wiring (no source edits):\n'
GO="$ROOT/.build/ditgo-quote" scripts/twin-run.sh "${PROBES[@]}"
