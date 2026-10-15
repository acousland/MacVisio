# ShapeSheet coverage audit

Run the app's `--inspect-calculation` command on a drawing or a directory of Visio documents:

```sh
build/MacVisio.app/Contents/MacOS/MacVisio \
  --inspect-calculation build/Visio2019-Libraries build/shapesheet-audit.json
```

The report counts parsed shape, Geometry, Connection, Control, User, and Property formula cells, separates successful evaluation from failures, records function call frequency, and groups diagnostics by message. A separate `packageFormulaInventory` counts and syntax-parses formula cells across every XML package part, grouped by pages, masters, document/styles, themes, and other parts. This makes formula-bearing content outside the evaluated page model visible without implying that those formulas were executed. Directory mode scans VSD/VSDX, VSS/VSSX, and VST/VSTX files recursively. The formula fixtures in `CalculationAuditTests` remove MacVisio's private metadata before auditing public VSDX output and check that unsupported calls are visible in both the function and failure reports.

The evaluator audits formulas against the imported cached page snapshot. The package inventory now enumerates formula-bearing XML cells in all package parts, but only page-model formulas are evaluated; style-sheet and master formulas still need host-aware evaluation. Events and actions are not formulas and remain outside this audit. A successful formula evaluation does not prove correct Visio semantics. Load failures appear per file. Use this inventory to choose further documented functions and test them against Microsoft Visio when the QEMU guest has a registered Visio installation.

## Installer scan, October 15, 2026

The packaged **0.20.0** candidate scanned all **856** extracted Visio 2019 libraries and templates without document load errors. Its page-model evaluator found **4,866,729** formula cells: Shape 3,408,368; Geometry 1,233,980; Connection 62,194; Control 66,232; User 89,538; and Property 6,417. These are occurrence counts, not unique expressions. The latest build evaluated **2,070,130**, failed **2,796,599**, and recorded **9,155** parse failures. The report is `build/shapesheet-audit-20261015-package-inventory.json`; earlier reports are `build/shapesheet-audit-20261015-theme.json`, `build/shapesheet-audit-20261015-current.json` and `build/shapesheet-audit-20261015-final.json`.

The same scan's syntax-only package inventory found **5,600,988** formula-bearing `Cell` elements across **34,178** XML parts: **2,844,790** in masters, **118,112** in document/styles, **81,949** in pages and **2,556,137** in other XML parts. It parsed 5,595,960 formulas, recorded 5,028 formula parse failures, and encountered 20 malformed XML parts. These package totals include formulas not evaluated by the page model; they cannot be compared directly with evaluated-cell totals because masters and styles are counted as source records rather than instantiated shapes. The most frequent raw package calls are `GUARD` (771,117), `THEMEVAL` (535,238), `IF` (422,848), `THEMEGUARD` (101,501), `RGB` (89,941), `LUM` (79,650), `NOT` (77,260), `SETF` (68,909) and `GETREF` (62,921).

Compared with the pre-fallback report, successful evaluations rose by **4,486** and failures fell by the same amount; the theme-import and selector work adds **3,459** successful evaluations over the earlier post-fallback scan. Supported palette and variation selectors resolve imported RGB colors, and `THEMEPROP("Embellishment"/"MultiFormat")` reads imported variation metadata. The most frequent calls remain `THEMEVAL` (2,455,719), `GUARD` (370,787), `IF` (171,252), `THEMEGUARD` (58,328), `RGB` (57,484), and `INDEX` (19,737). Major remaining diagnostics include unsupported non-palette `THEMEVAL` mappings, `Prop.MatrixSize.Format` (36,976), unresolved `THEMEPROP` selectors (19,138), `OPENTEXTWIN` (22,301), and `_ELLIPSE_THETA` (18,760).

These are imported formula and call occurrences, not counts of formulas executed when Visio opens a drawing; reused or inherited master/style formulas contribute to the totals. `THEMEVAL` still dominates the inventory. The updated report measures theme import and a subset of active palette/variation mappings, but it does not establish Visio behavioral parity or Windows validation.
