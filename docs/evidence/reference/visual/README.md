# Visual and physical reference (WP-19)

Visio 2019 exported each Visio-authored reference drawing (`Tests/MacVisioTests/Fixtures/Reference/visio-*.vsdx`)
to PDF and 96 dpi PNG (`Snapshot-VisioDrawings.ps1 -Export`). MacVisio rendered the same files
(`--render-document`, `--export-all-pdf`). Each image here shows Visio's export on the left and MacVisio's render
on the right, both cropped to the drawing.

Defects the comparison found, all fixed and covered by `VisioVisualReferenceTests`:

| Drawing | Visio | MacVisio before | Fix |
| --- | --- | --- | --- |
| intelligent | Rounded Rectangle has convex corners | `ArcTo` bows drawn inverted, so corners were concave | A positive bow bulges right of travel in Visio's y-up frame |
| intelligent | `DrawArcByThreePoints` 1-D arc | straight line between the endpoints | 1-D shapes that are not plain polylines draw their own geometry |
| structure | Side box callout: leader plus a box holding "Note" | straight route with the label at its middle | Same, with the text block at its TxtPin and TxtAngle, aligned across TxtWidth |
| intelligent | 0.24 pt stencil outlines drawn solid black | anti-aliased to grey | On screen and in bitmaps, lines are at least one device pixel wide. PDF keeps the exact weight. |
| flowchart | connector labels in the theme's connector font paint (61, 100, 172) | black | Themed connector `Char.Color` resolves through the connector font styles |

Physical scale (WP-19-T02/T04), `visio-pages.vsdx`:

- The Plan page is drawn at 1:50: 1000 mm of drawing is 20 mm on paper. The 4 m room measures 300 px in Visio's
  96 dpi export, which is 80 mm. MacVisio's model gives 80.0 mm.
- Visio stores PageWidth/PageHeight in drawing units. Plan's 210 × 297 mm drawing page is therefore 4.2 × 5.9 mm
  of paper. Visio's PDF page is 11.25 × 16.5 pt, rounded to whole pixels; MacVisio's PDF page is 11.91 × 16.84 pt.
  The unscaled Detail page is A4 in both (594.75 × 841.5 pt and 595.28 × 841.89 pt). Both PDFs have two pages,
  because the background page is not exported on its own, and the same extracted text.

Remaining difference, not a defect: Visio draws text in Calibri and MacVisio substitutes the system font when
Calibri is not installed, so glyph widths differ slightly. G1/G2 text that looks blue in Visio's PNG is black
with ClearType colour fringes.

After these changes the round-trip reference (22 outputs) and the authored reference (9 drawings) still show no
differences.
