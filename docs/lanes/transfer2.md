# Transfer fidelity follow-up

## Baseline and result

Read `scripts/twin-run.sh` and `docs/lanes/transfer.md` first. Worked in
`/Users/chup/workspaces/dit-go` because the transfer lane checkout predates the
integrated harness. `/opt/homebrew/bin/dit` and `../dit` were read-only throughout.

- Before: **12 identical, 16 differing** (28 default probes).
- After: **24 identical, 4 differing**.
- `go build ./...`: PASS.
- `go test ./...`: PASS, including new model and CLI regression tests.
- Full `bash scripts/twin-run.sh`: still exits 1; the requested overall gate is
  **not satisfied**. Remaining failures are `summary`, `market coverage`,
  `market coverage --json`, and `market history`. All transfer and requested
  usage-error probes now pass. No network-provider implementation, summary
  calculation, or coverage behavior was changed to disguise those failures.

## Actual payload differences

The seed's GIC purchase is made without `--date`. Swift records its current
instant, not midnight. For example, Swift exported transaction 5's date as
`813280832.259397`; Go exported `813196800`. The previous lane's assumption that
CLI-produced transaction dates are always midnight was false.

`Transaction` now retains an original non-midnight date number for encoding
while keeping its normalized `Day` for calendar calculations. Changing `Date`
invalidates that retained value. This repairs full store exports, the ledger
half of bundles, and merge rewrites of the existing ledger. Merge was not
silently duplicating IDs, merging series incorrectly, or adopting a foreign
watermark in this probe: re-encoding the existing transaction corrupted its
persisted timestamp.

A second difference appeared once the ledger was fixed: market `updatedAt`
`813280896.210004` became `813280896.2100039`. Adding/subtracting the Unix epoch
lost fractional precision. `MarketData` now retains that original reference
number while `UpdatedAt` is unchanged, including across a merge clone. The
comparison still checks persisted timestamps exactly; it does not round them.

## Error behavior

- Multi-account `store import` refusal is a runtime error (exit 1), with the
  same `error:` sentence as Swift and no usage block.
- Non-interactive confirmation refusal is exit 1 with the bare sentence, no
  `error:` prefix and no usage block. The preceding confirmation question is
  unchanged.
- Dispatch supplies exact Swift help text for store, bundle transfer, and
  market usage errors when the registry has no help text. These are static Go
  strings, not calls to the oracle at runtime.
- Missing bundle creation timestamp names `the document.createdAt`.
- Invalid JSON store imports use Foundation's corresponding format-error
  sentence rather than exposing Go's JSON parser diagnostic.

## Necessary comparison correction

The existing untracked `scripts/canonical-store-diff.py` compared *all* bundle
fields, including `createdAt`. Even identical implementations cannot produce
byte-identical generation timestamps when invoked sequentially. The comparator
now excludes **only top-level `createdAt` in `bundle/1` documents**. It still
compares every persisted payload value exactly, including the transaction date
and market `updatedAt` above. JSON dictionary formatting/order was already
canonicalized by this comparator; changing formatting was not the fix.

Thus transfer stdout, exit codes, and canonical payloads match the oracle;
whole export-file bytes (dictionary order and newly generated creation time)
are not claimed identical. No timestamp was hardcoded or rounded to make a
probe pass.

## Scope and existing edits

The repository already had edits to `internal/cli/table.go` and
`scripts/twin-run.sh`, plus the untracked canonical comparator. The existing
tracked edits were preserved and excluded from this commit. The comparator is
included because the narrow generation-time correction is necessary to make
the instrument meaningful. Regression tests cover timestamp preservation,
explicit date/timestamp changes, the specified usage blocks, the exit-1
multi-account refusal, and the unprefixed confirmation refusal.
