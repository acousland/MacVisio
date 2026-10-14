# Knot precision and compound caches — 0.14

The 0.13 library scan imported all 856 assets but reported NURBS endpoint fallback in 26 files. A new effective-row audit, after inheritance was resolved, identified 347 affected rows. Every failure in that audit involved tiny decreasing knot differences caused by separate knot cells retaining more digits than the compound data string. The largest observed relative descent was approximately 4.36e-14.

The renderer now accommodates negligible descending serialization differences, within a relative tolerance of 1e-11 or 16 floating-point steps. This also accommodates older MacVisio compound caches, which used twelve significant digits. It rejects materially decreasing sequences. It does **not** merge distinct increasing knots. Evaluating each span in a local parameter interval avoids losing intermediate samples when absolute knot values differ by one floating-point step.

Compound caches and calculated geometry cells now use round-trippable numeric strings. Cached geometry data can occupy up to 128 KB, with at most 4,096 compound arguments; authored formulas retain the 16,384-character limit. This allows materialized full-precision data to be longer than the formula that produced it. Existing expression/dependency and rendering limits remain in force.

Geometry metadata versions one and two retain their definitions and native identities while their older compound path caches are refreshed. Public source parts and preserved legacy-source bytes remain retained. Geometry cache version three marks the current renderer; earlier native JSON/binary caches receive the existing definition-based recovery.

Three added tests cover actual mixed-precision data plus earlier twelve-digit caches, distinct one-step knot spans, and a 400-control-point cache exceeding the formula-length limit. The full suite passes 231 tests. The targeted 26-file effective-row audit falls from 347 issues to zero. This proves that those reported NURBS fallback cases are resolved; it does not establish complete Visio behaviour.

The [World master example](../Examples/Curves/World/installer-curved-master.vsdx), from BCKGRN_M.VSSX, exercises an affected installer asset. It retains 41 NURBS rows and produces 595 native cubic commands. Its original pale styling and remaining import warnings are retained. Gradients, spline rows and full background/stencil solution behaviour remain incomplete.

For diagnostics, `MacVisio --inspect-geometry input.vssx report.json` records effective cached NURBS/polyline issues with page/master name, shape ID, signed dimensions, row cells, endpoints and the calculation error. It also accepts VSDX/VSTX input. This command reports compound geometry failures, not every unsupported Visio feature.
