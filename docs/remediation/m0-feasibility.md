# M0 feasibility conclusions

Recorded 2026-07-10 for issue #25. These conclusions gate later milestones; none of the spikes is production sync implementation.

## Typst 0.15 hard cancellation — unsupported

### Evidence

- Typst 0.15 exposes synchronous `compile(world)` and has no cancellation token, callback, deadline, or interrupt parameter in its public compilation surface.
- InkPond's C ABI calls Typst synchronously. Once a detached Swift task enters the FFI call, `Task.cancel()` only marks the Swift task cancelled; Rust has no observation point.
- The current 30-second race cancels the detached task handle and suppresses publication, but the synchronous Rust compile can continue consuming CPU and memory until it returns.
- The characterization test `typstCompilerCancelStopsPublicationButDoesNotInterruptSynchronousWorker` proves both halves: the cancelled generation publishes no Preview data, while the blocked synchronous worker still completes after release.
- Debounce sleeps, queued requests, generation publication, and work before entering FFI can be cancelled or discarded. Package HTTP has its own bounded timeout. None of those facts makes an in-progress Typst compile cancellable.

### Decision and gate

InkPond must not describe the current 30-second behavior as a hard compilation timeout. Discarding an expired generation is latest-wins publication safety, not cancellation.

M4-04 remains blocked pending explicit approval of one of these contracts:

1. maintain a Typst fork/upstream patch that threads cooperative cancellation through evaluation, layout, package/file work, SVG/PDF generation, and FFI; or
2. revise the product contract to a soft UI deadline with honest “still stopping” state, latest-wins publication, and bounded subprocess/session isolation where available.

Unsafe thread termination is rejected. M0 does not alter production timeout behavior because that belongs to the approved M4 contract.

## Dependency-free three-way diff3 — behavior feasible, spike not production-ready

### Evidence

`Tools/M0/Diff3Spike.swift` implements deterministic line-oriented Base/Local/iCloud merge behavior with no third-party dependency. Seven public-seam cases pass:

- independent local and remote edits merge automatically;
- overlapping replacements conflict;
- identical edits apply once;
- insertions at the same anchor conflict deterministically;
- delete/replace overlap conflicts;
- repeated lines produce stable output;
- one-sided deletion is preserved.

Conflicts retain Base, Local, and iCloud text and emit stable diff3 markers. The spike is not linked into InkPond.

### Limits and fallback

The spike uses an LCS matrix, so diff construction has quadratic time and memory in line count. It proves merge semantics and determinism, but it is unsuitable as the M3 production engine for unbounded or adversarial documents, including the 500k corpus.

M3 may keep the public merge result and fixed cases, but must replace the internal diff with a bounded linear-space Myers/patience-style implementation and add fuzz/property coverage, newline/encoding policy, conflict-size limits, and the user-confirmation workflow. If those bounds cannot be met without a dependency, return for separate dependency approval; do not silently ship this spike.

## iCloud and File Provider simulator semantics — partially verifiable

### Fresh simulator result

On a newly created iPhone 17 / iOS 26.5 simulator with no Apple account, `simctl icloud_sync` failed with `BRCloudDocsErrorDomain` code 153. The app's simulated entitlements are present, but an entitlement and a sync trigger do not create an authenticated ubiquity container or prove propagation.

### Safe simulator coverage

Isolated simulators can deterministically verify:

- local/shadow filesystem transactions and restart recovery;
- `NSFileCoordinator` behavior against ordinary sandbox files;
- unavailable-container and offline UI/state handling;
- session, journal, manifest, tombstone, merge, and migration logic through a fault-injectable fake backend;
- app lifecycle, navigation, progress, accessibility, and non-destructive integration behavior;
- cleanup of all simulator data after each destructive matrix.

### Unsupported claims in a fresh isolated simulator

A fresh unauthenticated simulator cannot prove:

- cross-device iCloud Drive propagation or ordering;
- real placeholder eviction/download transitions and resource metadata timing;
- remote `NSMetadataQuery` updates and conflict-version creation;
- account quota, authentication, server throttling, or CloudDocs retry behavior;
- third-party File Provider behavior, coordination bugs, or provider-specific permissions.

### Decision and fallback

All destructive sync/migration/conflict coverage belongs to the fault-injectable fake backend in isolated simulators. Real iCloud propagation may be claimed only after a separate run using a dedicated, signed-in simulator account and isolated container; the result must be labelled manual/environmental rather than deterministic CI evidence. Third-party File Provider semantics require provider-specific manual acceptance and must not gate the deterministic suite.

No real user project or device data is authorized for these tests.
