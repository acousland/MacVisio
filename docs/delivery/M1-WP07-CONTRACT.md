# M1 WP-07 calculation contract

State: implemented; the 24 owned calculation/native-async tests pass in grouped run 7. Full M1 acceptance still requires the parent-run complete suite and broader lifecycle disposition.

## Bounded children

- T01a: enumerate explicit cell, shape-text, parent, page, background and document-field dependencies; classify unknown/dynamic/volatile hosts conservatively.
- T01b: compute node dependency closure; keep cycles within the evaluator's existing diagnostic/cache-retention rules.
- T02a: retain bounded compiled expressions keyed by exact source and parser limit. Never share resolved values across immutable page contexts.
- T02b: retain page dependency indexes in a document-owned session with semantic identity; invalidate changed formula/source identities and page/archive context.
- T03a: skip unrelated geometry nodes and field nodes/pages; localize convergence while retaining diagnostics.
- T03b: capture the committed control-gesture diagnostic baseline without evaluation. Pointer events preview the handle overlay; solve control geometry once on release, then commit one transaction.
- T04a: audit AppKit text measurement and execution ownership; keep each text/font/layout record on the main thread through ShapeTextMeasurementService while numeric/string/geometry evaluation stays on its owned worker.
- T04b: expose calculation input identity/cancellation checks for the shared lifecycle job gate; application remains the document owner's responsibility.
- T05a: compare full/incremental state and diagnostic results on dependencies, fields, groups, unsupported functions and cycles.
- T05b: assert actual context, cell/formula, geometry-node, field-node and pass work counts.

## Dependency and fallback policy

The immutable page host resolves local cells, `Sheet.N!` references, `ParentShape!`, explicit text references, connection/geometry/control/User/Property cells and implicit parent transforms. The dependency index includes all formula branches, so changing an inactive branch remains safe. Groups add parent-to-child edges. No resolved cell value survives a new page snapshot.

Page metadata/theme/scale/sheet changes, archive/master/binding changes, removed/reordered ordinal identifiers, malformed formulas, unknown/dynamic functions and unresolved public references select conservative full-page geometry calculation. Known volatile formulas run on every calculation request. A page with retained unstructured diagnostics recalculates fully when changed because dropping provenance cannot prove an unrelated issue should disappear. Untouched pages retain their diagnostic baseline. Existing depth/operation/cycle bounds preserve source formulas and cached values on failure.

Fields additionally depend on foreground/background metadata, foreground page order/count and a single calculation-request `now`. Field contexts never reuse values across pages, foreground contexts or clock requests. Volatile fields are selected every request. Unknown/dynamic field functions force the field page to run and preserve cached display on failure.

The dependency index and diagnostic baseline are runtime state, never public serialization. Compiled expressions are context-free and bounded. Work counters distinguish index construction/scanning from actual evaluation; no claim is made that the fallback comparison adapter removes all O(n) input comparison work. The WP-06 change-set path is the boundary for avoiding that comparison in future callers.

## Preview and execution policy

Selection, zoom and all native gesture preview events do not calculate. During a control drag, Canvas updates the handle overlay only. Release submits one transaction request against the frozen committed baseline; large drawings perform control preparation and semantic settling on the owned worker before committing. Escape discards the overlay without calculation. The calculation helper retains an explicit preview API for callers/tests, but Canvas does not call it during pointer updates. There is no exception to AC-02.

AppKit `NSTextStorage`/`NSLayoutManager` and font selection remain main-thread owned. ShapeTextMeasurementService marshals one immutable text-measurement record at a time from the owned evaluator worker to main, with cancellation checks before enqueue, at execution and after the record. Each record is nonpreemptable; main-thread record counts and maximum duration are measured. The main thread does not wait for the overall calculation job. Data-only rich-text synchronization and numeric/string/geometry evaluation stay on the worker. Long calculations carry revision identity and cooperative pass/page/node/cell-reference cancellation boundaries.

## Implemented interfaces and work evidence

`DiagramCalculation.recalculate` accepts a retained `CalculationSession` and exact `DocumentChangeSet`. Every subsequent convergence pass propagates the IDs actually changed by geometry/fields; it does not compare the complete output diagram to determine convergence. Sessions update source signatures and immutable host maps by changed IDs. Dependency signatures retain all references/functions/branches while ignoring numeric literals, so dragging a stored numeric control expression does not rebuild the graph. Archive/source changes and structural ambiguity retain conservative rebuilding. Compatibility callers without a change set retain explicit comparison work.

`Result.work` records geometry passes/pages/nodes, field pages/nodes, cell requests, uncached cells, typed/field formula evaluations, separately counted default-pin formula attempts, text measurement calls, contexts, graph construction, source comparisons, host preparation, fallback input comparisons and selected rich-text nodes. M0 `PerformanceEvidence` additionally records the calculation span, actual uncached context cells and evaluated geometry objects. These counters do not claim every memory allocation or CoW copy is eliminated.

`ControlEditing.prepare(input, geometryIssuesByPage:, session:)` forks an already committed baseline without evaluation. Native gestures retain that baseline, update only presentation state during pointer events, and use `adjustControlInEditor` on release. Large drawings run the control solve through the request's worker preparation closure; the generic settling path preserves existing diagnostic/geometry behavior and commits once. The compatibility helper accepting both input and baseline validates their equality and reports that comparison. Full document validation remains at the commit boundary; control writes and geometry evaluation retain existing finite/range bounds.

`ShapeRichText.synchronize(...changes:session:onNodeVisits:)` updates changed existing nodes using retained indexes, with reported fallback visits. `synchronizeCalculation` accepts selected IDs and exact node indexes from the evaluator.

`CalculationJobs.evaluate` is an immutable-input API using `LifecycleJobInput` and cooperative cancellation at pass/page/node/cell-reference boundaries. Its output must pass `accepted(ifCurrent:)`; owner, snapshot identity and revision all participate. Numeric/string/field/theme/vector calculation runs on the worker with a request-owned session. Explicit `TEXTWIDTH`/`TEXTHEIGHT` uses ShapeTextMeasurementService to execute only each AppKit record on main; execution policy inspection remains available to qualify which inputs need that service. Ownership, worker/main equivalence and cancellation tests cover the API. The parent owns integration with document pending-edit state, supersession, undo and final result publication; the API alone does not claim those UI acceptance contracts.

## Qualification meaning

Incremental/full equivalence compares two paths through the existing supported evaluator. It proves invalidation and cache behavior for those fixtures; it does not establish Windows/Visio semantic parity or expand supported function claims. Unsupported functions/cycles retain their existing source formulas, cached values and diagnostics. The 40/4000 scale test measures warm local work with explicit change sets; initial load, structural rebuilding and compatibility-adapter diff construction are measured separately and remain conservative.


## Native pending selection and control release follow-up

The async request captures weak references to each attached editor and its committed page/node/edge selection. Cancel/error restores that selection only if owner, snapshot identity and revision still match, the editor is still attached, no newer request is pending and the active page still matches. A newer committed edit keeps its own selection. Submission failures defer restoration until the command has returned and posted its provisional selection.

Control baselines created by the document carry exact input identity. Native control release and the controller's direct control command both use `adjustControlInEditor`. For large drawings, the worker first solves control redirections/geometry with cooperative cancellation, then runs the existing semantic settling contract. Preparation work is included in the accepted result's counters and has an explicit calculation span. Small drawings retain synchronous behavior. This preserves one commit/undo and pending-save semantics; it does not claim a single evaluation pass or bounded whole-commit source diff construction.

## Save finalization boundary

A Save request that starts a new owned calculation while finalizing active inspector/inline text waits for that exact calculation before capturing its snapshot. Save admission stays occupied, preserving the existing bounded request queue. A current accepted text result applies its one transaction first; only then does the held Save recheck the source version and capture the new committed state. Cancellation, supersession, worker/admission failure, or document close completes the held Save with an error before snapshotting or writing. Requests queued behind a failed held Save continue through normal admission. A calculation already pending when Save begins retains the committed-snapshot rule. Direct synchronous serialization that itself starts asynchronous text finalization throws instead of returning the prior text.

A close request that itself starts asynchronous text finalization similarly retains one continuation keyed to the calculation ID, including the original delegate, selector and context pointer. Success applies accepted text before resuming AppKit's close policy; cancellation, failure, supersession or direct document close reports `shouldClose = false` through the standard Objective-C delegate ABI. Additional close attempts receive an immediate refusal rather than building a retained queue. This does not manufacture a semantic revision or force a large calculation onto main. Calculations pending before a close request keep the prior close policy.

An ordinary calculation result also reconciles current page presentation when its calculated active page is still the input page. Presentation-only activation preserves semantic identity and must not be overwritten by the captured worker snapshot. A command that explicitly requested a different active page retains that target; a current page absent from the result is not adopted.
