# MacVisio 0.25.0

This release brings the first part of milestone M3, intelligent Visio drawings, checked against Microsoft Visio Professional 2019. M3 is still in progress; this release makes no claim of full Visio parity.

**ShapeSheet formulas and fields.** More than 2,300 formula and text-field cases agree with Visio 2019 on the same drawing. They cover:

- typed units and dates
- colour and theme functions
- string coercion, and Visio's handling of missing, extra and invalid arguments
- text measurement and field format pictures

Page-sheet User and Shape Data formulas now recalculate. Recalculated values from unchanged formulas are not written back on save.

**Visio round trips.** Visio-authored drawings with masters, containers, groups, layers, Shape Data and multiple pages survive opening and saving in MacVisio, both unchanged and after moves, resizes, text, data, connection, deletion, page and layer edits. Only the edited content changes. Containers move with their members. Drawings that MacVisio writes from scratch open in Visio with the same pages, shapes, connections, Shape Data and fields.

**Appearance.** MacVisio now shows Visio theme quick styles in Visio's colours, including fill, line and text variants and connector label colours. Arcs and rounded corners, callouts and other one-dimensional shapes are drawn from their own geometry, and hairlines stay visible. Scaled pages print and export at their physical size: 1 m at 1:50 is 20 mm.

**Editing and output.** This release also adds:

- container membership independent of grouping
- Union, Intersect and Subtract
- persistent stencil pins and stencil drafts
- multipage printing
- PNG, JPEG and TIFF export with physical density and crop bounds
- per-document export settings

Known gaps are recorded in the M3 evidence:

- Some functions differ when used in control-handle, geometry or field cells.
- Text set in Calibri is measured with a substitute font on macOS.
- Layout, routing and template workflows are not yet complete.

Accessibility and Japanese input remain outside scope.

Apple Silicon and macOS 27.0.1 or later are required.
