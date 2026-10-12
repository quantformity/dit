# Ledger lane

## Delivered

- `internal/ledger/statement.go`: pure replay, per-account/per-currency snapshots, stable date ordering and merging, plain-list filtering, exact transaction summaries.
- `internal/cli/txlist.go`: statement/plain `tx list`, alias `tx ls`, `tx show`, account and transaction reference resolution, `txListSpecs` with declared options. No saves.
- `internal/ledger/statement_test.go`: all cash kinds and fees, FX legs, zero/negative snapshots, stable ordering, account isolation, filters, input immutability, Swift fixture details.
- `testdata/ledger/`: Swift-written portfolio, statement and nine show golden files, executable `verify.sh`.

All money uses internal/decimal; incoming impacts reuse Transaction.CashImpact. Foundation display money rounds ties-to-even, so a small local formatting adapter corrects exact half-cent ties before internal/text formatting. Label padding and terminal-only header styling adapt the existing cli.Table API without modifying shared files.

## Verification

- `go build -o .build/ditgo ./cmd/dit`: passes.
- `go test ./...`: passes.
- Required acceptance with the **actual unwired Go binary**: **71 passed / 336 failed** (baseline unchanged).
- Go build overlay that changes only the command registry return to `mergeLayers(registry, txListSpecs)`: builds. This overlay changes no checked-in shared file.
- `bash testdata/ledger/verify.sh "$PWD/.build/ditgo-wired"`: every byte comparison passes. Includes multi-account and single-account statements, compact single-currency, all nine show details, aliases and each filter, zero matches and store nonmutation.
- Additional Swift/Go differential test for more than four currencies (joined Balance after fallback): passes.
- Full scenario with **only list/ls/show routed to the wired Go binary**, and all other commands routed to Swift for seeding/other-lane functionality: **407 passed / 0 failed**, including all section 18 assertions and all list/show assertions elsewhere. This is a reference-seeded lane verification, **not** a claim that the standalone Go acceptance gate passes.

The local build overlays and scratch outputs live in ignored `.build/` and are not deliverables.

## Required parent wiring / unresolved shared concerns

1. `internal/cli/table.go`: merge `txListSpecs` into `commandSpecs()` after placeholder definitions (`return mergeLayers(registry, txListSpecs, ...other lane registries...)`). Without this, Dispatch calls placeholder specs and neither command can run; consequently there can be no standalone e2e gains in this isolated worktree.
2. Other lanes must supply transaction entry/mutation, account creation, and other commands so the standalone scenario can seed and progress. These are not implemented or touched here.
3. `internal/cli/dispatch.go` / routing: Swift supports a bare 8+ hex token as `dit tx <prefix>` and defaults a bare `dit tx` to list. The current SplitCommandWords consumes the token as a subcommand and discards it from rest. Before registry lookup, route an 8+ all-hex tx subcommand to `tx show` with `sub` prepended to rest; route an empty tx subcommand to `tx list`. Registering list/show alone cannot fix this. `tx show <prefix>` works, including eight-character prefixes, dashed/undashed UUIDs, case-insensitivity, exact-ID precedence, and ambiguity. As the actual TransactionRef.swift specifies, explicit show accepts unique hex prefixes of **at least four** characters; the eight-character rule applies to the shortcut router.
4. `internal/model/dates.go` / `transaction.go`: transaction decoding currently normalizes Date to UTC midnight, discarding recorded time and fractions. Swift Replay compares full Date instants, and preserves storage order only for exactly equal instants. All supplied date-only fixtures and scenario assertions pass, but imported transactions whose timestamps are out of order within a day cannot match Swift with the current model. Preserve transaction timestamp precision when decoding (without normalizing to calendar day), then sort/filter that precision; the list command already makes --until inclusive through 86,399 seconds. Resolving fractional timestamps requires a shared model representation change. I have not changed shared model files.

No forbidden/shared file was edited. No failing command saves a store.
