# Audit remediation ledger

This ledger is the traceability source for the remediation plan in [#24](https://github.com/Lin0u0/InkPond/issues/24). Each verified audit item assigned by child issues #26–#31 has one owner, a deterministic regression seam, an evidence gate, and a documentation destination. M7 (#32) verifies the whole ledger rather than owning new findings.

Status values are `planned`, `in progress`, `verified`, or `blocked`. M0 establishes ownership only; a row becomes `verified` only when its evidence exists and passes.

## M1 — file reliability kernel (#26)

| ID | Verified finding / required behavior | Regression seam | Required evidence | Documentation | Status |
|---|---|---|---|---|---|
| M1-01 | Projects and files lack stable IDs, monotonic revisions, immutable snapshots, and a versioned manifest. | Public identity/snapshot/manifest codecs | Round-trip and monotonicity tests | Storage ADR | planned |
| M1-02 | Storage implementations need one backend contract for local, iCloud, shadow, external, and fake stores. | `ProjectStorageBackend` contract suite | Same suite passes every backend | Storage ADR | planned |
| M1-03 | Operations need a separate versioned journal with prepared/applied/committed states. | Journal public API | Crash/restart replay at every state | Journal schema | planned |
| M1-04 | Writes must stage, verify, atomically replace, then durably commit. | File transaction API | Fault injection at each stage | Transaction protocol | planned |
| M1-05 | Path validation must reject traversal and symlink ancestors for every CRUD operation. | Storage CRUD API | Canonical-containment and symlink matrix | Path safety notes | planned |
| M1-06 | Autosave, flush, close, export, and conflict resolution can bypass one revision-aware writer. | Per-file writer API | Queued old autosave cannot overwrite newer flush | Session lifecycle | planned |
| M1-07 | Two windows can currently acquire competing write ownership. | Project lease API | Second writer rejected; read-only/transfer paths pass | Lease semantics | planned |
| M1-08 | Security-scoped bookmark access needs balanced RAII ownership. | Bookmark lease API | Repeated path lookup has zero net reference leak | External-folder ADR | planned |
| M1-09 | Reachability work must be asynchronous and never semaphore-block MainActor. | Reachability state stream | Actor/isolation and cancellation tests | Storage ADR | planned |
| M1-10 | Long operations need real domain progress instead of view-local/fake percentages. | `OperationProgress` model | Determinate/indeterminate phase tests | Progress contract | planned |
| M1-11 | Conflict handling must not delete remote data before verified local durability. | Conflict transaction API | Inject failure before local commit; remote remains | Transaction protocol | planned |
| M1-12 | Restart must resume journaled work without switching the project root early. | Recovery coordinator API | Termination matrix and idempotent replay | Recovery runbook | planned |
| M1-13 | Disk-full, permission loss, coordination failure, and process interruption are not deterministically covered. | Fault-injectable fake backend | Full transaction-stage fault matrix | Simulator test matrix | planned |

## M2 — document and workspace sessions (#27)

| ID | Verified finding / required behavior | Regression seam | Required evidence | Documentation | Status |
|---|---|---|---|---|---|
| M2-01 | Each text tab needs independent text revision, snapshot, save/sync, selection, scroll, undo/find, diagnostics, and asset state. | `DocumentSession` API | Two-tab state-isolation suite | Session lifecycle | planned |
| M2-02 | Workspace ownership is split across view state instead of one lease/tab/resource/mode/preview/routes owner. | `WorkspaceSession` API | Authoritative-state tests | Session lifecycle | planned |
| M2-03 | Session lifetime currently follows `DocumentEditorView` and navigation reconstruction. | Session registry API | Pop/reopen/reconstruction retention tests | Session lifecycle | planned |
| M2-04 | Compiler, export, Preview, and sync read mutable live bindings. | Immutable snapshot inputs | Mutation-after-submit tests | Snapshot contract | planned |
| M2-05 | Resource tabs can expose text-only Find, Outline, and editor commands. | Workspace command availability | Image/PDF/SVG command matrix | Workspace behavior | planned |
| M2-06 | Closing a tab can resurrect stale `currentFileName` state. | Tab close/open API | A → close → resource → close sequence | Session lifecycle | planned |
| M2-07 | External single `.typ` files lack a dedicated Editor + Preview workspace and folder-link upgrade. | External-file session API | Open/upgrade tests | External-file workspace | planned |
| M2-08 | Asset insertion is not bound to a stable token, revision, and tab session. | Asset request API | Type/switch/close race matrix; no orphan files | Asset import contract | planned |
| M2-09 | Saving, Saved Locally, Pending Sync, Synced, and Conflict are conflated. | Session state model | State transition table tests | Sync state language | planned |
| M2-10 | Switch, close, background, and interactive pop can lose or roll back newest text. | Session lifecycle API | Lifecycle race suite | Session lifecycle | planned |
| M2-11 | Reopened tabs may restore the wrong selection, scroll, or undo context. | Session persistence API | Per-file restoration tests | Session lifecycle | planned |
| M2-12 | A second window for the same project can mutate the active session. | Workspace lease integration | Multi-scene write rejection | Lease semantics | planned |
| M2-13 | UIKit/SwiftUI reconstruction can restore cursor state before the real text buffer. | Editor adapter API | Reconstruction ordering test | Editor integration | planned |

## M3 — cloud-first offline synchronization (#28)

| ID | Verified finding / required behavior | Regression seam | Required evidence | Documentation | Status |
|---|---|---|---|---|---|
| M3-01 | Sync needs Base/Local Shadow/Remote manifests and per-file digests. | Sync manifest API | Three-replica round trips | Cloud/offline ADR | planned |
| M3-02 | Edit/rename/move/delete/restore/auxiliary operations need resumable logging. | Sync operation log | Idempotent replay suite | Sync protocol | planned |
| M3-03 | Global target policy and per-project actual migration state must be distinct. | Storage policy API | Mixed-transition project tests | Migration model | planned |
| M3-04 | Migration needs Waiting/Copying/Verifying/Committing/Paused/Failed/Complete journal phases. | Migration coordinator API | Termination at every phase | Migration recovery | planned |
| M3-05 | Migration progress must report real projects/files/bytes and never fake 0%. | `OperationProgress` integration | Known-byte fixture assertions | Progress contract | planned |
| M3-06 | Text conflicts need deterministic Base/Local/iCloud three-way merge; automatic non-overlap still requires confirmation. | Text merge API | Fixed diff3 corpus and confirmation state tests | Merge semantics | planned |
| M3-07 | Binary conflicts need Keep Local, Keep iCloud, and Keep Both. | Binary conflict resolver | Choice matrix with digest verification | Merge semantics | planned |
| M3-08 | File conflicts should freeze one file; project rename/delete conflicts should freeze the project. | Sync availability API | Scope-of-freeze tests | Sync protocol | planned |
| M3-09 | Managed deletion needs tombstones and Recently Deleted. | Deletion/restore API | Delete/restore/permanent-delete replay | Deletion semantics | planned |
| M3-10 | iCloud → local migration must ask whether to retain the verified cloud copy; never silently delete. | Migration completion API | Default-retain and explicit-delete tests | Migration UX contract | planned |
| M3-11 | Fonts, Local Packages, and Snippets need independent opt-in sync. | Auxiliary sync policy | Per-category opt-in matrix | Cloud/offline ADR | planned |
| M3-12 | Snippets need stable-ID merge; packages need namespace/name/version plus digest identity. | Auxiliary merge API | Identity/collision tests | Auxiliary sync schema | planned |
| M3-13 | TestFlight builds must never start migration automatically. | Distribution migration gate | TestFlight receipt regression test | TestFlight checklist | planned |
| M3-14 | Offline/reconnect/partial transfer and simultaneous-change behavior lacks deterministic coverage. | Fake sync backend | Full connectivity and transfer matrix | Simulator test matrix | planned |
| M3-15 | Delete/modify and rename/rename conflicts lack deterministic coverage. | Fake sync backend | Conflict matrix | Merge semantics | planned |
| M3-16 | Disk full, unavailable container, permission loss, stale metadata, and insufficient shadow space need safe failure. | Fake sync backend | Capacity/permission/metadata matrix | Recovery runbook | planned |

## M4 — compiler, Preview, and cache (#29)

| ID | Verified finding / required behavior | Regression seam | Required evidence | Documentation | Status |
|---|---|---|---|---|---|
| M4-01 | Compilation lacks one immutable identity containing compiler, generation, revision, sources, files, fonts, and packages. | `CompilationSnapshot` codec/API | Mutation-after-submit tests | Compiler state ADR | planned |
| M4-02 | Compiler/window instances can share mutable Rust `SimpleWorld` state. | Compiler instance API | Same-project concurrent isolation test | Rust session model | planned |
| M4-03 | Source replace, compile, SourceMap, and artifact extraction are not one isolated transaction. | Rust compilation session | Cross-generation consistency tests | Compiler state ADR | planned |
| M4-04 | Typst core cannot be hard-cancelled; the approved contract is a truthful soft UI deadline plus latest-wins generation invalidation. | Generation invalidation and publication gate | Expired generations publish nothing; worst-case duration/CPU/memory/queue measurements | Cancellation contract | planned; soft timeout approved 2026-07-10 |
| M4-05 | Real-time Preview must be latest-wins and expired generations must publish nothing. | Preview publisher API | UI/cache/stats/session stale-generation matrix | Compiler state ADR | planned |
| M4-06 | Manual export needs an independent user-cancellable task unaffected by typing. | Export task API | Preview edits do not cancel export | Export behavior | planned |
| M4-07 | SVG, PDF, SourceMap, and compiled-output statistics need atomic bundle publication. | Preview artifact API | No mixed-generation bundle test | Artifact schema | planned |
| M4-08 | Last successful Preview may remain visible only with explicit stale state. | Preview state model | Stale transition tests | Approved Preview UX | planned |
| M4-09 | Editor/Preview sync must be disabled when artifact and SourceMap revisions differ. | Sync coordinator API | Mismatched-revision rejection | Compiler state ADR | planned |
| M4-10 | Preview cache needs immutable fingerprint directories and atomic publication. | Cache store API | Interrupted publish/read-failure-as-miss tests | Cache format | planned |
| M4-11 | Font cache keys omit canonical path/size/mtime/content digest. | Font fingerprint API | Same-path replacement invalidates all layers | Font cache format | planned |
| M4-12 | Package failures can be cached forever and ignore later installs/changes. | Package resolution cache | Retry/TTL/change invalidation tests | Package cache contract | planned |
| M4-13 | Explicit unresolved fonts must error; fallback only applies without an explicit family; simple dynamic constants need resolution. | Font resolver API | Explicit/implicit/dynamic-family matrix | Font resolution | planned |
| M4-14 | Compiler progress is not truthfully generation-bound by observable phase. | Compiler progress stream | Phase sequence and indeterminate/determinate tests | Progress contract | planned |
| M4-15 | Current-revision export can silently use a stale artifact. | Export API | Revision mismatch rejection | Export behavior | planned |

## M5 — editor correctness and performance (#30)

| ID | Verified finding / required behavior | Regression seam | Required evidence | Documentation | Status |
|---|---|---|---|---|---|
| M5-01 | Completion context can leak across sessions/windows/projects. | Completion session API | Two-window isolation tests | Editor architecture | planned |
| M5-02 | Highlight work is not one bounded serial latest-wins worker. | Highlight scheduler API | Concurrency maximum and latest-result tests | Editor architecture | planned |
| M5-03 | Failed tokenization can be cached as a successful nil result. | Token cache API | Failure-then-success retry test | Highlight cache | planned |
| M5-04 | Outline reparses per view access instead of once per revision in background/cache. | Outline index API | Parse-count and revision invalidation tests | Outline model | planned |
| M5-05 | AutoPair type-over can run with a non-empty selection. | AutoPair public operation | Selected-text type-over regression | Editor behavior | planned |
| M5-06 | Editor restoration can precede installation of the real text. | Editor adapter API | Ordering regression | Editor integration | planned |
| M5-07 | Text commands remain reachable on non-text resources. | Workspace command API | Resource-kind matrix | Workspace behavior | planned |
| M5-08 | Preview/editor sync lacks transaction IDs, acknowledgement/finally cleanup, source offsets, and X/Y coordinates. | Sync transaction API | Lost-ack/error/race coordinate tests | Sync protocol | planned |
| M5-09 | Floating/split keyboard avoidance does not use real rectangle intersection/layout guide. | Keyboard layout adapter | Floating/split/docked geometry tests | Editor integration | planned |
| M5-10 | WKWebView readiness does not follow navigation completion and failure. | Preview page loader | Success/failure readiness tests | Preview loading | planned |
| M5-11 | Resource preview fingerprints and I/O are not consistently backgrounded. | Resource preview loader | Same-path replacement and actor tests | Preview loading | planned |
| M5-12 | Image import may silently convert supported originals or perform unbounded foreground work. | Image import API | Format preservation/explicit conversion/limits | Asset import contract | planned |
| M5-13 | Older toast/task cancellation can clear newer presentation state. | Presentation token API | Consecutive cancellation race test | Interaction state | planned |
| M5-14 | Import dependency scans and project/file digests are full rather than incremental. | Dependency graph API | Changed-node-only counters | Performance baseline | planned |
| M5-15 | Font/reference scanning runs on MainActor and rescans unchanged nodes. | Scanner API | Actor and changed-node-only tests | Performance baseline | planned |
| M5-16 | Gutter recomputes newline positions instead of maintaining an incremental index. | Line index API | Edit corpus correctness and latency | Performance baseline | planned |
| M5-17 | Preview visible-page lookup is linear. | Page lookup API | 300-page binary-search correctness/latency | Performance baseline | planned |
| M5-18 | Slideshow retains more than previous/current/next pages. | Slideshow page store | 300-page residency bound | Performance baseline | planned |
| M5-19 | Project cards use heavyweight per-card previews instead of generated thumbnails. | Project-card thumbnail store | 100-card memory/scroll benchmark | Performance baseline | planned |
| M5-20 | ZIP export can observe a changing live tree instead of one immutable snapshot. | ZIP export API | Concurrent-edit consistency test | Export behavior | planned |
| M5-21 | Disk I/O, PDF rasterization, image decoding, and large hashing can run on the main thread. | Public async loaders | MainActor/I/O instrumentation matrix | Performance baseline | planned |

## M6 — navigation, UI, accessibility, and localization (#31)

| ID | Verified finding / required behavior | Regression seam | Required evidence | Documentation | Status |
|---|---|---|---|---|---|
| M6-01 | Navigation paths should carry stable `ProjectID`, never SwiftData objects. | `AppRoute` API | Stale/deleted/migrated ID tests | Navigation ADR | planned |
| M6-02 | The app needs one `NavigationStack(path:)` and one destination resolver. | App routing surface | Push/pop destination tests | Navigation ADR | planned |
| M6-03 | Compact must use native push/back/edge gesture while regular retains appropriate workspace chrome. | Navigation UI seam | iPhone/iPad/rotation/Split View matrix | Approved workspace design | planned |
| M6-04 | Mounted UIKit/WebKit editor and Preview identity must survive workspace routing. | Workspace host API | 100 open/back cycles; no cross-contamination/leak | Navigation ADR | planned |
| M6-05 | Fast typing followed by interactive pop must preserve newest revision. | Session/navigation integration | Interactive-pop race test | Session lifecycle | planned |
| M6-06 | iCloud download must finish before one push; failure remains on home. | Project-open coordinator | Success/failure route tests | Project-open behavior | planned |
| M6-07 | Layout decisions need real container width and minimum pane widths. | Layout policy API | Compact/regular/narrow-window matrix | Approved workspace design | planned |
| M6-08 | Project home needs approved Sort, Search, More, New, import/link/deleted/settings, and actionable empty state. | Project-home UI | UI and accessibility assertions | Approved project-home design | planned |
| M6-09 | Approved sync/migration/conflict/Recently Deleted surfaces are missing. | Presentation routes | UI state matrix | Approved sync designs | planned |
| M6-10 | Stale Preview and compiled-output statistics need approved presentation. | Preview UI | Generation-bound UI assertions | Approved Preview design | planned |
| M6-11 | External single-file Editor + Preview workspace is missing. | External workspace UI | Open/link-folder UI tests | Approved external-file design | planned |
| M6-12 | Onboarding must default local and explain explicit iCloud plus complete offline shadow. | Onboarding UI | Default/state/localization tests | Approved onboarding | planned |
| M6-13 | Progress must be indeterminate where no real fraction exists. | Progress UI | Phase/accessibility assertions | Progress contract | planned |
| M6-14 | Plurals and Finder-style localized search are incomplete. | Localization API | Four-locale plural/search tests | Localization guide | planned |
| M6-15 | Core flows are not release-gated under VoiceOver. | Accessibility UI | VoiceOver flow checklist | Accessibility matrix | planned |
| M6-16 | Interactive targets need 44×44 pt minimum regions. | UI hit regions | Geometry assertions | Accessibility matrix | planned |
| M6-17 | Dynamic Type through accessibility sizes, including editor `UIFontMetrics`, is incomplete. | Typography UI | Maximum-size layout tests | Accessibility matrix | planned |
| M6-18 | Reduce Motion must remove large translation, scale, and spring effects. | Motion policy | Reduce Motion assertions | Accessibility matrix | planned |
| M6-19 | Light/dark contrast needs validation. | Theme surfaces | Contrast audit evidence | Accessibility matrix | planned |
| M6-20 | Independent actions must remain independent accessibility elements. | Accessibility tree | Element/action assertions | Accessibility matrix | planned |
| M6-21 | Every visible change must ship in en, zh-Hans, zh-Hant-HK, and zh-Hant-TW. | String Catalog | Missing-translation validation | Localization guide | planned |
| M6-22 | String Catalog extraction ownership treats valid dynamic keys as stale. | Localization extraction | Extraction/validation regression | Localization guide | planned |
| M6-23 | Project opening and Preview rendering need immediate, human-readable, accessible phase feedback while verbose logs stay diagnostics-only. | Project-open/Preview UI | #23 simulator acceptance flow | Approved progress design | planned |

## M0 and M7 gates

- M0 evidence is recorded in `m0-feasibility.md` and `m0-baseline.md`.
- The user approved the revised soft-timeout/latest-wins contract on 2026-07-10; M4-04 is unblocked for implementation under that contract.
- M7 must resolve every `planned`, `in progress`, or `blocked` row before release-candidate completion.
- Evidence is invalid if it uses real user projects for destructive sync/migration tests or leaves temporary simulators, clones, DerivedData, result bundles, or fixtures behind.
