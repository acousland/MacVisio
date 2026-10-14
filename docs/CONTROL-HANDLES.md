# Control handles

Version 0.16 imports named rows from the public VSDX `Control` section. ShapeSheet references retain the `Controls.name.X` spelling. `Prompt` holds the tooltip text; the draft `Controls` section and `Tip` cell aliases remain readable for older local files. This distinction was verified against the actual installer libraries and Microsoft's [row schema](https://learn.microsoft.com/en-us/office/client-developer/visio/row-element-controls-sectionvisio-xml) and [Tip reference](https://learn.microsoft.com/en-us/office/client-developer/visio/tip-cell-controls-section).

## Implemented behavior

- A selected, unlocked shape displays yellow diamond handles at the calculated local position, including rotation and reflection. Hidden handles stay hidden. Cached tooltip text is shown.
- Dragging adjusts editable axes while retaining locked axes. Proportional, minimum-edge, center and maximum-edge behavior survive resize; hidden variants retain those rules. See Microsoft's [behavior definitions](https://learn.microsoft.com/en-us/office/client-developer/visio/x-behavior-cell-controls-section).
- `SETATREF` follows same-page targets, including cross-shape references, multiple destinations and chains of up to ten references. Assignment expressions can use the dragged value through `SETATREFEXPR`, and `SETATREFEVAL` materializes a subexpression. Original redirect formulas remain intact. Active IF/IFERROR branches are processed; guarded, locked and circular destinations reject the transaction. Stored-input markers outside the assignment template update separately. These functions are also recognized by the numeric/typed evaluators. See Microsoft's [SETATREF documentation](https://learn.microsoft.com/en-us/office/client-developer/visio/setatref-function).
- `BOUND` retains its range expression while its input changes. Inclusive, excluded and disabled ranges, ignored ranges and multiple ranges are calculated. Excluded endpoints use the nearest finite representable value outside the ranges; exact Microsoft boundary/tie behavior remains unverified. See Microsoft's [BOUND documentation](https://learn.microsoft.com/en-us/office/client-developer/visio/bound-function).
- **Shape > Control Handles** adds, renames, edits and removes rows. **Shape > Control Cells** edits coordinate, anchor, behavior, glue and tooltip cells. Existing units and opaque cells are retained. Renaming rewrites recognized local and cross-sheet references while preserving quoted text. Indexed aliases and opaque action/string references are not comprehensively rewritten.
- The document commits a drag or dialog edit through Undo/Redo. Escape restores the drag snapshot. Failed drags restore it and display the error in the status area.
- Public VSDX saves retain formulas and minimally patch existing rows. Inherited control definitions merge local overrides, remap inherited sheet references and retain master parts. Removed inherited rows receive tombstones. Renamed inherited rows become local definitions with the old row tombstoned.
- Older native metadata missing controls is hydrated from retained public XML while native object identities remain unchanged. Cross-scale insertion materializes coordinate caches and retains behavior modes.

## Evidence and limits

Twenty-four control regressions cover model calculation, constraints and redirection, public XML round trips without private metadata, opaque parts, deletion/rename, master overrides, metadata hydration, native editor transactions, in-process canvas drags and Escape, Undo and cross-scale insertion. The installer Parallelogram test imports `BASIC_U.VSSX`, drags its actual BOUND-controlled handle, verifies changed geometry and publicly reopens the result.

The raw installer audit finds 11,623 Control sections, 17,769 rows and 121,849 cells, including unused template masters. These raw counts differ from effective imported instances. All names pass the current row-name checks. [Raw audit](raw-control-audit.json) includes the formula function inventory; this is a coverage inventory rather than proof of all stencil behavior.

The final packaged import scan passes all 856 libraries and retains 13,740 effective controls across 606 files. The unchanged totals of 12,108 masters and 80,465 shapes and zero curve warnings establish that importing controls did not regress this corpus. They do not establish that all 13,740 handles behave like Microsoft Visio.

`Examples/Controls` provides before/after public drawings and a native editor render. Binary VSD contains saved calculated graphics and native metadata, **not complete public binary control definitions, formulas or glue semantics**. Its changed public geometry is checked through the bundled independent reader.

Required work remains: full ShapeSheet and string/text/context functions, live tooltip expression evaluation, anchor dynamics, control gluing, actions/events, complete master updates, exhaustive rename references, strict public schema coverage and Windows workflow comparison. Manual external UI interaction and Microsoft Visio acceptance remain unverified. Full Visio parity is not achieved.
