# M1 delivery contracts and child slices

Planning baseline: `7c270124993bac09967109f95e603ebb47bd98ff`. All qualification claims remain open until evidence is recorded. Public Visio qualification remains owned by M0/M3.

## WP-05 committed state

Save/autosave captures committed geometry. Pointer/resize/control previews belong to the canvas, are never encoded, and Escape discards them. Inline text keeps the existing explicit commit-on-save policy. Mouse-up/page-switch commits one transaction. An incompatible concurrent command invalidates the preview instead of restoring an old document.

Save acknowledgement belongs to the snapshot captured when a queued save actually starts. A newer edit remains dirty. Undo returns the prior state identity, including a previously saved state. Save-copy does not acknowledge the current destination. Failed writes retain the previous saved token and destination.

L children, recorded before implementation:

| Parent | Bounded children and acceptance |
| --- | --- |
| WP-05-T02 | a: canvas-owned geometry preview and Escape regression; b: one mouse-up transaction and stale-preview rejection; c: committed geometry save/autosave plus text commit policy |
| WP-05-T03 | a: state tokens survive undo/redo; b: snapshot acknowledgement is independent of AppKit callback timing; c: queued/failing/save-copy transitions retain exact identities |
| WP-05-T04 | a: invalid/write destination failures preserve file; b: autosave preview and external writer conflict tests; c: recovery checkpoint/reopen evidence |
| WP-06-T02 | a: ID/hierarchy/adjacency ownership; b: atomic updates for structural edits/undo; c: bounded property-edit updates |
| WP-06-T03 | a: conservative spatial buckets; b: draw-order hit/marquee equivalence; c: spatially local snapping with explicit policy |
| WP-06-T04 | a: typed change sets from committed edits; b: common command integration; c: selection/view events bypass calculation |
| WP-07-T01 | a: dependency inventory; b: local references/cycles; c: dynamic/volatile conservative fallback |
| WP-07-T02 | a: bounded expression cache; b: semantic host identity; c: cross-page/text cache invalidation tests |
| WP-07-T03 | a: changed-page/shape closure; b: field/context propagation; c: reused gesture diagnostic baseline |
| WP-07-T04 | a: revision-owned jobs; b: cancellation/stale rejection; c: AppKit ownership audit |
| WP-08-T01 | a: prepared scene identity; b: shared screen/output layer policy; c: route/background context identity |
| WP-08-T02 | a: dirty-region candidate queries; b: lightweight overlays; c: work-count assertions |
| WP-08-T03 | a: path/text/resource budgets; b: route obstacle invalidation; c: repeated-cycle bounded growth |
| WP-08-T04 | a: persistent inspector/page controls; b: per-page view state; c: reusable library presentation/mixed values |
| WP-09-T01 | a: bounded job/snapshot ownership; b: cancellation/stale rejection; c: shared workflow integration |
| WP-09-T02 | a: legacy/template open; b: library loading; c: atomic export with progress/cancel |
| WP-09-T03 | a: saved archive/binding rebase; b: revision compatibility; c: repeated opaque-part preservation |
| WP-09-T04 | a: decoded-image budget; b: undo bounds; c: twenty-cycle memory/resource evidence |

WP-05-T01 baseline evidence: the existing timer-driven `AsyncDocumentSaveTests.testNativeSaveUnblocksMainAndWritesCapturedDiagramSnapshot` remains intact; the new native event regression captures Save before Escape. Suite runs and boundary traces must be retained; isolated reruns cannot close the historical intermittent failure.

## WP-05 initial evidence

- Baseline release suite: 454 tests, 13 optional installer/reference skips, 0 failures (`build/m1-evidence/baseline-suite.log`). This green run does not dispose of the historical intermittent defect.
- Native event regression fails on the baseline: committed node (100,100), saved node (140,140), Escape restores (100,100) while clean (`gesture-before.log`).
- After preview/state identity change: 60 focused tests pass, one optional installer fixture skipped (`wp05-focused.log`). Includes the retained timer-driven async save, overlapping saves, invalid writes, geometry/control/group undo, explicit snapshot-before-AppKit-token edit, and undo/redo through saved identities.
- The deterministic boundary test demonstrates and covers a snapshot/token ordering hazard; it does not prove that this was the only cause of the historical suite-context failure. Final acceptance still requires retained repeated full suites and lifecycle/recovery tests.
