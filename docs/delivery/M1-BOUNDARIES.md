# M1 dependency, tooling and formatting boundaries

The package has the `MacVisio` executable, a bounded `MacVisioInfrastructure` target and the existing test target. The infrastructure target contains only resource budgets, lifecycle jobs and staged atomic output. The model/calculation/runtime sources remain in the application target; the import audit does not claim a complete independent model/calculation module.

## Dependency direction

| Layer | Owns | May depend on |
| --- | --- | --- |
| Foundation infrastructure | Bounded generic cache, cancellation/job queue, staged atomic output | Foundation, platform rename in Darwin |
| Committed values and sources | Diagram/page/node/edge values, preserved source identity and package bindings | Foundation/CoreGraphics plus current interchange helpers |
| Derived semantic runtime | Affected sets, UUID/hierarchy/adjacency/spatial indexes, dependency indexes and syntax cache | Committed values and pure geometry/parser helpers |
| Document coordinator | State/revision identity, undo, saved acknowledgements, source rebasing, job publication | Derived runtime and Foundation infrastructure; AppKit document lifecycle |
| Prepared presentation | Retained paths, attributed text, measured routes/labels, resources and per-page view state | Evaluated values and runtime; AppKit on the main thread |
| Native input and paint | Canvas event interpretation, preview overlays, narrow-phase hits and drawing | Current prepared presentation; committed transactions through the document coordinator |
| Developer tools | Fixture/example generation, audits, profilers, benchmark adapters and CLI processing | Existing product APIs; no dependency from pure runtime back into tooling |

The following nine new foundation files are checked by `scripts/check-foundation-boundaries.py`. Their allowed explicit imports are Foundation/CoreGraphics; `AtomicJobOutput.swift` additionally permits Darwin for the same-volume rename, and the application-owned `UndoPayloadBudget.swift` imports MacVisioInfrastructure. AppKit, SwiftUI, WebKit and unlisted modules fail even in a conditional import branch or an attributed/symbol import. The infrastructure target cannot import the application target. Comments and string examples are ignored while diagnostic line positions are preserved. Missing scoped files fail. This is an import-token check, not a proof of transitive purity or actor isolation.

| Audited file | Current direct application dependencies |
| --- | --- |
| `DocumentChanges.swift` | Diagram/page/node/edge values and shape details |
| `PageRuntime.swift` | Diagram/page/node/edge values, ShapeDrawingOrder, ShapeSnapping |
| `CalculationDependencies.swift` | Diagram values, PageChangeSet, VisioPageBinding, VisioIDAllocator, GeometrySheet and ShapeSheet expressions/parser |
| `ShapeSheetExpressionCache.swift` | ShapeSheet.Expression; cached syntax only, never evaluation hosts or values |
| `MacVisioInfrastructure/LifecycleJobs.swift` | No model/UI symbols; Foundation queue/locks and main-queue delivery closures |
| `MacVisioInfrastructure/ResourceBudget.swift` | No model/UI symbols; generic retained-value costs and LRU |
| `MacVisioInfrastructure/AtomicJobOutput.swift` | LifecycleJobCancellation/LifecycleJobError; Foundation files and Darwin rename |
| `UndoPayloadBudget.swift` | Diagram values, DocumentChangeSet, ResourceBudgets and model encoding |
| `ViewportCoordinates.swift` | CoreGraphics coordinates; typed DrawingLocation/CanvasLocation |

`Diagram.scene(for:)` can evaluate foreground-specific background fields before preparation. `Model.swift` also references validation/interchange helpers. A Foundation import on that existing file would therefore not make the complete model an independent target. ShapeSheet text functions use AppKit measurement. Those edges must be separated deliberately before a broader pure-model extraction.

## Thread and UI-sensitive boundaries

- `MacVisioDocument.replace/applyCalculated`, snapshot capture, undo registration, saved-state acknowledgement and controller refresh belong to the document's main-thread owner. Worker jobs receive captured values and publish only after owner/request/revision checks.
- `LifecycleJobService` and cancellation/cache locking are Foundation work. Its `accepts`, progress and completion closures deliver on main; the document/UI owner decides whether a result is current. Foundation import purity does not make live document objects safe to capture in a worker.
- `PreparedNodeDrawing.init`, retained label preparation, `ShapeRichText.attributed`, `ShapeTextFunctions.metrics`, font/image decoding and every NSBezierPath/NSGraphicsContext drawing operation are UI-sensitive. They remain in the AppKit-facing target and follow the main-thread audit in the rendering contract.
- `RetainedRenderPage` preparation owns route/port evaluation. Paint and exact connector hit tests consume prepared values. Formula evaluation, file reading and document mutation must not enter paint/hit methods. The page runtime broad phase itself evaluates no formula and performs no AppKit operation.
- `InspectorPanel.refresh` preserves the active field editor and displayed-value commit guard; selection/layout changes update presentation only. `EditorRootView` owns per-page selection/viewport state. View state does not create a semantic revision or calculation request.
- `ViewportCoordinates.drawing(CanvasLocation)` and `.canvas(DrawingLocation)` apply paper scale and zoom once. Interchange parent/page transforms remain in DiagramCoordinates; stored node positions already use page coordinates.

## Bounded target extraction

One `MacVisioInfrastructure` target now contains only `ResourceBudget.swift`, `LifecycleJobs.swift` and `AtomicJobOutput.swift` under `Sources/MacVisioInfrastructure`. These files have no Diagram, ShapeSheet, source archive or AppKit type dependency. The application and test targets depend on this target. Consumer-file changes are explicit imports only; model/runtime/calculation targets were not moved. This extraction was coordinated after the calculation and lifecycle owners froze their source and before the parent's grouped build.

The package-visible API is:

- `ResourceBudgets`: decoded-image, retained path/text, undo count/cost constants and `decodedImageCost`.
- `ResourceBudgetCache<Key,Value>`: initializer, `Statistics` fields, `statistics`, `value`, `insert`, and `removeAll`.
- `LifecycleJobInput` and its owner/snapshot/revision initializer/fields; `LifecycleJobKind`; `LifecycleJobError`; `LifecycleJobProgress` and its fields.
- `LifecycleJobCancellation`: initializer, `isCancelled`, `check`, `cancel`, `onCancel`, `removeHandler`.
- `LifecycleJobHandle`: public-to-package read access for identity/kind/input/cancellation and `cancel`; construction stays inside the infrastructure file.
- `LifecycleJobContext`: read access for identity/input/cancellation/current context and `checkpoint`/`progress`; execution/context-box plumbing stays private.
- `LifecycleJobService`: `shared`, initializer, `Statistics` fields, `statistics`, generic `submit`, and owner cancellation.
- `AtomicJobOutput.write`.

The API uses package access under the existing Swift 5.9 package requirement. LifecycleJobInput and LifecycleJobProgress have explicit package initializers; LifecycleJobCancellation has an explicit package initializer. Private/file-private construction, queue, locking and context-box plumbing stays private. Actual app/test consumers import MacVisioInfrastructure, and the existing test target has an explicit dependency. LifecycleJobOwner, progress UI, NSDocument coordination, image decoding and retained rendering stay in the application. Job cancellation/staleness/queue-bound, atomic-failure and cache-budget regressions are part of the parent's grouped validation after this move. The model-dependent undo budget remains with the application until a later deliberate model boundary is available.

## Formatter and audit commands

`.swift-format` configures four-space indentation, a 110-column target, separate statements/case/variable declarations and ordered imports. `scripts/check-foundation-format.sh` consumes the nine audited Foundation files plus sixteen explicitly named document, canvas, calculation, routing, export and lifecycle state files. `STATE_FORMAT_FILES` in the audit script is the additional formatter manifest; these AppKit owners are deliberately excluded from the Foundation import audit. Default/`--check` runs strict lint; `--fix` is the explicit formatting mode; `--list` prints the exact 25-file formatting scope; the Python audit’s `--list` remains its nine-file import scope and `--format-list` prints the union. The script never recursively rewrites a source tree. The named existing Document/Canvas/DiagramOperations state paths are formatted deliberately alongside the new files. `SWIFT_FORMAT_BIN` can select a toolchain binary; otherwise the script uses xcrun/swift-format.

Run:

```sh
python3 scripts/check-foundation-boundaries.py
python3 -m unittest scripts.tests.test_foundation_boundaries -v
scripts/check-foundation-format.sh --fix
scripts/check-foundation-format.sh
```

After all owners froze source, the expanded 25-file formatter fix and strict lint passed. The semantic integration is commit `aa6ff78`; the critical-path formatting is separate commit `4c423bc`. The import audit and seven Python audit/scope/module-boundary regressions passed; the consumer-symbol audit found no missing infrastructure imports, and `git diff --check` passed. The earlier unformatted snapshot produced 681 diagnostics in `build/m1-evidence/foundation-format.log`; that log is retained as pre-fix evidence, not the final check outcome. Final child command results are recorded in `build/m1-evidence/foundation-boundary-format-summary.json`. No source was reformatted during a compiler read. Full Swift validation remains owned by the parent; formatting and import checks alone do not establish milestone acceptance.

## Developer command dispatch

`DeveloperCommands.swift` contains the existing tooling CLI blocks moved into `dispatch(arguments:)`, while leaving the production bootstrap in `main.swift`. It has no top-level side effect and no AppDelegate/global-application symbol. The integrated main entry point now invokes this dispatcher after application/appearance initialization.

The integration retains process-local launch-check preferences, appearance argument handling, `NSApplication.shared`, activation policy and `EditorAppearance.apply()` in main. The extracted command blocks are replaced by:

```swift
try DeveloperCommands.dispatch()
```

AppDelegate creation, assignment and `application.run()` remain after dispatch; `--benchmark-sample` is handled only by the dispatcher. A recognized option with missing operands now prints usage and exits 2; unknown/system options remain available to normal startup. Existing command success/failure exit behavior remains.

The three headless document operations use an exhaustive `HeadlessOperation` and synchronous `processDocument` helper. Output is written through `AtomicJobOutput`, with source-path exclusion and a cancellation token, so a failed conversion/render leaves an existing destination intact. This is a CLI output guarantee, not a claim about fault recovery or new background execution. New tests cover usage rejection, source-preserving complete conversion, failed-output preservation, source-as-destination refusal, pre-cancellation and staging cleanup. Swift test execution remains owned by the grouped build.

## M0 evidence integration scope

The collector, its tests and `docs/evidence/INSTRUMENTATION.md` originated from M0 commit `3c22d00`; M1 adds counters/hooks at retained-runtime boundaries. Corpus generator/runner/tests/docs use `81f6140`, including the correction retaining optional overall adapter failures. BenchmarkProfile/adapter/tests/docs originated at `fc69ccb`; M1 now dispatches owned synthetic events through the NSApplication queue/window responder chain, scrolls offscreen targets into view, and waits for asynchronous native calculation. The 20 corpus/adapter Python tests passed locally. No Swift build was run by this child.

`INSTRUMENTATION.md` records the M0 baseline and verification history; its old broad-render statements must not be read as the current retained implementation or current M1 acceptance. M1 needs counters at its new actual preparation/cache/query boundaries. In particular, `visitedObjects` continues to count only nodes entering the engine evaluation loop; it excludes comparison, filter, index and host-building scans. Missing counters/stages remain unobserved. Retained scene preparation cannot be inferred from an old ordered-node input count, and total input comparisons must not be hidden inside a claim about bounded semantic evaluation.
