# Transfer lane

## Delivered

- `internal/bundle/bundle.go`: `bundle/1`, stable decimal-safe encoding, strict file decoding with JSON paths, explicit schema/format refusals, strict single-account file decoding without changing the live store reader.
- `internal/bundle/apply.go`: pure replace/merge calculation, orphan-account and GIC validation, independent/skipped empty halves, transaction deduplication, observation-over-derived merge, newer snapshots, asymmetric watermark rules.
- `internal/cli/transfer.go`: all five commands and `transferSpecs`; location-based backups; read-only loads before validation; staged file writes with rollback and transactional attached-database SQLite writes.
- `internal/bundle/bundle_test.go`: codec/apply assertions, Swift interoperability, file and SQLite refusal byte-identity checks, half-file byte preservation, nested-market backup coverage.

No protected/shared files were edited.

## Required integration change

In `internal/cli/table.go`, inside `commandSpecs()`, replace its final:

```go
return registry
```

with:

```go
return mergeLayers(registry, transferSpecs)
```

The owning lane should combine this with the other lanes' registry layers. Without this hook the five implementations cannot be dispatched. Verification used a Go build overlay, not an edit to the protected file.

No store or model API changes are needed for the scenario sections.

## Verification

- `go build -o .build/ditgo ./cmd/dit`: PASS.
- `go test ./...`: PASS (Swift interoperability runs when `/opt/homebrew/bin/dit` exists).
- `go vet ./...`: PASS.
- Registry-wired build: `.build/ditgo-transfer`, produced with `.build/overlay.json` mapping only `internal/cli/table.go` to `.build/table.go`.
- `DIT_TRANSFER_TEST_BINARY=$PWD/.build/ditgo-transfer go test ./internal/bundle -v`: PASS, including actual command refusals that leave both `.dat` files/database files byte-identical, take no backups, and exit 2.
- `.build/compare.py`: 13 differential cases PASS, comparing Swift and Go exit codes, stdout bytes and semantic exported/restored documents; includes full/scoped/half exports, replace/merge/non-TTY refusals, and file/SQLite restore. JSON dictionary ordering is excluded as permitted.
- `TestSwiftReadsGoBundle`: Go writes a high-precision decimal bundle, Swift imports it, restored ledger and market compare equal; Swift re-exports, and Go strictly decodes the same facts. PASS.

### Final scenario counts

| Invocation | Passed | Failed |
| --- | ---: | ---: |
| Required plain build (`DIT=.build/ditgo`) | 71 | 336 |
| Registry-wired Go-only build (`DIT=.build/ditgo-transfer`) | 80 | 327 |
| Transfer-only oracle wrapper (`DIT=.build/dit-transfer-oracle`) | 407 | 0 |

The transfer-only wrapper sends ONLY `store export/backup/import` and top-level `export/import` to Go. All other commands go to Swift. This isolates the transfer lane rather than claiming other commands have been ported. **All checks in sections 11 and 25 pass under this isolation**, including strict refusals, half-files, merge watermarks, automatic backups, and SQLite.

Plain acceptance remains blocked by the protected registry hook. The wired Go-only acceptance remains blocked by the other lanes' missing account/transaction/ticker/market implementations: the scenario cannot construct or inspect its fixtures using the Go-only CLI. Its 9 gains do not regress the 71 baseline checks.

## Remaining edge limitations

- The shared `model.Day` decoder normalizes dates to UTC midnight. Valid CLI-produced ledger dates/daily closes are midnight, and all scenario/interop fixtures pass. Arbitrary hand-written non-midnight date numbers are not faithfully preserved by the current shared model reader; changing that policy is outside this lane.
- Non-TTY refusal stdout and exit code match; the shared error reporter prefixes its final stderr refusal with `error:` whereas Swift's confirmation helper exits after printing an unprefixed line.
- Single-account lookup implements exact names and UUID/prefix resolution; Swift's optional did-you-mean suggestion for misspelled account names is not implemented here.

Verification logs and scratch fixtures are in ignored `.build/`; they are not deliverable source files.
