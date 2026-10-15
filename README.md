# MacVisio

A native Swift/AppKit diagram editor with a Visio-style ribbon and Dark, Light, and System appearance. VSDX opening caches XML lookups and reduces repeated work during master expansion. It includes Sparkle updates, text/property-aware ShapeSheet calculation, native text measurements, text-driven dimensions and controls, live tooltips, typed cell editing and exact snapshot Undo/Redo. Native control handles, text fields, mixed text styles, NURBS/splines, drawing scales, signed dimensions, stencils/templates, connections, groups, backgrounds, images, layers, Shape Data and hyperlinks are included. Both VSDX and experimental binary VSD can be read and written. **The complete 1:1 Visio port remains unfinished. Full binary VSD semantics and Visio feature parity are not implemented. VSD output is experimental and has not been validated in Microsoft Visio.**

## Run

Version 0.23.2 reduces editing stalls in large drawings with indexed rich-text synchronization, cached formula parsing, and recalculation limited to changed pages. VSDX/native documents load and save in the background. Saving captures an immutable snapshot and preserves edits made while writing. Version 0.23.1 fixed large-metadata save failures. The Home screen provides recent and pinned drawings, templates, and document switching. Drawings use separate native windows; closing the last drawing returns to Home. Switching or reopening an existing drawing preserves its zoom and selection. See [document workflow](docs/DOCUMENT-WORKFLOW.md). Use the ribbon’s **View > Appearance** control to choose Dark, Light, or System. See [editor appearance](docs/APPEARANCE.md).

This version also adds bounded line-theme ShapeSheet evaluation and experimental VSD 1-D connector endpoints. [The resumed plan](docs/PLAN.md) and [public Windows comparison corpus](docs/INTERCHANGE-CORPUS.md) describe the remaining compatibility work.

Download the ZIP from [GitHub releases](https://github.com/acousland/MacVisio/releases/latest), expand it and move MacVisio.app to Applications. The 0.23.2 distribution is for Apple Silicon and macOS 27 or newer. Choose **MacVisio > Check for Updates…** to check manually. Automatic checks are enabled by default and can be toggled in the same menu; installation requires your confirmation. See [release and updater setup](docs/DISTRIBUTION.md).

Open `build/MacVisio.app`. This arm64 build requires macOS 27 because its bundled legacy reader was built for that version. Earlier macOS releases and Intel Macs have not been tested. Swift source targets macOS 13, but producing an older-system bundle also requires rebuilding every legacy-reader dependency for that system.

```sh
brew install libvisio
./scripts/build-app.sh
open -n build/MacVisio.app
```

The build requires Xcode or Apple's Command Line Tools with Swift 5.9+, Python 3, network access for the pinned ZIPFoundation and Sparkle dependencies, and libvisio. The app bundles the reader and its native dependencies; end users do not need Homebrew. Build output records the actual minimum macOS version. Third-party licenses and source locations are included in `Contents/Resources/Licenses`.

Local builds use an ad hoc signature by default. Set `MACVISIO_SIGNING_IDENTITY` to a Developer ID Application identity to sign for distribution. The app is built for the architecture of the build machine. Apple notarization is performed separately before packaging a release.

## Use

- Launch to Home for recent and pinned drawings. **New Diagram** (Command-N) opens the template chooser; **New Blank Drawing** (Shift-Command-N) creates a blank drawing. **File > Open Recent** opens recent drawings.
- Use **View > Switch Windows**, Control-Tab, or Control-Shift-Tab to switch drawings. The ribbon’s **File** tab returns to Home. Closing the last drawing returns to Home; unsaved drawings use the native Save, Discard, or Cancel prompt.
- Drag or click a shape in the library. Search or filter the library at the top left. **Shape > Open Stencil** loads `.vssx` or legacy `.vss` masters; click or drag a master to insert editable shapes.
- **File > Visio Libraries** browses `build/Visio2019-Libraries`, containing the extracted installer assets. Search by filename or type, then open a stencil or template. **Choose Visio Library Folder** selects another folder. Library parsing and behavior limits are recorded in [STENCIL-LIBRARIES.md](docs/STENCIL-LIBRARIES.md).
- Double-click a shape to edit text; select characters and use Command-B/I/U for bold, italic or underline. **Shape > Text Format > Show Fonts** changes the selected font. Command-Return commits and Escape cancels. Option-click selects a child inside a group.
- Press **C**, then click two shapes to connect them. **V** returns to the pointer; **T** inserts text; **L** draws a free line.
- Drag to move; drag handles to resize. Hold Option to bypass snapping. Shift-click or drag a rectangle to select multiple shapes. Command-D duplicates. Delete removes. Arrow keys nudge; Shift moves ten points.
- Select a shape and drag its yellow control handle to adjust supported geometry parameters. Escape cancels a drag. **Shape > Control Handles** adds, renames or removes rows; **Control Cells** edits formulas and cached values. [Control behavior and limits](docs/CONTROL-HANDLES.md) includes an actual installer stencil test. Open `Examples/Controls/control-handles.vsdx` for a working example.
- Open `Examples/TextContext/text-driven-shapes.vsdx` and edit a label to exercise automatic dimensions. **Shape > ShapeSheet** edits supported text transforms and typed User/Property cells. [Text/context behavior and limits](docs/TEXT-CONTEXT.md) records the tested functions and remaining gaps.
- Use the inspector for formatting and geometry. Use **Shape** for grouping, rotation, flipping, images, Shape Data, hyperlinks and ShapeSheet. **Page > Layers** controls layer visibility, locking and printing. **Page Setup**, **Add Background Page** and **Edit Background** manage shared title blocks and backgrounds.
- Command-S saves `.vsdx` drawings. Existing VSDX files open in place, so Save updates that file. Save As creates a separate copy. `.macvisio` saves the native model with preserved source package parts.
- Opening external `.vsd` converts saved graphics to editable vectors, text and images. The original file is untouched; save the conversion as `.vsdx` or choose experimental binary VSD. MacVisio VSD files with matching metadata open in place. Opening `.vstx` or `.vst` creates an unsaved drawing from its pages.
- **File > Export Visio Template** writes `.vstx`. **Shape > Export Selection as Stencil** writes the selection as one `.vssx` master, including supported groups, connector glue, text, images, data and ports. Original advanced master logic is incomplete.
- **Page Setup** accepts paper dimensions and paper/drawing scale lengths, such as 1 cm = 50 cm. Geometry stays in drawing units; fonts and line weights use paper units. Scaled engineering masters keep real dimensions between measured drawings. See [DRAWING-SCALE.md](docs/DRAWING-SCALE.md) for tested behavior and remaining limits.
- Export the current page to PDF, PNG or SVG. VSDX and experimental VSD export contain all pages. **Export All Pages to PDF** combines foreground pages with their backgrounds. File > Print prints the current page.

## File compatibility

| Format | Read | Write | Practical limit |
| --- | --- | --- | --- |
| VSDX | Yes | Yes | Supported model edits are patched into the original package. Unchanged external packages retain every part's bytes; ZIP container bytes may differ. Unknown parts and unedited XML remain available. This does not establish full rendering or behavior fidelity. |
| VSD | Native metadata when verified; otherwise public graphics through libvisio | **Experimental** | A genuine v11 binary encoder writes saved graphics/text and native metadata. Unchanged source files retain all bytes; edited public binary semantics are incomplete and Windows acceptance is unverified. |
| VSSX | Master loading | Yes | Supported editable content exported as public masters. Full master identity/behavior and original stencil editing are incomplete. |
| VSTX | Opens as a new drawing | Yes | Public template content type, drawing pages and preserved package parts; solution automation is incomplete. |
| VSS / VST | Cached graphics / new drawing | No | Binary conversion loses names, formulas, data and glue; VSS/VST writing remains incomplete. |
| MacVisio | Yes | Yes | Native JSON, including original VSDX package parts for recovery. |

Public VSDX XML supports cached vector paths, nested groups, images, text blocks, fonts, shape data, hyperlinks, layers, free lines and connectors. Numeric ShapeSheet expressions support arithmetic, units, cell references and a bounded subset of functions. Unsupported formulas retain their source and cached values. Complete field formatting and advanced text layout, complete geometry evaluation, dynamic background behavior, engineering measurement tools, themes/effects, full port semantics and many specialist features remain incomplete. See [the detailed capability matrix](docs/COMPATIBILITY.md) and [binary VSD behavior and limits](docs/BINARY-VSD.md), and [background-page workflows](docs/BACKGROUND-PAGES.md).

VSDX export includes public Visio geometry and an integrity-checked native metadata part. Tests remove that private part before reopening interchange output. Windows Visio has not been used to validate these files. Microsoft documents the [VSDX package format](https://learn.microsoft.com/en-us/office/client-developer/visio/introduction-to-the-visio-file-formatvsdx) and [XML elements](https://learn.microsoft.com/en-us/office/client-developer/visio/visio-file-format-reference).

## Build and verify

```sh
swift test
./scripts/build-app.sh
build/MacVisio.app/Contents/MacOS/MacVisio --generate-examples Examples
python3 scripts/verify-app.py
open -n -W build/MacVisio.app --args --launch-check /tmp/macvisio-launch-check.json
```

Command-line conversion and rendering use the same document implementation as the editor:

```sh
build/MacVisio.app/Contents/MacOS/MacVisio --convert drawing.vsd converted.vsdx
build/MacVisio.app/Contents/MacOS/MacVisio --convert drawing.vsdx experimental.vsd
build/MacVisio.app/Contents/MacOS/MacVisio --render-document drawing.vsdx preview.png
build/MacVisio.app/Contents/MacOS/MacVisio --export-all-pdf drawing.vsdx all-pages.pdf
build/MacVisio.app/Contents/MacOS/MacVisio --profile-open drawing.vsdx open-timing.json
```

The launch check opens a temporary native window, records document/controller/action routing, and exits. Foreground activation is recorded separately. Open `Package.swift` in Xcode to develop the app. See [remaining work](docs/PLAN.md), [installer inspection](docs/INSTALLER-INSPECTION.md) and [validation](docs/VALIDATION.md).

Mixed-text implementation, source preservation and test boundaries are recorded in [RICH-TEXT.md](docs/RICH-TEXT.md). The two-page editable example is `Examples/RichText/project-handover.vsdx`, with matching VSD, native, template and rendered outputs.

Use **Shape > Insert Text Field** at the text caret or **Shape > Text Fields** to edit formulas. Tested behavior and limits are recorded in [TEXT-FIELDS.md](docs/TEXT-FIELDS.md).

Use **Shape > Geometry…** to edit an imported shape's existing geometry cells. See [GEOMETRY-FORMULAS.md](docs/GEOMETRY-FORMULAS.md) for supported behavior and remaining gaps.

NURBS and polyline data are editable through the same Geometry grid. Their tested scope and examples are in [NURBS-GEOMETRY.md](docs/NURBS-GEOMETRY.md).
