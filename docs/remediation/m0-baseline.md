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
- `Tools/M0/run-baseline.sh` and `Tools/M0/run-benchmarks.sh` install exit traps that delete all temporary state on success, error, or interruption. All trial devices and temporary roots were confirmed absent before M0 completion; one ad-hoc diagnostic shell that failed before reaching its normal cleanup was detected by the final audit and deleted explicitly.

## Build and test result

| Gate | Result |
|---|---|
| Generic simulator Debug build | Passed |
| iOS regression suite | 126 passed, 0 failed, 0 skipped |
| iOS regression duration | 31.130 seconds reported by the test operation; xcresult interval 50.501 seconds |
| Isolated product corpus benchmark | 1 passed, 0 failed, 0 skipped in a separate test-host process |
| Product benchmark duration | 3.244 seconds reported by the test operation; xcresult interval 5.971 seconds |
| Rust unit tests | 29 passed, 0 failed, 0 ignored; pinned to one test thread |
| Rust test execution | 0.77 seconds after build |
| `cargo fmt --check` | Passed |
| `git diff --check` | Passed |
| `Info.plist` and entitlements | `plutil -lint` passed |
| String Catalogs | `xcstringstool compile --dry-run` passed for Localizable and InfoPlist catalogs |
| Fixed fixture manifest | 7 files matched generator output and SHA-256 manifest |

The build currently emits ten distinct Swift-concurrency warnings: nine `UserDefaults` actor-isolation warnings in `Diagnostics.swift` and one actor-isolation warning in `MetricKitDiagnosticsSubscriber.swift`. They do not fail Swift 5 mode, but are recorded risks for later cleanup rather than hidden by M0.

The existing Rust test helper derives temporary directory names from process ID plus wall-clock nanoseconds. A parallel baseline run reproduced a directory collision/removal race in `extract_tar_gz_bytes_extracts_regular_files`; M0 therefore pins the suite to `--test-threads=1` for reproducible evidence and records the helper as later test-harness debt instead of changing Rust production inputs or rebuilding the xcframework in this milestone.

## Fixed corpus

`InkPondTests/M0Fixtures/manifest.json` pins:

- source files with exactly 20,000, 100,000, and 500,000 UTF-16 code units;
- 100-heading and 500-heading Typst documents;
- 100 deterministic project-card records;
- one Typst source with exactly 300 forced Preview/Slideshow pages.

Regeneration is deterministic through `FixtureGenerator.swift`; validation compares the full bytes and manifest, not only file names or sizes. The baseline script copies these resources to its temporary root and validates that isolated copy.

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

## Product-seam corpus characterization

The iOS test bundle contains the same hashed fixtures and exercises current app/FFI seams on the pinned simulator:

- syntax tokenization accepts the 20k, 100k, and 500k UTF-16 sources;
- Rust-backed Outline parsing returns exactly 100 and 500 headings;
- the 100-project corpus decodes with stable first/last identities;
- live Preview SVG compilation returns exactly 300 pages;
- coordinated sandbox write/read/move/delete completes successfully.

The test emits per-operation `M0_PERF` milliseconds into xcresult activities. The table above remains the stable cross-run numeric comparison because test-host launch and instrumentation overhead are not isolated enough to treat one simulator sample as a latency promise. M5 must repeat the product-seam measurements with memory, concurrency, I/O, and UI instrumentation before/after each optimization.
