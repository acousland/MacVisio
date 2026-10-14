# NURBS and polylines — 0.13

MacVisio now renders saved NURBSTo and PolylineTo geometry instead of substituting an endpoint line for each row. It retains the compound data, including coordinate types, control points, knots and weights. Supported formulas regenerate the saved data after edits, and native Geometry cell editing supports Undo.

NURBS are curves controlled by points, knots and weights. The native renderer evaluates homogeneous B-splines and approximates their spans with cubic segments. It handles degrees 1–25 with finite positive weights and valid nondecreasing knots, within calculation limits. Local coordinates and coordinates relative to Width/Height can be mixed across axes. Polylines render their saved intermediate vertices and endpoint.

Compound expressions support NURBS/POLYLINE, GUARD, SETATREFEXPR, lazy IF/IFERROR, numeric arguments and references to User, Property, geometry and other Sheet cells. Unsupported expressions and cycles report issues and retain the saved compound value. This is a geometry-data evaluator, not the complete typed ShapeSheet language.

Public VSDX exports retain row types, formulas, units and saved data. Source edits patch the changed cells and preserve unknown row cells. Content-only edits also preserve unchanged page-index and relationship bytes. Cross-scale materialization scales absolute compound coordinates, retains relative coordinates and clears materialized geometry formulas.

Experimental binary VSD exports now write public saved NURBS and polyline data records, including weights, knots and coordinate types. Their expressions still reside in native metadata rather than a complete public binary formula representation. Windows resize/recalculation behaviour and open/edit/save acceptance remain unverified.

Version 0.12 native metadata already retained geometry definitions. The 0.13 reader rebuilds older compound path caches from those definitions while retaining native identities and preserved legacy-source segments. Native JSON and earlier binary native metadata receive equivalent cached-path recovery. Metadata predating retained geometry still needs public reimport; that older recovery path does not establish complete native or legacy-source preservation.

Fifteen focused tests cover exact cubic controls, an analytic weighted quarter-circle, nonuniform span continuity, degree 25, a degree-seven curve that bends between quarter samples, malformed data, mixed/signed axes, recalculation and compound references, cyclic/unsupported formulas, public curve bounds in both formats without private metadata, source-cell/part preservation, cross-scale coordinates, native editing/Undo and older-cache/legacy-source recovery. The full suite passes 228 tests.

The [example](../Examples/Curves/curves-and-polylines.vsdx) contains a cubic NURBS, weighted quarter-circle and polyline, with native JSON/VSD/PDF/PNG/SVG companions. An actual installer [Spiral staircase example](../Examples/Curves/Installer/installer-curved-master.vsdx) imports four NURBS rows and produces 34 native cubic commands. Its report includes the source's remaining import warnings; it demonstrates saved geometry, not complete stencil behaviour or Windows equivalence.

The approximation uses degree-dependent samples with adaptive subdivision, a default sampled tolerance of 0.00001 drawing inches, and bounded depth/segment counts. This is not a certified global error bound. Nonpositive weights, singular curves, periodic closure conventions, spline rows, control handles and complete dimensional/function semantics remain unsupported or unverified. The document renderer caps generated commands to avoid unbounded compound expansion; limited previews report a warning.

The packaged installer scan imports all 856 files, but 26 still report NURBS endpoint fallback. Those cases remain required work. The [audit](nurbs-fallback-audit.json) lists affected files and preliminary raw-row findings; it does not resolve inherited cells or prove every fallback's cause.

That paragraph records the historical 0.13 result. The 0.14 effective-row audit resolves those 26 files' 347 failures through serialization-precision handling and local-span evaluation. [KNOT-PRECISION.md](KNOT-PRECISION.md) records the evidence and remaining scope.

Microsoft's [NURBS function](https://learn.microsoft.com/en-us/office/client-developer/visio/nurbs-function) and [row definition](https://learn.microsoft.com/en-us/office/client-developer/visio/nurbsto-row-geometry-section) specify the data and endpoint cells. Its [DrawNURBS method](https://learn.microsoft.com/en-us/office/vba/api/visio.master.drawnurbs) describes compact knots and the supported degree range. The [POLYLINE function](https://learn.microsoft.com/en-us/office/client-developer/visio/polyline-function) specifies relative/local intermediate coordinates. The implementation and tests cover the subset described above.
