# M1 lifecycle and headless operation contract

This documents the implemented local contract. Acceptance results and known failures belong to [M1-WP09-EVIDENCE.md](M1-WP09-EVIDENCE.md); implementation alone does not close WP-09.

## Owned work

Open, conversion, library, export and calculation jobs carry distinct job, owner, snapshot and revision identities. `MacVisioInfrastructure.LifecycleJobService` runs at most two workers and retains at most 32 outstanding requests/results, including results awaiting main delivery. Queue admission fails with `LifecycleJobError.queueFull`. Progress and completion are delivered on main. A cancelled request or rejected owner/input identity delivers a typed cancellation/stale disposition and cannot install the computed model/resource result.

Window-bound library/export owners cancel when their window closes. A later replaceable library scan cancels its predecessor. Ordinary document edits do not invalidate an explicit export snapshot: the completed artifact continues to represent the exact captured input. Its callback updates status only. Document opening retains NSDocument's source bookkeeping; templates become new dirty drawings, while an untouched ordinary source remains clean.

NSDocument retains its prepared asynchronous save path, separate from generic worker scheduling. Saves have exact save/snapshot identities and a bounded serial queue. Closing a document cancels queued saves; an already writing atomic NSDocument save is allowed to finish. A successful real save acknowledges only its captured committed state. Recovery autosave has a separate acknowledged identity. Source rebasing changes no live pages, semantic identity, revision or retained runtime revision; it requires the exact compatible source resource and uses stable source lineage for undo.

The source version records canonical URL, filesystem device/inode, byte count and modification time after a consistent URL read or successful real save. Each queued same-source save checks this baseline when it starts. The safe-write entry checks again; the advanced write override checks before and after serialization at NSDocument's `originalContentsURL`, which may name an original file AppKit has renamed during staging. It never compares the temporary output file against the input fingerprint. A conflict has the typed `DocumentSourceConflict` error and directs the user to the existing File > Revert to Saved or File > Save As commands. A separate destination remains writable. Failed/conflicted saves preserve the baseline and dirty state.

This is ordinary external-change detection, not a content-integrity hash or a lock against adversarial filesystem writers. An in-place writer that preserves inode, byte count and modification time can evade it. A writer ignoring file coordination can race after the last check. Successful revert cancels pending calculation, installs the newly read source, resets saved/recovery identity and clears stale undo/runtime state; reverting while a save is in progress is refused.

For an autosave-in-place subclass, `autosaveElsewhereOperation` represents an untitled document without a permanent URL. It acknowledges its recovery snapshot independently while the document remains edited and requires a user save. Recovery tests must obey that NSDocument operation contract. The explicit unsaved-checkpoint manifest/fresh CLI process test demonstrates local recovery content identification and reopening; it does not demonstrate installed-app restoration registration, OS relaunch UI or macOS recovery-location discovery.

NSDocument enables draft autosaving by default. `autosaveAsOperation` writes a new current file, so it establishes the source fingerprint and acknowledges the captured saved/recovery identity like an ordinary current-file save. Later edits are dirty again and same-source writes use the external-change guard. Automatic draft/in-place writes do not add system paths to application recents; only explicit Save/Save As does so.

The inherited initializer for recovery associated with a different original URL has no persisted source metadata fingerprint in the public document. Its loaded checkpoint fingerprint does not authorize replacement of that original file. Such a same-original save conservatively reports a conflict; Save As to a separate copy remains available. Same-original recovered save acceptance requires an explicit original-baseline contract and is not inferred from the untitled probe.

## Cancellation and destination safety

Jobs check cancellation before work, between bounded input/record steps, before output replacement and again before result delivery. Legacy helpers have a 30-second default deadline and a 64 MiB output limit. Cancellation/timeout requests SIGTERM and escalates to SIGKILL after 250 ms if the helper is still running. Timeout, output limit and nonzero helper exit are separate `LegacyConverterError` cases.

Atomic exports write a unique sibling stage and replace the destination with a same-volume rename only after the complete writer returns and the final cancellation check succeeds. A writer error or observed cancellation before that commit step leaves the existing destination intact and removes the stage. Cancellation arriving after the final check can race the atomic commit; the destination then contains a complete artifact, and result delivery may still report cancellation. There is no partial-destination state. A process killed abruptly can leave a hidden staging file because process cleanup cannot run; no abrupt-termination staging cleanup claim is made.

Canonical input/output path equality, including symlink aliases, is rejected. This protects input source bytes. Existing public format writers and validation remain authoritative for the staged artifact.

FontManager, text layout and AppKit drawing for exports run on main in target batches of at most 32 preparation steps or approximately four milliseconds. Workers assemble immutable PDF records/SVG markup and encode/write complete output using Core Graphics, ImageIO or Foundation serializers. Individual objects, scene field evaluation and layer setup can exceed the target; reported maximum step/object durations expose that limit. Prepared export records are capped at 128 MiB. PNG retains the existing 100-million-pixel output limit; that output bitmap is separate from the decoded-image cache budget.

## CLI results

`--convert INPUT OUTPUT`, `--render-document INPUT OUTPUT` and `--export-all-pdf INPUT OUTPUT` remain synchronous headless operations and use the same staged destination safety. They do not wait on AppKit UI sheets or a generic job's main-thread completion. The code API accepts a cancellation token; the command line does not introduce a new cancellation flag or JSON error-output mode.

| Result | Normal exit status | Observable output |
| --- | --- | --- |
| Complete operation | 0 | Destination contains the complete artifact; success is printed; import warnings remain on stderr |
| Read, validation, helper or output failure | 1 | Localized operation error on stderr; valid prior destination retained when failure precedes atomic commit |
| Recognized option with missing required operands | 2 | Usage on stderr; no fallback into ordinary GUI launch |
| Host terminates process with a signal | Host signal termination | No application completion/cleanup promise; atomic output keeps the destination complete |

Unknown application/system arguments remain available to ordinary bootstrap. Public API errors retain typed cancellation, stale-input, queue-full, source-as-destination, timeout, helper-status and output-limit distinctions. CLI stderr remains human-readable text.

## Retention budgets

The decoded-image cache retains at most 128 entries and a 64 MiB declared decoded/source cost. Prepared paths/text have a combined 64 MiB declared cost and a count bound; retained input payload is part of the prepared-resource charge. These are resource cache budgets, not a total application RSS limit.

Undo retains at most 100 NSUndoManager groups. Its ordinary-history charge budget is 64 MiB, using indexed editable-object encoding costs and conservative source-resource charges; older history is discarded only at a commit boundary, preserving an already open grouping depth and the current action. One action larger than the budget remains undoable and explicitly reports `oversizedSingleAction`. Shared resources are intentionally overcharged. This policy does not equate serialized costs with exact allocator bytes.

Twenty actual open/edit/save/close cycles, a separate decoded-raster loop, long undo/redo and metadata-discriminator timings supply measured evidence. Named-host RSS samples and slope describe the process/allocator/OS observations; they do not prove absence of leaks or qualify Windows Visio behavior.

The nil-source compatibility page set names only the latest successful nil-source snapshot, replacing the prior set and remaining bounded by one input's page count. A successful save whose subsequent metadata stat fails retains its older known baseline and an explicit unverified destination marker; subsequent same-source writes fail closed until a successful reload/save establishes metadata again.
