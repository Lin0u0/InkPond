# M0 reproducible baseline

Recorded 2026-07-10 for issue #25.

## Source boundary

- Starting point: `main@590c297` with the pre-existing dirty worktree named by #25.
- Remediation branch created before any commit: `codex/m0-feasibility-baseline`.
- Independent baseline commit: `bc5e86b` (`Preserve pre-remediation baseline`).
- All M0 tooling, tests, fixtures, and documentation are after that commit, so later changes can always be compared against the preserved baseline.

## Pinned environment and cleanup

- Xcode: 26.6 (`17F113`) from `/Applications/Xcode.app`.
- Destination: temporary iPhone 17, iOS 26.5 (`23F77`), created with a unique name and captured UUID.
- Build: generic iOS Simulator Debug.
- DerivedData, xcresult, fixture copy, benchmark PDFs, timing files, and simulator are temporary.
- `Tools/M0/run-baseline.sh` and `Tools/M0/run-benchmarks.sh` install exit traps that delete all temporary state on success, error, or interruption. Both failed and successful trial devices were confirmed absent after exit.

## Build and test result

| Gate | Result |
|---|---|
| Generic simulator Debug build | Passed |
| iOS unit tests | 125 passed, 0 failed, 0 skipped |
| iOS test duration | 31.773 seconds reported by the test operation; xcresult interval 51.376 seconds |
| Rust unit tests | 29 passed, 0 failed, 0 ignored |
| Rust test execution | 0.69 seconds after build |
| `cargo fmt --check` | Passed |
| `git diff --check` | Passed |
| `Info.plist` and entitlements | `plutil -lint` passed |
| String Catalogs | `xcstringstool compile --dry-run` passed for Localizable and InfoPlist catalogs |
| Fixed fixture manifest | 7 files matched generator output and SHA-256 manifest |

The build currently emits ten distinct Swift-concurrency warnings: nine `UserDefaults` actor-isolation warnings in `Diagnostics.swift` and one actor-isolation warning in `MetricKitDiagnosticsSubscriber.swift`. They do not fail Swift 5 mode, but are recorded risks for later cleanup rather than hidden by M0.

## Fixed corpus

`Tools/M0/Fixtures/manifest.json` pins:

- source files with exactly 20,000, 100,000, and 500,000 UTF-16 code units;
- 100-heading and 500-heading Typst documents;
- 100 deterministic project-card records;
- one Typst source with exactly 300 forced Preview/Slideshow pages.

Regeneration is deterministic through `FixtureGenerator.swift`; validation compares the full bytes and manifest, not only file names or sizes.

## Relative compiler performance

Machine: Apple M4. Tool: Typst 0.15.0 CLI. Each value is the median of three independent compiles; generated PDFs were deleted after measurement.

| Fixture | Runs (seconds) | Median | Output bytes |
|---|---:|---:|---:|
| 20k UTF-16 source | 0.12 / 0.12 / 0.12 | 0.12 s | 26,924 |
| 100k UTF-16 source | 0.21 / 0.21 / 0.21 | 0.21 s | 85,647 |
| 500k UTF-16 source | 2.23 / 2.24 / 2.24 | 2.24 s | 392,049 |
| 100 headings | 0.12 / 0.11 / 0.11 | 0.11 s | 58,493 |
| 500 headings | 0.13 / 0.12 / 0.12 | 0.12 s | 256,548 |
| 300 pages | 0.12 / 0.12 / 0.11 | 0.12 s | 358,488 |

These are relative corpus baselines, not user-facing latency promises. M5 must add simulator-level UI latency, memory, concurrency, and I/O measurements before claiming responsiveness improvements.
