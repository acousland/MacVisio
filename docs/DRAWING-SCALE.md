# Drawing coordinates and scale — version 0.9

MacVisio now keeps Visio geometry in drawing coordinates and converts it to paper coordinates for the native canvas, thumbnails, PNG/SVG/PDF and printing views. `PageScale / DrawingScale` is the conversion factor. Paper dimensions are drawing-page dimensions multiplied by this factor. Font size and line weight remain paper quantities.

This follows Microsoft's [drawing-scale specification](https://learn.microsoft.com/en-us/openspecs/sharepoint_protocols/ms-vsdx/1a60ffcb-969c-48f1-aa02-ff2228718043). Cached length values are [stored in inches](https://learn.microsoft.com/en-us/openspecs/sharepoint_protocols/ms-vsdx/516ff6cd-4242-41d0-9233-b76aefc64430), even when their display unit `U` is MM or M. The importer does not convert those cached values a second time. Bounds apply to physical paper dimensions; raw coordinates also have a finite upper limit. Supported scale factors are 1e-6 through 1e6, with a 20,000-point paper page/shape limit.

## Native behavior and persistence

Page Setup exposes paper width/height and paper/drawing scale lengths, accepting units such as cm, mm and inches. Scale/page changes support Undo. Geometry and numeric ShapeSheet length cells stay in drawing units, so raw values and formulas can round-trip to public XML. `ThePage!PageScale` and `ThePage!DrawingScale` are available to the scalar formula evaluator. Canvas hit testing, zoom, selection markers and physical exports use the same coordinate factor.

Backgrounds with different scales align at their physical lower-left origins. Each layer retains its own coordinate and layer namespaces. VSDX stores the public PageScale/DrawingScale cells and drawing-unit geometry. The experimental binary writer stores the public scale values too; independent libvisio parsing verifies the resulting physical page dimensions and font sizes.

Dropping measured shapes between measured drawings retains real dimensions. Crossing between measured and unmeasured drawings adjusts cached geometry to retain its paper size. This distinction follows Microsoft's [DropOnPageScale documentation](https://learn.microsoft.com/en-us/office/client-developer/visio/droponpagescale-cell-miscellaneous-section). Dropped cached fragments record the scale factor, translate source coordinates/ports and remap identifiers. When geometry changes units, geometry formulas are materialized as cached values to prevent source length literals from reverting public dimensions. Homogeneous Width/Height port formulas stay live where their scaled result matches. Full master instances, arbitrary dimension-aware formula rewriting and extreme drop-scale thresholds are not implemented or Windows-validated.

## Signed dimensions and pin transforms

Negative Width/Height are legitimate source coordinates. The native editing frame uses positive dimensions with source origin `(min(W,0), min(H,0))`. Paths are normalized relative to that origin; raw flip flags are retained. The source transform is:

`Pin + Rotate(Angle) × Flip × (point − LocPin)`

This order is defined by Microsoft's [coordinate-system specification](https://learn.microsoft.com/en-us/openspecs/sharepoint_protocols/ms-vsdx/99f006f5-c67e-4e29-8a19-134ae611fd8f) and corroborated by the pinned official libvisio collector. Group members and attached/free connector points convert between positive native frames and signed parent coordinates. Public VSDX and binary cached graphics retain the signed geometry. Off-center pins now account for the shape's own flip before rotation; changing a flip in the native model updates the public pin to retain the model's frame.

The actual BLOCKP_M “Elbow 1” child with width −1 mm has four independently derived expected points: `(82.2047244094,−31.1811023622)`, `(85.0393700787,−56.6929133858)`, `(85.0393700787,56.6929133858)`, `(82.2047244094,31.1811023622)` points. Tests verify these points after import, numeric recalculation, fresh public export, source-preserving movement and independent binary parsing.

Older VSDX native metadata containing flips is reimported from public XML under the new transform marker. Missing scale fields in older archive-backed metadata are hydrated from the public PageSheet. Pre-0.9 native JSON containing cached flipped frames is not automatically reconstructed; reimport its public VSDX source to obtain the corrected transform. Complete geometry expression recalculation, dynamic axis-sign changes, all typed ShapeSheet cells and source-master controls remain open work.

## Evidence and validation

All **856 installer libraries** now pass import/model validation: 536 stencils, 320 templates, 12,108 masters and 80,465 shapes. The full report is `build/library-import-report-0.9.json`; [library-import-summary.json](library-import-summary.json) is the durable summary. This resolves the 55 size/signed-axis failures from 0.8. It does not prove that every shape renders or behaves like Visio.

Representative source-paper dimensions checked by tests:

| Master | Scale | Cached physical size |
| --- | --- | --- |
| RECRT_M “Basketball key” | 0.002 | 20.9763779528 × 43.0866141732 points |
| SITACC_M “Entrance gate” | 0.01 | 345.6 × 13.6913385827 points |
| CEILPL_M template page | 0.02 | Width 2,383.93700787402 points |

Eleven new tests cover actual library dimensions, physical raster comparison with equal fonts/lines, canvas/background coordinates, source-byte preservation and public round trips, native scale editing/Undo, older metadata, insertion/ports, signed transforms, old flipped-pin metadata and independent reads in both file formats. The complete suite passes 169 tests.

`Examples/Engineering` contains a 1:200 drawing with actual recreation/site-access/block masters, native JSON, VSDX, experimental VSD, VSTX, SVG, PDF/PNG and a native editor render. The court's real playing dimensions are 15.2 m × 28.7 m and the gate's span is 12.192 m; the abstract block symbol uses the cross-space drop factor. These values are cached source dimensions, not certified engineering measurements. Renders were inspected in process; Windows/native manual interaction, specialist engineering functions and full diagram behavior remain unverified.

Static archive identity evidence from REA: BLOCKP_M `ev_77be6d8974f89775ef5e2aa332a4f0463779f93d7e793149924b361aead3a8e2`; RECRT_M `ev_395b54e9484d561a9599b3b77e0a535ad3f5b37330f9688f9318008e5128564c`; SITACC_M `ev_e7d9e577e6ce3ea07c8ea8b4c1aab8ca6835a298649820ca93604428b42e1ed5`; SHPREC_M `ev_eefb4f298326f646f88a2dbfce1fbf044c5e7609882dcfc01108a1fe070017e8`. These establish archive identity; the transform expectations come from actual XML and documented math. No Windows execution was observed.

The engineering package check exposed empty Property/Hyperlink sections on cached group children. The independent reader's section skipper could consume later text, so generated empty optional sections are now omitted while inheritance deletion markers remain. A grouped-shape regression verifies following text with the independent reader.
