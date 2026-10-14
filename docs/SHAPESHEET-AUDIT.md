# ShapeSheet coverage audit

Run the app's `--inspect-calculation` command on a drawing or a directory of Visio documents:

```sh
build/MacVisio.app/Contents/MacOS/MacVisio \
  --inspect-calculation build/Visio2019-Libraries build/shapesheet-audit.json
```

The report counts parsed shape, Geometry, Connection, Control, User, and Property formula cells, separates successful evaluation from failures, records function call frequency, and groups diagnostics by message. Directory mode scans VSD/VSDX, VSS/VSSX, and VST/VSTX files recursively. The formula fixtures in `CalculationAuditTests` remove MacVisio's private metadata before auditing public VSDX output and check that unsupported calls are visible in both the function and failure reports.

The audit evaluates formulas against the imported cached page snapshot. It does not yet enumerate every page, style-sheet, document, master-definition, event, or action cell, and a successful formula evaluation does not prove correct Visio semantics. Load failures appear per file. Use this inventory to choose further documented functions and test them against Microsoft Visio when the QEMU guest has a registered Visio installation.

## Installer scan, October 15, 2026

The packaged **0.20.0** candidate scanned all **856** extracted Visio 2019 libraries and templates without load errors. It found **4,866,729** formula cells: Shape 3,408,368; Geometry 1,233,980; Connection 62,194; Control 66,232; User 89,538; and Property 6,417. These are occurrence counts, not unique expressions. The latest build evaluated **2,069,288**, failed **2,797,441**, and recorded **9,155** parse failures. The report is `build/shapesheet-audit-20261015-theme.json`; earlier reports are `build/shapesheet-audit-20261015-current.json` and `build/shapesheet-audit-20261015-final.json`.

Compared with the pre-fallback report, successful evaluations rose by **4,486** and failures fell by the same amount; the theme-import and selector work adds **3,459** successful evaluations over the earlier post-fallback scan. Supported palette and variation selectors resolve imported RGB colors, and `THEMEPROP("Embellishment"/"MultiFormat")` reads imported variation metadata. The most frequent calls remain `THEMEVAL` (2,455,719), `GUARD` (370,787), `IF` (171,252), `THEMEGUARD` (58,328), `RGB` (57,484), and `INDEX` (19,737). Major remaining diagnostics include unsupported non-palette `THEMEVAL` mappings, `Prop.MatrixSize.Format` (36,976), unresolved `THEMEPROP` selectors (19,138), `OPENTEXTWIN` (22,301), and `_ELLIPSE_THETA` (18,760).

These are imported formula and call occurrences, not counts of formulas executed when Visio opens a drawing; reused or inherited master/style formulas contribute to the totals. `THEMEVAL` still dominates the inventory. The updated report measures theme import and a subset of active palette/variation mappings, but it does not establish Visio behavioral parity or Windows validation.
