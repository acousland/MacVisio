# M1 WP-09 delivery slices

Owner: M1 lifecycle subagent, 16 October 2026. Status: design and isolated implementation in progress; no package acceptance claimed. Existing public Visio preservation, NSDocument bookkeeping, undo-to-saved behavior and source IDs remain required regressions. WP-05/WP-06 supply the committed snapshot and change-set contracts; lifecycle work must consume them without introducing a second editable model.

## Bounded children before implementation

| Parent | Child | Deliverable and acceptance | Requirements |
| --- | --- | --- | --- |
| WP-09-T01 (L) | T01a | Foundation-only bounded worker service: explicit job/owner/snapshot/revision IDs, queue admission, progress and cancellation. Deterministic blocking-work tests prove the worker/outstanding limits and main-thread delivery. | MV-UX-08, MV-AUT-02, MV-NFR-03/04 |
| WP-09-T01 | T01b | Owner lifecycle and acceptance gate: cancellation before start, during work, after work/before delivery, closed owner and superseded input cannot install results. Completion occurs once with structured disposition. | MV-DOC-04/05/10, MV-NFR-03/05 |
| WP-09-T02 (L) | T02a | Route VSD/VST/VSTX and native/VSDX opens through the service while retaining NSDocument source bookkeeping and template-as-new semantics. Deduplicate pending source opens and retain completion callers. A main-run-loop heartbeat continues during blocked input. | MV-DOC-04/05, MV-IO-03, MV-NFR-03 |
| WP-09-T02 | T02b | Cancel-aware bounded legacy process reader: terminate subprocess, bound bytes/time, remove temporary resources, classify cancellation. Test a controlled helper without requiring the optional bundled converter. | MV-IO-03, MV-NFR-05/06 |
| WP-09-T02 | T02c | Owned library/stencil loading, template export, selection-stencil export and ordinary exports. Capture the committed snapshot before submission; publish complete results on main; stage destination writes and replace atomically only after cancellation check. AppKit drawing/text operations need an explicit audited execution policy. | MV-UX-08, MV-DOC-10, MV-IO-03, MV-NFR-03/06 |
| WP-09-T03 (L) | T03a | Return the archive/bindings actually written from preservation serialization. Preserve public entry points, stable node/page IDs, opaque parts and useful source slices. | MV-DOC-05/10, MV-IO-03 |
| WP-09-T03 | T03b | Save artifact carries save ID and exact committed input identity. Rebase only compatible source state after successful atomic save; keep newer pages, undo history and dirty identity intact. Tests cover repeated save, new objects, edit during save, failed save and Save As/Save To policy. | MV-DOC-05/10, MV-NFR-05/06 |
| WP-09-T04 (L) | T04a | Deterministic count/cost LRU with explicit image/path/text budgets and decoded-pixel accounting. Oversized entries are not retained. Report occupancy/eviction counters. | MV-NFR-04/05 |
| WP-09-T04 | T04b | Immutable source/resource identity outside editable equality, preserving Codable format and source patch ownership. Test unchanged resource identity through snapshots and rebases; serialized interchange remains unchanged. | MV-DOC-10, MV-NFR-04/05 |
| WP-09-T04 | T04c | Undo count/cost policy wired to actual history behavior; measure twenty open/edit/save/close cycles plus long history, cache occupancy and process resident memory. State both deterministic retention limits and measured whole-process effects. | MV-DOC-10, MV-NFR-04/05/06 |
| WP-09-T04 | T04d | Measure metadata envelope detection/duplicate decode; decode only the envelope format discriminator before the normal model decode, retaining malformed/unsupported/segmented input regressions. | MV-NFR-03/04/05 |
| WP-09-T05 (M) | T05a | Document and test CLI exit/error contracts, input/output identity safety, atomic output on helper/export failure and interruption. Record lifecycle evidence and limitations. | MV-AUT-02, MV-IO-03, MV-NFR-05/06 |

## Interfaces

`LifecycleJobInput` identifies owner UUID, committed snapshot UUID and revision. `LifecycleJobHandle` owns cancellation; `LifecycleJobContext` supplies checkpoints, progress and cancellation-handler registration. `LifecycleJobService.submit` admits at most 32 outstanding jobs and runs at most two; it delivers progress/completion on main and rechecks cancellation and owner/input compatibility there. The operation receives captured values, never a mutable document. Queue rejection, cancellation and stale input are distinct errors. Owner close cancels its active handles.

`AtomicJobOutput` writes to a unique sibling staging URL. The writer cannot overwrite its input; successful validation/cancellation checks precede atomic replacement. Cancellation/failure removes staging data and retains an existing destination.

`ResourceBudgetCache` is a deterministic count-and-cost LRU rather than an advisory cache. Costs describe retained decoded resources (for raster images, at least width × height × four bytes), not compressed file length. Snapshot/undo policies must account separately for shared immutable resources and editable payload; estimated costs are not claimed as measured resident memory.

Preservation serialization should return a `VisioDocumentArchive` containing written package parts and updated page bindings. The save coordinator installs this source baseline only for the matching save artifact and source lineage. It must never assign saved pages over live newer edits or use rebasing to acknowledge a newer dirty revision. Newer compatible edits can use the rebased baseline because binding originals continue to describe the exact saved snapshot.

## Current acceptance gaps

- Implemented lifecycle paths and measured grouped-run results are recorded in `M1-WP09-EVIDENCE.md`. The parent owns the final complete grouped run and disposition of all failures.
- The second stale-window appearance regression, corrected untitled recovery autosave fixture, external-writer guard and fresh-process checkpoint test await the next grouped run.
- Local recovery initialization and explicit CLI checkpoint reopen do not establish installed-app/macOS restoration. That acceptance must be recorded separately.
- Metadata fingerprints detect ordinary external writes; they are not a content hash and cannot exclude an uncoordinated writer racing after the final check.
- Worker ownership, cache/undo charges and twenty-cycle RSS have explicit scope and oversized/current-action exceptions; they are not a total-process memory cap or a proof of absence of leaks.
- No Windows Visio acceptance is inferred from lifecycle tests, native equality, public parsing or metadata round trips.

## Ownership and integration

During foundation work this agent owns new lifecycle/resource files and tests plus this note only. Protected shared files (`Document.swift`, `CanvasView.swift`, `Model.swift`, `DiagramCalculation.swift`, `Drawing.swift`, `EditorUI.swift`, backlog representations) require coordination before edits. No Git commits or full Swift builds from the subagent while the parent owns the shared index/build lane.

## Implemented contracts awaiting grouped validation

- `LifecycleJobs.swift`, `LifecycleJobOwner.swift`, `LifecycleProgress.swift`: bounded owned jobs, progress/cancel, stale delivery gate, window-close cancellation and replaceable requests. Native/VSDX/VSD/VST/VSTX document opening, library scans and stencil loading use that path. Cancellation checkpoints reach OPC entries/chunks, stencil masters, public page import and legacy conversion.
- `LegacyConverterProcess.swift`: configurable 30-second default and 64 MiB output cap; cancellation interrupts pipe reads and SIGTERM escalates to SIGKILL after 250 ms for an uncooperative helper. Controlled helper tests cover timeout/cancel/status/output limits.
- `AtomicJobOutput.swift`: unique sibling stage, cancellation before replacement, atomic same-volume rename and canonical input/output alias guard. Failure removes the stage and retains the valid destination.
- `VisioFormat.writeRebased`/`VisioPreservation.writeRebased`: return exact written parts and allocated bindings while keeping existing `write` APIs. NSDocument's prepared save artifact installs this baseline only after a real successful save and compatible source identity; semantic/revision/runtime state and newer pages remain live. Recovery autosaves acknowledge a separate recovery identity. Undo carries the latest compatible source baseline.
- `DocumentSourceVersion`: captured source metadata identity is checked when each same-source save starts, at safe-write entry and around serialization against AppKit's original-contents URL. External changes produce a typed conflict with existing Revert to Saved/Save As recovery instructions; failed writes preserve the tracked baseline. Revert resets saved/recovery identity, calculation/runtime state and stale undo history. New destination copies remain allowed.
- `VisioDocumentArchive` retains immutable source parts behind a shared identity fast path; existing Codable keys and value equality remain compatible. This avoids traversing shared package bytes during equality and does not claim eager copies were previously occurring.
- `NativeMetadataStorage` decodes an envelope format header rather than materializing an entire `[String: Any]` model before the model decoder. The grouped7 discriminator-only comparison and its limitations are recorded in the evidence note.
- `ResourceBudgetCache` declares 64 MiB/128 decoded images, 32 MiB paths and 32 MiB text. Parent integrated actual image/prepared drawing caches. `UndoPayloadBudget` maintains indexed editable-object retention charges, a 64 MiB ordinary-history charge budget and a separate 100-group NSUndoManager limit. The current action remains undoable if it alone exceeds 64 MiB; that oversized-action exception is explicit and must be reported rather than called a hard allocator cap. Charge uses serialized object bytes × 4 plus inline strides and full source bytes × 4 per action, intentionally overcharging shared immutable storage. It is not exact RSS.
- `ExportJobs.swift` captures owned snapshots, prepares vector records on main in 4 ms/32-step target batches, then performs Core Graphics/ImageIO/SVG assembly and atomic output on bounded workers. FontManager/TextKit/AppKit rendering remain on main. Recorded maxima include individual objects, scene field evaluation and layer setup; a single complex step can exceed the target. Retained recording bytes are capped at 128 MiB. Parent wires UI entry points; package and stencil exports use Foundation serializers on workers.
- New tests cover service ownership/bounds/heartbeat, atomic output, converter interruption, source identity/Codable, save rebasing/recovery, raster cache retention, long undo, twenty actual open/edit/save/close cycles, and owned public exports. The twenty-cycle test emits named-host Mach RSS samples/slope only when `MACVISIO_LIFECYCLE_EVIDENCE_PATH` is set. Whole-process RSS is measured evidence, not proof that no leak exists.

No task/package acceptance is claimed until the parent records grouped compile/test results and resolves failures. The parent owns final backlog status and handoff.
