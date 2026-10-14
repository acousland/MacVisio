# Spline rows — 0.15

MacVisio now calculates SplineStart/SplineKnot sequences as curves instead of drawing their control polygons. It collects the consecutive rows, uses the preceding geometry vertex as the first control point and evaluates their compact knot sequence with the existing B-spline engine. The sequence finishes before another row type or at the end of its Geometry section.

Row indexes, cached cells, formulas, units and unknown cells remain editable and preserved. Supported scalar formulas update spline coordinates and knots after edits. **Shape > Geometry…** edits existing cells with Undo. Cross-scale materialization changes coordinate cells while retaining knots and degree.

Public VSDX retains the original spline row types and definitions. Experimental binary VSD can emit saved SplineStart/SplineKnot records directly. A shape containing another unsupported binary row type continues to export its cached native paths. Complete public binary formulas and Windows edit/recalculation behaviour remain unfinished or unverified.

Ten tests cover exact cubic controls and curve bounds, nonuniform span joins, sequence boundaries/subpaths, resizing and User-cell dependencies, source preservation of units/unknown cells/unchanged parts, public curve bounds without private metadata in both formats, malformed/orphan rows, native editing/Undo, cross-scale coordinates and recovery of older cached polygons. The full suite passes 241 tests.

The curve example now includes a second **Splines** page. The World master exercises 119 SplineStart and 365 SplineKnot rows; its effective NURBS/spline/polyline audit reports zero issues. This verifies cached geometry calculation, not complete background/stencil behaviour or exact Windows appearance.

Geometry cache version four enables recovery from earlier native spline polygons while preserving native identities and retained source parts. Native JSON and earlier binary metadata also refresh supported cached paths. Malformed sequences retain their cached control polygon or coordinate with an explicit diagnostic. Periodic conventions, singular/nonpositive-weight NURBS, complete ShapeSheet/control handles, themes and Windows differential validation remain required work.

Microsoft documents the second control point, knot cells and degree in [SplineStart](https://learn.microsoft.com/en-us/office/client-developer/visio/splinestart-row-geometry-section), and following points/knots in [SplineKnot](https://learn.microsoft.com/en-us/office/client-developer/visio/splineknot-row-geometry-section). The implementation retains these definitions and covers the tested subset above.
