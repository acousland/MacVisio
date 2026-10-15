# Binary VSD read/write — version 0.3

MacVisio now has an **experimental native binary VSD writer**. It emits Visio v11 saved-value streams inside a real MS-CFB compound document. It is not VSDX, SVG or XML with a `.vsd` filename. An independent libvisio reader parses generated documents, including Unicode text, nested groups, images, multiple pages and cubic curves.

**Microsoft Visio has not opened, edited, saved or reopened these generated files. The encoder is not a verified full VSD implementation.** Some payload suffixes, masks and Windows-specific semantics remain unknown. An independent reader accepting a file is insufficient evidence that Windows Visio accepts it without repair or preserves its behavior.

Version 0.13 adds saved NURBS/polyline data records with coordinate types, knots and weights. Independent tests omit private metadata and compare public curve bounds. Complete binary formulas and Windows recalculation remain unimplemented or unverified. See [NURBS-GEOMETRY.md](NURBS-GEOMETRY.md).

## Available workflows

- File > Export Binary VSD (Experimental), or the Export toolbar menu, writes all pages.
- Save As offers Binary Visio Drawing (Experimental). Native VSD files with matching MacVisio metadata open in place; Save updates them.
- External legacy VSD files open as converted, unsaved drawings, preserving the original file. They default to VSDX saving; VSD Save As is also available.
- Command-line conversion accepts VSDX and VSD output:

```sh
build/MacVisio.app/Contents/MacOS/MacVisio --convert drawing.vsdx drawing.vsd
build/MacVisio.app/Contents/MacOS/MacVisio --convert drawing.vsd drawing.vsdx
```

## What is public binary content

The encoder writes the compound-file header/directory, FAT, mini-FAT and DIFAT, Visio document header, pointer tables, fonts, page names, page/background references, page dimensions, shape IDs/order/parent relationships, saved transforms, fill/line properties, text blocks, Unicode text, uniform character/paragraph style, vector geometry and supported images. Cubic and quadratic paths use equivalent uniform NURBS records rather than being reduced to line segments. BMP uses the DIB payload expected by the binary reader. PNG, JPEG, GIF and TIFF data are also encoded; PNG and BMP have pixel/content regression coverage. PDF/SVG/metafile/OLE image export is not implemented and fails before replacing the destination.

Formula logic, original masters, Shape Data, hyperlink behavior, layers, connection-point definitions and glue semantics, advanced text formatting and other full Visio features are **not comprehensively serialized into public binary records**. Microsoft's [Connection Points reference](https://learn.microsoft.com/en-us/office/client-developer/visio/connection-points-row-connection-points-section) defines the point's X/Y, direction and type semantics, but not their legacy binary payloads. The available reference-reader source declares binary chunk IDs for connection-point lists (`0x71`), glue lists (`0x72`) and connection points (`0x99`) without parsing these records; the evidence ledger therefore does not establish payload bytes or Windows behavior for them. See its [record table](https://github.com/LibreOffice/libvisio/blob/d6c9d6492131dbb8bb568e1d38b38890ae2a865a/src/lib/VSDDocumentStructure.h#L40-L81) and [chunk dispatch](https://github.com/LibreOffice/libvisio/blob/d6c9d6492131dbb8bb568e1d38b38890ae2a865a/src/lib/VSDParser.cpp#L419-L592). Several complete Windows row structures and document/style settings remain unresolved. Geometry and cached style coverage is not a full behavioral port.

## Native metadata and preservation

A separate `MacVisioModel` compound stream stores native model details, including connections, IDs and supported formulas/data. It is used only when the hashes of every public compound stream and the root class ID still match. External edits invalidate it; the importer then reads public content through libvisio. Microsoft Visio does not use this stream to implement those native features.

An external legacy import also retains the complete original file and its imported baseline. Exporting that baseline unchanged preserves the source **byte for byte**, including opaque streams. Native JSON recovery retains this source. VSDX recovery retains it in bounded `.mvsd` package segments referenced by the native metadata part; tests verify that returning to VSD restores the original bytes. When an imported drawing is edited, binary export regenerates supported saved graphics/text and copies opaque root-level CFB stream payloads and the root class ID into the new compound file. It replaces `VisioDocument`, `VisioInformation` and `MacVisioModel`; nested-storage streams and references/ownership semantics are not mapped, and preserved opaque values may no longer match the regenerated document. This does not establish lossless preservation of original legacy semantics.

The old SVG conversion path remains the public-content importer for external files. Its preview can reduce rich text, alignment and glue behavior; it is not a full binary object-model importer. The independent SVG renderer prints rounded dimensions and does not reproduce every text/connector styling feature. Generated native VSD files reopen via checked metadata, while independent-public-content tests bypass that metadata explicitly.

Binary files and preserved original sources are limited to 100 MB; compound decoding is bounded to 128 MB and checked for invalid/cyclic allocation. The VSDX package limits still apply to preserved source segments and other parts. Large drawings may exceed these bounds.

## Evidence and next work

See [the byte/source evidence ledger](VSD-FORMAT-EVIDENCE.md) for fixture hashes, source commit and pointer/chunk layouts. These observations came from fixture inspection and source analysis; they are not Windows runtime observations or REA provider evidence. The CFB container follows Microsoft's [MS-CFB specification](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-cfb/53989ce4-7b05-4f8d-829b-d08d6148375b).

Remaining work includes Windows open/edit/save/reopen tests, complete binary payload and expression serialization, richer direct binary import, full original-object/stream mapping and edit preservation, semantic glue/master/data handling, and the broader gaps in [COMPATIBILITY.md](COMPATIBILITY.md). The complete Visio port remains open.
