# M1 local qualification and handoff

Current code candidate: **`5560ddf44255f56c0559485f9c9dfe904b3b3dc5`** (foundation candidate `7db0a8b`), branch `codex/m1-editing-foundation`, 16 October 2026. Planning baseline: `7c270124993bac09967109f95e603ebb47bd98ff`; reviewed product baseline: `c8a57458afd124b14c7b8e632108bffd388ab3f2`.

**M1 local engineering checkpoint accepted.** All 25 WP-05–WP-09 task contributions are locally qualified, including actual automatic local app-bundle recovery after interruption. M2 may integrate the accepted source and contracts. M3 still needs M2's accepted integration and applicable M0 inputs. Controlled numerical performance, G1/G2, reference and release gates remain mandatory and open. No push, release or main-branch merge was performed. See the [accepted engineering handoff](M1-ENGINEERING-HANDOFF.md).

The [foundation machine record](../evidence/M1-LOCAL-QUALIFICATION.json) retains historical run digests, resource trajectories, metadata samples and environment. The [native follow-up record](../evidence/M1-NATIVE-QUALIFICATION.json) retains the current candidate, frozen executable/test bytes and all 42 native attempts. Original foundation binary digests remain recorded; those historical binary bytes were replaced by the follow-up build and are not retained. The [actual recovery record](../evidence/M1-RECOVERY-QUALIFICATION.json) adds verified native interruption/relaunch and recovered-file evidence on the same executable, with no production changes. [Task evidence](M1-TASK-EVIDENCE.json) maps all 25 tasks and 57 bounded children to exact requirement contributions and executable checks. These contributions do not close entire requirements, Visio compatibility or release gates. Raw logs, generated immutable corpora and binaries remain under ignored local build directories.

## Regression evidence

The first four foundation runs below use `7db0a8b`. The unlocked follow-up changes only the benchmark driver and its tests, and qualifies current candidate `5560ddf` in the final native Release suite. Builds and all native runs were serial. Release repeats used the already built executable/test bundle with `--skip-build`.

| Full run | Tests | Explicit skips | Failures | Wall seconds | Raw log |
| --- | ---: | ---: | ---: | ---: | --- |
| Debug final | 607 | 16 | 0 | 34.882 | `build/m1-evidence/full-debug14.log` |
| Release 1 (fresh build) | 607 | 16 | 0 | 30.438 | `build/m1-evidence/full-release-1.log` |
| Release 2 | 607 | 16 | 0 | 28.173 | `build/m1-evidence/full-release-2.log` |
| Release 3 | 607 | 16 | 0 | 28.754 | `build/m1-evidence/full-release-3.log` |
| Unlocked native Release, current candidate | 607 | 13 | 0 | 29.798 | `build/m1-evidence/full-release-native-final.log` |

The wall figures above are XCTest suite durations and exclude compilation. Thirteen skips are preexisting optional installer/reference fixtures. In the original four runs, three additional skips are native `BenchmarkProfileTests` requiring an unlocked graphics session. After the user unlocked the desktop, all five native/refusal tests pass and none of those three skip in the final native Release suite. All 43 calculation checks (20 incremental, 23 native async), save/undo/close, runtime/render/UI and owned lifecycle checks pass without those skips.

Python verification passes 34 tests (`python-tests-final.log`). The separate seven boundary-audit tests pass (`foundation-audit-tests-final.log`); the import audit covers nine explicit pure files, and strict formatting covers 25 explicit foundation/critical state files (`critical-format-check-final.log`). This is an import-token guard plus a real infrastructure target, not a claim that all model/calculation code has moved out of the app target. Final backlog validation preserves 39 packages, 161 tasks, 154 requirement coverage entries and the original dependency graph.

Reproduce the full Release runs from this worktree:

```sh
MACVISIO_LIFECYCLE_EVIDENCE_PATH="$PWD/build/m1-evidence/new-lifecycle.json" \
MACVISIO_METADATA_EVIDENCE_PATH="$PWD/build/m1-evidence/new-metadata.json" \
swift test -c release --scratch-path .build-m1 --jobs 4
```

Use fresh evidence paths and retain every failed attempt. Subsequent repeats can use `--skip-build` only while the source candidate is unchanged.

## Save/gesture and historical intermittency disposition

The retained baseline responder-handler regression fails deterministically: drag (100,100) to (140,140), Save, then Escape leaves saved geometry at (140,140), live geometry at (100,100), and the document clean (`gesture-before.log`). This test drives native Canvas responder methods; it is not the foreground NSApplication queue trace required by WP-08-T05.

Canvas now owns drag/resize/control previews. Save and autosave serialize committed geometry; Escape discards the preview. Release commits once and registers one undo action. Inline/inspector text is accepted explicitly before Save. When that acceptance starts a long calculation, its Save/Close waits on a bounded continuation; cancellation, stale input, failed admission or direct close refuses the held operation before snapshot/write/close. A Save invoked during an already pending independent calculation still captures the current committed state.

Save captures an immutable `(snapshot ID, state ID, diagram)` only when the request starts. Own saved/recovery state IDs determine dirty status; AppKit change-count callback timing does not determine which model was saved. A deterministic boundary hook inserts an edit after snapshot capture but before the AppKit token boundary and requires the newer state to remain dirty. Overlapping/failing/copy saves, autosaveElsewhere, untitled autosaveAs, actual autosave during a preview, undo/redo through saved identities and queued text saves all pass in the four final full suites.

The review's original one-time timer-driven dirty-state failure has no unique proven cause. The original timer-driven test remains intact. M1 reproduces and removes a snapshot/token ordering hazard that could produce the observed class of error, adds deterministic coverage, and records repeated full-suite context passes. This is the local engineering disposition; it is not proof that no future race exists. Actual local automatic recovery is qualified below; broader AR-09 shipping installation/platform and release qualification remain open.

External-writer checks use actual child-process writes, source metadata fingerprints, queued-save admission and symlink aliases. Stale same-source writes refuse replacement; Save As and explicit Revert preserve the available versions. A failed post-save metadata verification fails closed for later same-source saves. Fingerprints do not detect a writer preserving inode, size and modification time and do not exclude a writer racing after the final check.

## Task disposition

“Locally qualified” means the bounded implementation contribution and named regressions pass. Original package/dependency and overall acceptance requirements remain in force; notably WP-05-T05's local checks do not close its predecessor's installed recovery qualification.

| Task | Local disposition | Contribution and checks |
| --- | --- | --- |
| WP-05-T01 | Locally qualified | Deterministic gesture/save and exact token-boundary reproduction. Checks: `GestureSaveContractTests`, `AsyncDocumentSaveTests`. |
| WP-05-T02 | Locally qualified | Canvas-owned drag/resize/control previews; explicit text commit; one release transaction. Checks: `GestureSaveContractTests`, `PreviewCalculationContractTests`, `ControlHandleTests`. |
| WP-05-T03 | Locally qualified | Exact immutable save identity, queued/failing/copy saves, undo through saved identity. Checks: `GestureSaveContractTests`, `AsyncDocumentSaveTests`. |
| WP-05-T04 | Locally qualified | Actual automatic local app-bundle interruption/relaunch recovery, native Save As/readback, external modification refusal/revert and staged write interruption. Checks: `SavePreservationRebaseTests`, `ExternalWriterRecoveryTests`, `AtomicJobOutputTests`. |
| WP-05-T05 | Locally qualified | Existing metadata formats remain readable; rebased bindings follow successful save. Checks: `NativeMetadataStorageTests`, `SavePreservationRebaseTests`, `SourceResourceOwnershipTests`. |
| WP-06-T01 | Locally qualified | Committed/view/source/derived ownership, affected sets and coordinate boundaries. Checks: `PageRuntimeTests`, `TransactionRuntimeTests`, `RetainedSceneTests`. |
| WP-06-T02 | Locally qualified | ID/hierarchy/adjacency indexes, atomic fallback and certified append. Checks: `PageRuntimeTests`, `TransactionRuntimeTests`. |
| WP-06-T03 | Locally qualified | Conservative indexed hit/marquee and local snapping under actual paint order. Checks: `PageRuntimeTests`, `RetainedSceneTests`. |
| WP-06-T04 | Locally qualified | Common native commands publish change sets and presentation-only events. Checks: `TransactionRuntimeTests`, `PreviewCalculationContractTests`, `AsyncCalculationContractTests`. |
| WP-06-T05 | Locally qualified | One bounded infrastructure target, import audit, scoped formatter and isolated CLI dispatch. Checks: `DeveloperCommandsTests`, `RetainedSceneTests`, `scripts/tests/test_foundation_boundaries.py`. |
| WP-07-T01 | Locally qualified | Retained conservative dependencies, cycles, dynamics/volatility and diagnostics. Checks: `IncrementalCalculationTests`. |
| WP-07-T02 | Locally qualified | Bounded syntax cache and immutable host/source identity invalidation. Checks: `IncrementalCalculationTests`. |
| WP-07-T03 | Locally qualified | Affected closure/field convergence, zero-evaluation control baseline and pointer previews. Checks: `IncrementalCalculationTests`, `PreviewCalculationContractTests`. |
| WP-07-T04 | Locally qualified | Native long calculations use owned cancellable workers and exact publication gates. Checks: `AsyncCalculationContractTests`, `IncrementalCalculationTests`. |
| WP-07-T05 | Locally qualified | Full/incremental state+diagnostic equivalence and bounded evaluator work counts. Checks: `IncrementalCalculationTests`, `AsyncCalculationContractTests`. |
| WP-08-T01 | Locally qualified | Immutable evaluated scene values, shared layer policy and route/background identity. Checks: `RetainedSceneTests`, `PageBackgroundTests`, `LayerSettingsTests`. |
| WP-08-T02 | Locally qualified | Cull before path/text preparation and keep selection/handle overlays local. Checks: `RetainedSceneTests`, `PerformanceEvidenceTests`. |
| WP-08-T03 | Locally qualified | Cost/count-bounded path/text/image caches, dependency route invalidation and stale inputs. Checks: `RetainedSceneTests`, `ResourceBudgetTests`, `LifecycleMemoryTests`, `PreviewCalculationContractTests`. |
| WP-08-T04 | Locally qualified | Retained inspector/page/stencil controls, mixed values and per-page view state. Checks: `RetainedEditorUITests`. |
| WP-08-T05 | Locally qualified | Screen/output policy fixtures plus named-host native routed raster feedback trace. Checks: `RetainedSceneTests`, `OwnedExportJobTests`, `BenchmarkProfileTests`. |
| WP-09-T01 | Locally qualified | Bounded job admission, ownership, cancellation and stale main delivery. Checks: `LifecycleJobTests`. |
| WP-09-T02 | Locally qualified | Native open/template/stencil/library and export owned workflow integration. Checks: `OwnedOpeningWorkflowTests`, `OwnedExportJobTests`, `LegacyConverterProcessTests`. |
| WP-09-T03 | Locally qualified | Install exact written source archive/bindings while preserving newer semantic edits. Checks: `SavePreservationRebaseTests`, `AsyncCalculationContractTests`. |
| WP-09-T04 | Locally qualified | Immutable source resources, header metadata decode, image/undo budgets and twenty cycles. Checks: `SourceResourceOwnershipTests`, `NativeMetadataStorageTests`, `MetadataProbeEvidenceTests`, `LifecycleMemoryTests`, `UndoPayloadBudgetTests`. |
| WP-09-T05 | Locally qualified | Headless exit/output contract, atomic destination safety and converter interruption. Checks: `DeveloperCommandsTests`, `AtomicJobOutputTests`, `LegacyConverterProcessTests`, `ExternalWriterRecoveryTests`. |

## Architecture contract results

| Contract | M1 evidence and practical limit |
| --- | --- |
| AC-01 | Prepared paint/hit tests and 20 grouped plus 20 ungrouped gesture cycles preserve complete parser statistics, with zero evaluated cells/visited objects/commits and no calculation span. Cold AppKit path/text preparation is permitted; semantic evaluation is not. |
| AC-02 | Selection/zoom/pointer previews bypass semantics. Control formulas solve once on committed release; nonlinear repeated solves fork the captured baseline session. |
| AC-03 | Committed edits publish typed affected sets, stable semantic state IDs, explicit invalidation and one undo contract. Full immutable input/final diffs remain compatibility boundaries; untouched equal pages are skipped before per-object maps. Structural fallback and container-copy costs remain. |
| AC-04 | Calculation/jobs carry owner/snapshot/revision; stale/cancelled results cannot publish. Route keys include endpoints, evaluated ports, obstacles, layers and signed geometry; unrelated straight routes are retained. |
| AC-05 | Exact snapshot acknowledgement, independent recovery identity, failure/queued/conflict/rebase and undo-to-saved tests pass. Actual automatic local app-bundle recovery passes; signed shipping installation/platform recovery gates remain separate. |
| AC-06 | Expression cache: 2,048 entries/2 MiB. Node and label caches: 4,096 entries/32 MiB charged cost each. Decoded images: 128 entries/64 MiB. Undo: 100 groups/64 MiB conservative charge, with one explicitly reported oversized current action allowed. Jobs: two workers/32 outstanding including main delivery; saves: 32 active/queued, trace 64. Routes and issue tables are owned by the current scene/session/input; they report retained work/cost but have no universal hard byte cap independent of document size. |
| AC-07 | Screen/PDF/PNG/SVG share evaluated visibility, printability and layer/color policy; editing decorations are explicit. Local fixtures pass. Unlocked native event/raster traces pass; controlled input/frame and independent reference/output qualification remain open. |
| AC-08 | Existing preservation behavior is retained; complete object/cell unsupported-content diagnostics and editing policy belong to M0/M2/domain work and remain open. |

AR-01 through AR-07 and AR-10 have concrete local contributions, recorded in the backlog. No whole architecture finding is globally closed: AR-06 includes structured diagnostics work beyond M1; AR-08 needs the licensed exact-build reference; AR-09 needs broader shipping installation/platform, controlled performance and release gates; AR-11 needs complete native keyboard/VoiceOver/platform journeys. M0's instrumentation/corpus/adapter through `fc69ccb` was adapted; its final documentation-only `02dea533` does not supply the missing Visio reference.

## Measured work and resource limits

Both warm three-page calculation fixtures, at 40 and 4,000 formula nodes per page, report identical local engine work: four geometry nodes, two field nodes, 14 uncached cells, ten typed/field formula evaluations, zero fallback input-comparison nodes, nine dependency-source comparisons and nine host preparations. These counters exclude full commit-input/final model comparisons, container copies, initial setup and explicit structural/dynamic fallbacks. M0 `visitedObjects` counts the evaluation loop, not all infrastructure work. No whole-command O(k) claim is made.

The first Release 2,200-node request returned pending after **5.7625 ms** of main request work and delivered its heartbeat. The text-worker fixture used two main-owned records and reported a process maximum of **0.2338 ms** per record. These are local observations, not p95 or maximum supported text latency. Each AppKit text record and each export object remains nonpreemptable. Export's 4 ms/32-step batch target does not cap initial scene/runtime preparation or a single complex object; recorded maxima expose those costs.

Twenty lifecycle cycles use 64 shapes, eight edits and a 2 MiB opaque source part per document, with a hidden native editor, layout, viewport rasterization and drained queued teardown. Every cycle verifies document release and detached editor references/scenes. Separate tests exercise twenty 1024² decoded images and long undo histories. RSS is process-wide allocator/OS data. The “peak” below is the maximum post-cycle sample; the initial baseline is recorded separately.

| Run | Baseline RSS bytes | Post-cycle sample peak | Final RSS bytes | Fitted bytes/cycle |
| --- | ---: | ---: | ---: | ---: |
| Earlier Debug editor run | 431,734,784 | 420,544,512 | 420,544,512 | +380,552.28 |
| Final Debug | 688,422,912 | 692,453,376 | 681,967,616 | −366,632.04 |
| Release 1 | 688,848,896 | 693,370,880 | 688,603,136 | +13,156.48 |
| Release 2 | 710,819,840 | 702,955,520 | 690,126,848 | −842,889.05 |
| Release 3 | 963,067,904 | 967,065,600 | 955,252,736 | −835,756.46 |

The earlier positive slope is retained, not hidden by later negative slopes. These short series do not prove absence of leaks, flat RSS, a universal retained-byte limit or standard/large specification workload acceptance. Explicit cache/undo/job limits and ownership assertions are the deterministic local evidence.

The first Release metadata discriminator probe uses 8,412,826 synthetic bytes/5,000 nodes, one warmup and five measured samples: full-object discriminator median **11.9314 ms**, header-only median **4.8955 ms**. This measures only envelope discrimination, not complete model decoding/import or a universal speedup. All raw samples and repeat series are in the machine record.

## Retained failed runs and repairs

Failures were retained and repaired before the final full suites; they are not passing qualification evidence.

- Early grouped calculation fixtures used an unprimed retained session and an unsupported date picture. Their setup was corrected while retaining strict work/state assertions; evaluator semantics were not widened.
- A real undo grouping bug was repaired. Queued initial-fit work then exposed document lifetime hazards; queued fit captures weak owners and checks current visible ownership.
- Native opening/appearance refresh exposed closed-window controllers in `NSApp.windows`. Refresh checks visibility and active ownership.
- Queued AppKit/Core Animation layout exposed a separate stale editor tree after document close. Idempotent detachment runs from both close and windowWillClose, clears links/scene/gesture resources, and guards subsequent layout/refresh/hit access. Tests retain closed controllers through document release and include a nil-window-delegate case.
- Debug8/9/10 compile failures were a missing infrastructure import and test-only NSText/NSTextView casts; fixed before successful compilation.
- Debug11 deadlocked successful async text close at nested synchronous AppKit activity admission (`debug11-sample.txt`). Production close now takes a fresh main turn, asynchronous `performActivity`, and `continueActivity` for nested `super.canClose`, with exact identity checks and exactly one completion.
- Debug12 then exposed an invalid fixture holding an AppKit activity before text publication/undo notification (`debug12-sample.txt`). The supersession fixture now holds only after accepted publication and undo completion. Original success and corrected queued refusal pass all final runs.
- The recovery fixture incorrectly forced autosaveElsewhere after establishing a permanent file URL, producing Cocoa 512. It now uses a genuinely untitled document and separately verifies autosaveAs. Actual external conflicts can be AppKit Cocoa 67000 or the typed source conflict; tests accept only those cases.
- The routed benchmark compared NSEvent pointer identity even though AppKit copies posted events. It now checks owned event type/window/timestamp and dispatch count. Further diagnostics in the original run found `CGSSessionScreenIsLocked=1`, inactive app and no key window; that locked run has no native success claim. Preflight reports this prerequisite; three tests explicitly skip while locked. The later unlocked qualification is recorded below.

## Local engineering acceptance and remaining release qualification

**WP-05-T04 locally qualified:** In addition to checkpoint/readback, actual interrupted writer, conflicts and autosave coverage, the exact candidate executable ran in a normal isolated local app bundle. A committed unsaved page UUID/name/counts and Edited state survived SIGKILL of PID63306 and automatic no-file relaunch under PID63462. Home initially covered the already-restored Untitled editor. Its exact content was verified before any Save As or explicit Open; native Save As then produced an independently decoded matching file and clean UI, followed by a successful fresh-process public VSDX readback. The [recovery qualification](M1-RECOVERY-QUALIFICATION.md) records procedure, evidence and limits. Production source stayed unchanged. This qualifies the current-host local engineering recovery path, while shipping installer/signing/platform matrices remain separate. Recovered named-original saves without a known source fingerprint remain fail-closed with Save As/Revert available.

**WP-08-T05 local contribution qualified:** On the same Mac16,10 Apple M4/16 GiB/macOS 27.0.1 build 26A434/local APFS host, the user unlocked the desktop. Final native tests pass; twelve public scaling traces and thirty exact 1,000-shape/500-connector interaction traces pass without failed attempts. The next section records scope and observed timings. Controlled input/frame/performance gates remain unaccepted. This host is not controlled/exclusive hardware, and no hardware-input, drag/pan, compositor/frame or VoiceOver qualification is claimed.

The immutable public corpus includes 12 fixtures (100/1,000/5,000/20,000 objects × balanced/hierarchy/formula-heavy); the spec corpus includes the authored interaction/standard/large shape/connector/page counts. Generator/validator and refusal tests pass. Generating fixtures does not produce event, timing, memory or Visio compatibility evidence. The licensed reference, shipping installation/update/recovery platform matrices, accessibility, stable release integrity and broad workload gates remain with their owning milestones.

Use [M1-HANDOFF.json](M1-HANDOFF.json) for integration identity and [M1-TASK-EVIDENCE.json](M1-TASK-EVIDENCE.json) for contribution-level scope. Full implementation, formatting and final correctness repairs are separate commits (`aa6ff78`, `4c423bc`, `7db0a8b`); the native driver/harness follow-up is `5560ddf`. Documentation-only commits may follow without changing the qualified code candidate.


## Unlocked native follow-up

The user reported “Unlocked and ready”; the session probe then reported the lock key absent, and actual app/key-window admission succeeded. The first unlocked run exposed a driver wait that pumped CFRunLoop work but never dispatched native activation events. A small native probe reproduced and isolated that distinction. The final helper dispatches the NSApplication queue while waiting for both key-window and active-application admission. Its three scripted input events still go through `postEvent`, `nextEvent`, `sendEvent`, NSWindow hit testing and responder routing; they are not direct Canvas handler calls.

An intermediate helper toggled regular/prohibited activation for every sample. The retained repeated native probe showed queued deactivation overtaking later activation and dropping mouse input. The product already initializes regular activation once; XCTest now matches that process lifecycle for the group and restores its previous policy afterward. A final offscreen fixture also exposed viewport admission ordering: the helper now lays out after activation, refreshes canvas size and explicitly scrolls/reflects the clip view before checking target visibility. No document, calculation, runtime or render implementation changed in this follow-up.

All five focused tests pass (`native-unlocked-tests-4.log`): synthetic selection/edit/save/readback/close, large-paper target scrolling, completed calculations with issues remaining failed, private-input refusal and output/input preservation. The final full Release suite passes 607 tests, 13 preexisting installer/reference skips, zero failures. Failed intermediate logs 1–3 and standalone attempts 1–2 are retained with dispositions in the native machine record.

All twelve authored public scaling fixtures pass one complete product trace each: 100/1,000/5,000/20,000 objects × balanced/hierarchy/formula-heavy. The matrix report remains **incomplete for distribution qualification**, as intended: one sample per fixture is insufficient for p95. Its twelve individual attempts all have zero validation errors; no distribution or absolute performance pass is claimed for them.

The exact interaction fixture has 1,000 shapes, 500 connectors, 800 formula cells and 50 images on one page. Thirty fresh product processes pass all required phases/counters, three owned event deliveries, clean committed edits, exact native snapshot save/readback, unchanged inputs and executable hashes. Its corpus uses exact copied fixture bytes and an unchanged authored manifest entry from the original specification corpus. The subset and original manifest hashes/provenance are recorded; both corpora were revalidated after the run. Warm means full filesystem pre-read and fresh app process; it does not mean warm app caches or OS cache eviction.

The combined three-event-to-raster script measured **p50 242.5182 ms, p95 246.7404 ms, maximum 247.0593 ms**. These are local observations of selection plus keyboard edit and raster feedback. They do not establish a 50 ms single-input target or a 33 ms compositor frame; the 50 ms input, 33 ms frame and 100 ms save-stall release gates remain explicitly **unaccepted** because hardware/load are uncontrolled and required frame/save-stall metrics are absent. The current trace also does not qualify hardware input, dragging, panning or VoiceOver. This measured scope and the open gates are retained rather than treating successful event delivery as performance acceptance.


## Engineering acceptance decision

The original M1 exits are satisfied: committed/preview/save/undo consistency and historical-intermittency disposition; bounded runtime/scene/calculation work invariants with explicit full-input/structural fallback costs; revision-safe cancellable long jobs and measured resource/undo policies. All 25 local task criteria have evidence, including actual automatic app recovery. The source tested by the final 607-test Release suite and native traces is unchanged; no new Swift build or rerun is required to record the additional external UI qualification.

`M1-HANDOFF.json` therefore sets `state=ready`, `acceptance_passed=true` and `downstream_acceptance_ready=true` for the **local M1 engineering checkpoint**. This releases M2's M1 integration dependency. It does not accept G1/G2, any numerical release target, supported-platform/distribution matrix or independent Visio compatibility. WP-08-T05 requires real event traces and explicit reporting of material differences/performance misses; it does not replace the specification's later numerical release gates with task-count acceptance. Those mandatory gates remain documented and owned by M0/M2/M3/release work.
