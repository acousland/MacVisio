# Background pages and page exports — version 0.4

MacVisio now imports and writes the public VSDX `Background` and `BackPage` attributes, renders shared/nested backgrounds, and provides native controls to create, assign, navigate to, resize and delete them. Foreground pages appear first in the page tabs; background tabs have a diamond marker. Background shapes are edited on their own page. Changes there update every foreground page using that background.

## Use

- **Page > Add Background Page** creates a background at the current page's size, assigns it to that page and opens it for editing.
- **Page > Page Setup** edits name, width, height, foreground/background type and the assigned background. Bare dimensions are points; units such as `210 mm` and `8.5 in` are accepted.
- **Page > Edit Background** opens the assigned page. **Go to Page** includes pages whose tabs do not fit in the window.
- **Page > Match Background Size** resizes the shared background to the current foreground's dimensions. This affects its other users too.
- Converting a background to a foreground page or deleting it detaches the pages using it. These edits support Undo.
- **File > Export All Pages to PDF** exports foreground pages with their backgrounds, retaining each page's dimensions. Backgrounds are not extra PDF pages. Current-page PNG/SVG/PDF export and printing also compose backgrounds.

A sample with two foreground pages and one shared title block is in [Examples/SharedPages](../Examples/SharedPages). Edit the title block once to change both pages.

```sh
build/MacVisio.app/Contents/MacOS/MacVisio --generate-page-example Examples/SharedPages
build/MacVisio.app/Contents/MacOS/MacVisio --export-all-pdf drawing.vsdx all-pages.pdf
build/MacVisio.app/Contents/MacOS/MacVisio --render-ui docs/page-editor-preview.png --page-example
```

## Coordinates and preservation

The native renderer composes each page as a separate layer, preserving page-scoped node identifiers, connector endpoints and layer settings. It does not merge background/foreground layer names. It clips the combined output to the foreground paper. Its placement uses a common physical lower-left origin: when page heights differ, a background's top-left drawing coordinates are offset by `foregroundHeight - backgroundHeight`. There is no automatic stretching of cached shapes.

Changing paper height preserves literal physical shape and free-line coordinates by adjusting their native top-left positions. A page-only resize or background assignment retains original shape-part bytes when content is unchanged in physical coordinates, including opaque extensions, pin formulas and connector records. Public page IDs remain unsigned 32-bit integers when adding pages to preserved packages. Older native metadata that omitted background fields is hydrated from public XML.

Microsoft documents [the public attributes](https://github.com/MicrosoftDocs/office-developer-client-docs/blob/main/docs/visio/page-element-pages_type-complextypevisio-xml.md), [background assignment](https://learn.microsoft.com/en-us/office/vba/api/visio.page.backpage), and [size-mismatch behavior](https://support.microsoft.com/en-us/visio/match-background-size-to-the-foreground-page). The coordinate mapping described above is an implementation inference from page-coordinate conventions; it has not been compared in Windows Visio.

## Verification and remaining limits

Tests cover public VSDX graph round trips without native metadata, initial foreground selection, shared/nested layers, page-local identifier collisions, print visibility, lower-left positioning, cycle/missing-reference rejection, deletion/type changes, Undo/navigation, unchanged part bytes, pin/formula retention, old metadata hydration, page-ID allocation, 100-background chains and multi-page PDF dimensions. The independent bundled libvisio reader also sees the title block on both foregrounds in generated VSDX and experimental VSD files.

The native render and rasterized two-page PDF were visually checked. Native panels and printing have not been manually driven through the UI. Windows Visio behavior remains unverified. Dynamic background formulas evaluated in foreground context, exact drawing-scale semantics, page-relative fields, themes and other advanced behavior remain incomplete. External binary VSD import still uses the graphics converter; it can flatten composed graphics rather than recovering an editable background-page graph. Checked native VSD metadata preserves the graph for MacVisio-authored files. Full Visio parity is not claimed.
