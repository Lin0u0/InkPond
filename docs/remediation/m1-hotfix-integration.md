# M1 integration with production build 57

Validated 2026-09-06 for #26 / #34, after M0 #33 merged into `main` at `0d837c2`.

## Source and merge decisions

- Preserve M1 implementation `057ab6e` and the local compact navigation-title fix `1d6da65`.
- Merge the updated `main`, including build 56 and build 57 at `8cb03d2`, through normal merge history.
- Linked-folder enumeration retains M1's symlink exclusion and the hotfix's fresh download-state checks, cancellation, deadlines, and real file counts. Initial linking retains 600 seconds; explicit refresh retains 120 seconds.
- The file-browser sheet retains both reliable async create/import/delete callbacks and refresh/progress/cancel controls.
- Editor disappearance invalidates linking and cancels refresh immediately, then uses M1's async flush/reconcile/close sequence. Do not restore the old synchronous flush call.
- Both editor layouts retain the refresh-only preview cache bypass. The existing refresh effect preserves the current unsaved editor and entry-source text.
- Correct M1's storage backend selection: folder bookmarks, like external single files, use `.linkedExternal` regardless of the managed-project iCloud setting. Managed local/iCloud selection remains separate.

## Integration regression evidence

`LinkedFolderReliabilityIntegrationTests` verifies:

- A real folder bookmark selects the coordinated external backend with the managed-cloud preference both disabled and enabled; staged replacement and coordinated read return the written bytes.
- A reliable save followed by linked-folder refresh discovers a new asset without following a symlink outside the project.
- Applying refresh effects preserves newer unsaved editor/entry text, and a subsequent reliable write commits that text with the next manifest revision and the new asset identity.

The full suite also retains the M1 regression cases for old autosave versus newer flush, transaction-stage faults and interruption recovery, verified conflict commits, root-migration commit ordering, writable leases, and bookmark reference balance. Existing hotfix tests cover failed/cancelled/replaced refresh tasks, preservation of cached previews on failure, real download progress, cache invalidation, and preview rendering.

## Validation and environment

Command: `CI=1 DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer Tools/M0/run-baseline.sh`.

| Check | Result |
|---|---|
| Generic iOS Simulator Debug build | Passed |
| Application unit/regression suite | 164 tests passed, 0 failed |
| Isolated product-corpus benchmark | 1 passed |
| Rust unit suite, one test thread | 30 passed |
| Diff3 spike and fixed fixtures | 8 cases passed; all 7 fixture hashes matched |
| Formatting, plist and String Catalog checks | Passed |
| Rust source and committed framework versus build 57 | Unchanged |

Xcode 27.0 beta (`27A5194q`), isolated iPhone 17 / iOS 26.5. Typst 0.15.0 CLI medians in seconds: 20k `0.12`, 100k `0.22`, 500k `2.33`, 100 headings `0.12`, 500 headings `0.13`, 300 pages `0.12`. These are corpus measurements, not UI responsiveness claims.

The temporary simulator and test artifacts were removed after the run. Only generated sandbox fixtures were used.

## Evidence boundaries and follow-up

- This is deterministic storage/refresh integration acceptance. Real signed-in iCloud propagation, File Provider behavior, physical-device lifecycle UI, and the future M2 session model are not validated by this run.
- Xcode 27 reports concurrency-isolation warnings in existing diagnostics and in M1's storage/lease constructors and security-scope helpers. Swift 5 mode builds and tests pass; Swift 6 compatibility is not claimed. Resolve these warnings before enabling Swift 6 language mode.
- Xcode also emitted a `SwiftCompile ... exit code 0` diagnostic while forwarding warnings; the build process returned success and the test results above passed. This toolchain diagnostic is recorded rather than counted as a failed test.
- The original per-finding audit ledger remains the M7 traceability checklist; this report does not mark later storage/session/compiler milestones complete.
- The App Store submission remains the existing build 57. This integration does not upload a new build or enable migration for TestFlight.
