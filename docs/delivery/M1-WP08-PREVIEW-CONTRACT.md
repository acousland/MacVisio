# Formula-free retained gesture previews

`RetainedRenderScene(previewPage:baseline:previous:)` is the presentation-only constructor for pointer geometry previews. The caller captures the committed `EvaluatedSceneSnapshot` for the gesture and supplies the same snapshot while preview geometry changes. The Canvas owner replaces its normal scene constructor with this call; committed release continues through the existing document calculation/transaction path.

The constructor clones value routes, prepared port positions and route bounds from each evaluated layer. It does not call the committed route/port preparation path at gesture begin. Background pages and their already evaluated foreground-specific text are reused from the committed scene. Preview layers retain the original source page and its formulas for display and future commit.

Each preview layer has a private routing-only page. For a changed node, a committed prepared port is converted through the inverse original transform to a local normalized position, then through the new dimensions, flips and rotation. The routing copy stores that projected position as numeric port cells and clears those cells' formulas. Geometric routing may run against this disposable copy without entering ShapeSheet parsing or cell evaluation. The displayed/committed models are never sanitized or modified. A missing prepared port uses its numeric cached cell values, without evaluating a source formula.

This policy deliberately previews the committed normalized position. A port formula with constant offsets, nonlinear references or external dependencies can have a different exact position after resizing; the exact formula result is calculated on committed release. The preview does not claim to solve arbitrary formulas. Unchanged transforms retain the exact prepared world point. A preview may rebuild disposable spatial indexes or reroute automatic connectors; avoiding semantic calculation does not claim zero geometric work or zero copy-on-write allocation.

Port maps omit nodes with no ports. Route bounds are retained in `EvaluatedSceneSnapshot.Layer`, so a clone restores conservative indexed bounds without measuring/evaluating ports again. A certified root append updates affected automatic/newly attached routes while retaining unrelated straight routes and their bounds; arbitrary structural fallbacks remain conservative.

Grouped-edge geometry uses the committed route table during gestures. `DiagramOperations.transformChildren` and `transformGroupedEdges` accept an optional prepared route table; supplied tables never fall back to the formula-bearing route evaluator. A missing prepared entry uses cached edge points. Normal semantic commands retain their existing routing behavior when no table is supplied.

`PreviewCalculationContractTests` adds five regressions:

- Twenty resize/rotation/flip projections retain source formulas, match geometric expected port positions, and keep parser/cache statistics and semantic counters unchanged.
- Twenty synthesized direct-handler drag/resize/Escape cycles include formula-bearing ports on foreground and background pages. They require unchanged complete `ShapeSheetExpressionCache.statistics`, zero evaluated/visited/committed counts, no calculation stage, and unchanged committed diagram/revision/state identity. This is a responder-handler trace, not hardware input or compositor qualification.
- Resize release matches normal committed calculation, preserves both port formulas, survives native encode/decode and undoes to the committed baseline.
- Twenty grouped drag/resize/Escape cycles exercise parent-owned connector geometry with formula-bearing child ports. They retain the same strict parser, evaluated-cell, calculation, committed-model and revision assertions as the ungrouped cycles.
- Sparse port dictionaries and the bounded root-append path retain an unrelated straight route and its conservative bound.

Source formatting and diff checks passed. The child did not run a Swift build; the parent owns Canvas wiring and grouped test execution. This note records the implementation contract, not a completed M1 acceptance claim.
