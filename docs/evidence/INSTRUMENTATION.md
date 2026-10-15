# Product performance evidence contract (schema 1)

`PerformanceEvidence` provides opt-in, process-local aggregate instrumentation.
Ordinary app launches do not start a run. A runner calls `beginRun`, performs the
work, then calls `endRun` with its returned ID. Overlapping runs are refused rather
than resetting evidence. The existing `--profile-open` and `--profile-interactions`
commands now include an additive `instrumentation` object in their JSON reports.
Keep the original operation results and errors alongside this object.

Only typed stage names, random run IDs, counts and monotonic durations are
retained. No filenames, document/shape IDs, text, formulas, paths or image bytes
are accepted by this collector. The global collector includes activity from all
threads in the process: use an isolated synthetic qualification run with no
unrelated document activity. Collection adds synchronization and signpost cost;
compare equivalent instrumented conditions and keep absolute latency qualification
on named controlled hardware.

## Stages and boundaries

The object maps `stages` to observed summaries: `count`, `totalSeconds`,
`maxSeconds`, `samplesSeconds`, and `droppedSamples`. Times are seconds, not
milliseconds. Spans are inclusive and can nest; adding them does not produce a
pipeline total. Each explicit span has paired Instruments signposts in
subsystem `com.macvisio.qualification`, category `PerformanceEvidence`.

| Runner phase | Instrumented boundary |
| --- | --- |
| `open` | Document data/URL read; direct reader in open profiling. Nested native URL/data reads can both appear. |
| `event` | Canvas mouse down/drag/up and key handling, including inline-text key handling. Programmatic commands are not UI events. |
| `commit` | Existing `applyCalculated` call, including guard/no-op handling, undo registration and refresh. Calculation happens before this boundary. |
| `calculation` | Top-level `DiagramCalculation.recalculate`, including text-field settling passes. Direct engine calls do not create this outer span. |
| `textLayout` | Actual shape/edge text measurement during painting and `ShapeTextFunctions.metrics` text layout. Does not include glyph painting. |
| `scenePreparation` | Foreground/background scene resolution and ordered-node preparation. Current code still resolves background fields during scene construction. |
| `route` | A call to `DiagramGeometry.route`, including preserved points, orthogonal work or fallback. |
| `draw` | Canvas paint and export/shared `drawContents`. Includes nested scene/routing/text work; no separate retained renderer is claimed. |
| `snapshot` | Capturing the existing value-model save snapshot. This is a copy-on-write value capture, not a deep serialization. |
| `encoding` | Document format encoding, validation and temporary VSDX package work. |
| `save` | Started NSDocument save through its completion callback; queue waiting is outside this span. |
| `close` | Synchronous `NSDocument.close` call. Profile-mode controller cleanup occurs after report generation and is not claimed as an observed document close. |

A span reports measured elapsed work even if the operation throws. It does **not**
report phase success or compatibility. The adapter must preserve the operation's
actual outcome. Missing keys mean `not_observed`, never zero duration or passed.
A nonzero `unfinishedSpans` invalidates a complete-run claim. No save, close or
real event result may be inferred from the open/interaction profiler's name.

`beginRun(heartbeatInterval: 1.0/60)` additionally schedules a timer on the real
main queue. `mainLoopGap` samples are nonnegative delay beyond the requested
interval between delivered heartbeats, in seconds. `heartbeatSamples` records
deliveries; Instruments receives `mainLoopHeartbeat` events. This is a scheduling
probe, not the duration of an individual input event or every run-loop iteration.
A synchronous profile that never yields to the main queue may produce no samples;
that is missing responsiveness evidence, not a zero-gap result.

Raw stage samples are capped at 10,000 per stage to bound memory. Total count,
total duration and maximum remain complete. `droppedSamples > 0` means raw-sample
percentiles cannot represent the entire run. For p50/p95/max qualification, retain
at least 30 independent runner samples per fixture/cache condition and do not
substitute nested per-item samples for end-to-end operation samples.

## Work counts

Counts describe executed work, not fixture size or unique document objects.
Repeated passes count again. A missing counter is unobserved/no increments;
adapters must preserve that distinction when exposing their own schema.

| Counter | Exact meaning |
| --- | --- |
| `visitedObjects` | Nodes entering the ShapeSheet engine's main evaluation-node loop after unchanged-page rejection. Excludes its preflight/filter/index loops and text-field-only visits; this is not a total model-visit counter. |
| `evaluatedCells` | Uncached shape/page cell resolution attempts in `ShapeSheetContext`, after cycle detection. Includes literals/defaults; failures after the increment count as attempted work. Cache aliases/hits do not increment. Excludes standalone/composite/field evaluator paths outside this context. |
| `drawnObjects` | Calls to `drawNode` and `drawEdge`, including submitted objects later clipped by AppKit. Does not count overlays, ruler ticks, or grid dots. |
| `sceneObjectsPrepared` | Nodes supplied to ordered-node preparation, including hidden nodes considered for ordering. Repeated preparation counts again. |
| `routeRequests` | Actual `DiagramGeometry.route` calls, including preserved routes and fallbacks. |
| `orthogonalRouteSearches` | Actual bounded-search function invocations, including failed attempts and retry searches. |
| `textMeasurements` | Actual instrumented text measurement/layout operations; includes empty visible node text. |
| `transactionsCommitted` | Non-no-op `applyCalculated` installations, including undo/redo. |
| `snapshotsCaptured` | Value-model save snapshots actually captured on the main thread. |
| `encodedDocuments` | Successfully completed document encodings; a failed encoding span does not increment. |
| `heartbeatSamples` | Main-queue heartbeat timer deliveries for this run. |

`visitedObjects`, `evaluatedCells`, and `drawnObjects` can be copied directly to the
corpus runner's names with these scope definitions retained. Fixture object counts
remain separate. The runner's `elapsedMs` is seconds multiplied by 1,000, but
aggregate nested stage totals are diagnostic workload durations, not an
end-to-end phase elapsed time. No numerical counter proves semantic acceptance.

## M1 integration and qualification limits

The M1 contract was read from `docs/delivery/M1-IMPLEMENTATION.md` in its managed
worktree. These hooks leave its committed-state, index, retained-scene and job
ownership decisions intact. M1 should move/add hooks at the new actual loop/cache
boundaries and extend counters rather than reusing a broad count to claim bounded
work. In particular, scene ordering is not a retained scene; the current canvas
still submits visible nodes outside a small dirty rectangle. Text-layout/cell
caching and route-cache invalidation are not implemented by this instrumentation.

`PerformanceEvidenceTests` checks disabled behavior, overlapping runs, stale and
unfinished spans, exception boundaries, concurrent exact counts, uncached cell
resolution without document content, page-skipping visit counts, independent
preparation/routing/layout/drawing counts, dirty-rectangle drawing without
calculation, snapshot/encoding separation, and actual main-queue heartbeat
sampling. The dirty-rectangle test exposes count independence and permits later
M1 culling; it does not mark dirty-region performance accepted. Native UI events,
full pipeline cancellation, suite-context saved-state intermittency, controlled
hardware latency/memory, and exact-build Visio acceptance require downstream
runs and remain unqualified here.

## Local verification, 2026-10-16

- `swift test --scratch-path .build/m0-instrumentation -j 2 --filter PerformanceEvidenceTests`: 12 tests passed, zero failures. Retained local log: `build/M0/instrumentation-tests.log`.
- `swift test --scratch-path .build/m0-instrumentation -j 2 --skip-build --filter BinaryVisioTests`: 14 existing tests passed, zero failures. Retained local log: `build/M0/binary-tests.log`. This is a local binary-format probe, not exact-build Visio acceptance.
- `git diff --check`: passed for this slice. No full-suite, controlled latency, memory, or saved-state intermittency qualification is claimed by these focused runs.
- Direct Debug executable smoke on the generated public `objects-100-balanced.vsdx`: both `--profile-open` and `--profile-interactions` exited 0, emitted schema 1 instrumentation and reported zero unfinished spans. Local reports: `build/M0/instrumentation-open-smoke.json` and `build/M0/instrumentation-interactions-smoke.json`. Open observed drawing/routing/preparation/layout; interactions additionally observed calculation and three committed installations. Neither synchronous run observed actual input-event handling or heartbeat delivery, so those stages remain unobserved. These are adapter/output smoke checks, not performance qualification samples.
