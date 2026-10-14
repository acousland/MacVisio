# Native MacVisio implementation plan

The user requires a complete native port of Visio Professional 2019 with reading and writing of **both VSD and VSDX**, and all Visio functions. A working editor milestone does not satisfy that acceptance target. The supplied Windows installer has been inspected and preserved; it contains no source project that can be built for macOS. See [installer findings](INSTALLER-INSPECTION.md).

## Completed implementation milestones

1. Native Swift/AppKit editor: document windows, canvas, library, text editing, geometry/formatting inspector, connectors, undo/redo, clipboard, pages, zoom, printing and exports.
2. Public VSDX import/export and source package preservation: supported edits patch original XML while retaining opaque parts; in-place VSDX document saves and native recovery include original package data.
3. Legacy VSD graphics import through a bundled native libvisio reader. Converted drawings can be edited and saved as real VSDX files. An experimental v11 binary writer now emits native saved graphics/text and checked MacVisio metadata. Unchanged external VSD exports preserve source bytes; changed binary semantics remain incomplete.
4. Expanded editable features: nested groups and transformations, custom paths, images, fonts/text blocks, layers, Shape Data, hyperlinks, cached connector routes, numeric ShapeSheet dependency calculation, VSSX master loading and VSTX drawing creation.
5. Reproducible release packaging, pinned ZIPFoundation dependency, bundled third-party reader/dependencies/licenses, model/editor/interchange tests, real-format fixtures and application render/launch diagnostics.
6. Inherited master-group expansion, partial subshape/row overrides, instance-scoped connections and formula references, minimal local save overrides, deletion tombstones and older-metadata reimport. See [MASTER-INHERITANCE.md](MASTER-INHERITANCE.md).
7. Connector hierarchy across import, transforms, clipboard, layer behavior and both public exporters; cached master ungrouping with retained glue; bounded shape-ID allocation; preservation of equivalent caches and numeric-looking text. See [GROUPED-CONNECTORS.md](GROUPED-CONNECTORS.md).
8. Connection-point rows, names/indexes, cached coordinates/formulas, port-specific VSDX glue, native grid editing/snapping, rename/delete with Undo, inherited deletion and metadata upgrade. See [CONNECTION-POINTS.md](CONNECTION-POINTS.md).

## Required work before claiming the requested port is complete

1. Complete the experimental binary VSD serializer and implement a richer importer with retained semantics. Verify Windows open/edit/save/reopen in each supported Visio generation; complete payloads, expressions, masters, data/glue and original-object edit preservation. The current encoder/graphics converter is not a verified full VSD implementation. See [BINARY-VSD.md](BINARY-VSD.md).
2. Establish a Visio Professional 2019 Windows comparison environment matching the installer build, plus representative user files. Build a feature inventory and test every workflow; compare public file content, rendered pages, save/reopen and editing behavior. A Windows environment was requested as an optional clarification and is not available yet.
3. Complete ShapeSheet, geometry/control handles, master inheritance and instance updates, rich text, backgrounds, themes/effects, connection ports/routing, image/metafile/OLE handling and the installer libraries. Resolve the itemized gaps in [COMPATIBILITY.md](COMPATIBILITY.md).
4. Implement the specialist solutions: diagram semantics and validation, data graphics/linking/refresh, containers/lists, reports, engineering scales/measurement, CAD, org-chart/data import, automation compatibility and integrations.
5. Run differential regression tests on the full fixture/workflow inventory. Complete manual native UI tests, printing/recovery tests, accessibility, performance and supported OS/architecture testing; configure distribution signing/notarization when distribution is required.

These stages require substantial further engineering and validation. The absence of a Windows comparison environment does not prevent continued implementation, but it prevents a substantiated claim of full behavioral and file compatibility. No estimated completion date or full-parity claim is supported by the current evidence.

The 0.12 geometry milestone retains indexed public Geometry definitions and adds supported numeric recalculation, native cell editing/Undo, minimal inherited patches and formula-preserving VSDX output. Experimental VSD exports the calculated public graphics. [GEOMETRY-FORMULAS.md](GEOMETRY-FORMULAS.md) records the tested subset; full dimensional/composite geometry, controls and master updates remain required work.

The 0.8 library milestone decodes and hash-checks all 856 installer assets, exposes a native folder browser, reads binary VSS/VST graphics, writes public VSSX/VSTX and handles cached elliptical arcs, repeated deleted sentinel IDs and unnamed layers. Its historical scan imported 801 libraries with 55 size/signed-dimension failures. Signed group dimensions and scale-aware engineering page coordinates were addressed in 0.9; richer VSD semantics remain required. Full master behavior and specialist template solutions remain required work.

The 0.9 milestone resolves those 55 import failures with signed coordinate origins and paper/drawing scales. The complete 856-file scan passes; native editing/exports and public geometry checks are recorded in [DRAWING-SCALE.md](DRAWING-SCALE.md). Required work remains: typed/full ShapeSheet and geometry evaluation, master updates, rich text/fields, complete binary VSD semantics, specialized solutions and Windows/native workflow comparison. All-library import is a coverage result, not the completion criterion.

## Current milestone checks

- Native editor builds and launches on this Mac.
- Automated tests exercise actual model changes, undo/redo, document persistence and render output.
- Public interchange tests remove private native metadata before reopening.
- Unedited imported external VSDX packages retain part bytes; edited packages retain tested unknown extensions/media/vendor parts.
- Real legacy VSD fixtures convert into editable native shapes and export as VSDX.
- App packaging includes its legacy reader and relocates copied native libraries. The declared deployment floor reflects their actual requirements.

Actual results and testing limits are recorded in [VALIDATION.md](VALIDATION.md). The full user request remains open.

The 0.3 milestone adds CFB FAT/mini-FAT/DIFAT support, native VSD document saving, public v11 saved-value serialization, independent binary-curve/image tests, stale-metadata rejection and original binary-source preservation across native/VSDX recovery. This advances the format requirement without proving the complete port.

The 0.4 milestone adds shared/nested background graphs, native Page Setup/navigation, source attribute preservation, page-coordinate-preserving resize, composed exports/printing and multi-page PDF. Public-format/independent-reader and rendered-output checks cover these additions; dynamic foreground-context evaluation and Windows parity still require further work.

The 0.10 milestone adds native mixed-text editing, indexed character/paragraph imports, master styles, font declaration correction, run-aware public exports and whitespace-safe XML preservation. Seventeen additional tests cover interchange without private metadata, partial formatting, both Undo paths, source/master preservation, Unicode, numeric default-character formulas and repeated saves. Full text fields/layout, indexed/full ShapeSheet evaluation, geometry/master updates, rich binary VSD semantics, specialist solutions and Windows workflow comparison remain required work. See [RICH-TEXT.md](RICH-TEXT.md).

The 0.11 milestone adds live native text fields, typed strings/booleans/lengths/dates, field-preserving editing and VSDX saves, foreground background context and cached public binary field records. Fifteen additional tests exercise real media-template fields, model/editor updates, public/source preservation, references, field placeholders, cached fallback, measured formatting and private-model-free binary parsing. Required work still includes full typed/geometry ShapeSheet behavior, all field formats/functions, binary expressions/data/glue, master updates, specialist solutions and Windows workflow comparison.

The 0.13 milestone adds compound geometry evaluation, positive-weight NURBS/polyline rendering and public saved binary records, with fifteen new tests and an installer staircase example. Unchanged page metadata is retained during content edits, and version-one geometry metadata preserves native identities and original VSD segments during cache recovery. Full geometry/controls, master updates, complete binary semantics, specialist functions and Windows comparison remain required work. See [NURBS-GEOMETRY.md](NURBS-GEOMETRY.md).

The 0.14 milestone resolves the 26-file NURBS fallback corpus: all 347 effective failures were serialization-precision mismatches. Local-span evaluation preserves distinct close knots, and full-precision compound cache serialization supports longer materialized data without expanding authored-formula limits. Geometry metadata versions one/two recover to the current cache version. Required work still includes complete curve/control/function semantics, spline rows, master updates, specialist solutions, binary expressions/data/glue and Windows validation.

The 0.15 milestone implements spline sequences using their control points, knots and degree, preserves public row definitions and exports saved binary records. Ten additional tests exercise geometry, formulas, preservation, public parsers, malformed data, Undo, scale and cache recovery. Complete periodic/control/function/master semantics, specialist solutions, richer binary import/export and Windows/native workflow validation remain required work.

The 0.16 milestone adds yellow native control handles, transactional row/cell editing, constraints, BOUND and SETATREF calculations, master/source preservation and native metadata hydration. Twenty-four new regressions include an actual installer Parallelogram. The raw installer inventory exposes 17,769 control rows and their function dependencies. Full control dynamics/gluing, all ShapeSheet/context functions and master behavior, richer binary semantics, specialist solutions and Windows/native workflow validation remain required work. See [CONTROL-HANDLES.md](CONTROL-HANDLES.md).

The 0.17 milestone connects typed text/property values and native text measurement to geometry and controls, corrects STRSAME, updates text blocks/tooltips, coordinates fields and geometry, restores exact Undo snapshots and extends typed native cell editing. Eighteen regressions include Analytics text-driven controls and staircase implicit-unit formulas. Native paragraph spacing/indents, numeric precision, dimensional aggregates and REF diagnostics are included. Formula audits guide the remaining work. Complete ShapeSheet/text/unit semantics, master/control dynamics, specialist solutions, richer binary semantics and Windows workflow validation remain required work. See [TEXT-CONTEXT.md](TEXT-CONTEXT.md).
