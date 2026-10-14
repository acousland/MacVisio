# Visio libraries — version 0.9

The supplied Office Click-to-Run image contains 536 VSSX stencils and 320 VSTX templates. All **856 assets / 98,839,448 bytes** have been decoded into `build/Visio2019-Libraries`. Each compressed block and completed file matches the installer manifest's SHA-256 declaration; every ZIP passes CRC checks. The source ISO remains unchanged and was mounted read-only. Libraries are local workspace assets, separate from the application bundle.

## Extraction and evidence

`scripts/extract-visio-libraries.py` reads `s641033.cab → Stream.Platform.Culture.man.xml` using macOS's built-in `tar`, then seeks declared zlib ranges in `stream.x64.en-us.dat`. It checks range coverage, compressed/decoded sizes, both hashes, ZIP expansion bounds and CRCs. It rejects existing output directories, duplicate filenames, missing requested files, gaps/overlaps and oversized inputs. No installer or Windows executable runs.

The report `build/Visio2019-Libraries/extraction-report.json` records every source path, file size and actual SHA-256. The manifest SHA-256 is `CF48DBF584A838B18F6AABE8B861CD337106C7DE20563C5C8F74E830C5E3750F`.

The actual `BASFLO_M.VSSX` hash is `E1A1B40CB24E4530E3426128292B7CC229DCAA7BF6A8CE14C9FFA50893F90833`. REA archive inspection evidence `ev_58387bf984bca97dcaef997dba87de44b246e19b4fbf397b1ed8042a5fe69f76` and nested inventory `ev_0582863463a5894bfd228ab71bc51daea379e48c7b3dc4dd6995f93677d0bf16` record its actual ZIP identity and 27 graph nodes. This is static package evidence; REA does not establish rendering or behavior. The custom `.dat` carrier is unsupported by REA, so its range decoding is direct bounded XML/zlib/ZIP analysis.

The flowchart stencil has 15 actual master entries, including Process, Decision, Subprocess, Start/End, Document, Data, Database and Dynamic connector. Tests import it and its paired template, insert the Process master and retain public connection-point rows through VSDX save/reopen without private metadata.

## Native workflows and public files

**File → Visio Libraries** opens a searchable folder browser. The local build automatically finds the extracted folder beside the app; **Choose Visio Library Folder** changes it. Selecting a VSSX/VSS loads masters into the active document's Shapes panel. Selecting a VSTX/VST opens an unsaved drawing; the original template stays unchanged. Folder enumeration skips hidden files and symlinks and is bounded to 10,000 entries. Files load on demand.

**File → Export Visio Template** writes the public template content type and preserves supported drawing content/source parts. Exporting an imported template as VSDX normalizes its public main content type to drawing. Native integrity metadata is updated after content-type changes.

**Shape → Export Selection as Stencil** serializes the selection as one public master. The serializer can write multiple masters; generated master parts include supported groups, cached paths, images, text, data, hyperlinks, layers, ports and connector records. Image relationships are relocated to their master parts. The file has the stencil main content type and no MacVisio private drawing metadata. The independent bundled `vss2xhtml` reader accepts the generated stencil.

Legacy VSS uses libvisio's `parseStencils` interface through bundled `vss2xhtml`, rather than accidentally selecting drawing pages. Masters become editable vector/text/image fragments. Original binary master names, formulas, data, glue and master identity are lost. VST uses the bounded legacy drawing reader and opens as a new drawing. Legacy VSS/VST writing is not implemented.

Cached EllipticalArcTo and RelEllipticalArcTo rows use their endpoint, intermediate arc point, angle and axis ratio to construct cubic segments. Microsoft defines these cells in its [elliptical-arc reference](https://learn.microsoft.com/en-us/office/client-developer/visio/ellipticalarcto-row-geometry-section) and [relative-arc reference](https://learn.microsoft.com/en-us/office/client-developer/visio/relellipticalarcto-row-geometry-section). Cubic approximation follows at most 90° per segment. Degenerate rows use a warned endpoint fallback. This adds the actual flowchart Document master's curved border; geometry formulas/control handles still do not fully recalculate.

## Validation boundary

The 0.9 complete scan imports **856/856 libraries: all 536 stencils and 320 templates**, totaling 12,108 decoded masters and 80,465 shapes. The full report is `build/library-import-report-0.9.json`; the durable [coverage summary](library-import-summary.json) records zero import failures. Drawing-scale-aware bounds and signed-coordinate origins resolve all 55 failures seen in 0.8. [DRAWING-SCALE.md](DRAWING-SCALE.md) explains the geometry and its verification boundary.

An initial complete scan imported 621 files and exposed legitimate zero-size shape axes, deleted members sharing sentinel ID 4294967295, repeated unnamed layers and engineering pages above the current limit. Zero axes receive a minimal editing frame, keeping original public cached dimensions untouched for unedited source files. Text-block and normalized path bounds are validated in physical coordinates, so a small frame may contain larger valid drawing content. Master thumbnails include cached path control hulls and text-block bounds. Deleted overrides are excluded from live-object uniqueness checks but retained in source XML. Layer display names are made unique without changing unchanged source rows.

Import success establishes that supported cached data can be decoded and validated. It does not establish that every geometry row, formula, master action, stencil solution or template workflow behaves like Visio. Full NURBS/splines, typed measurement and control-cell evaluation, dynamic signed-axis changes, master identity and updates, specialized solution logic and Windows comparison remain incomplete.

`Examples/Libraries` contains a drawing made from three actual installer masters, native/VSDX/experimental VSD/VSTX versions, a public three-master VSSX, PDF/PNG and native editor/browser renders. In-process renders are not manual UI validation. Microsoft Visio open/edit/save/reopen has not been tested.
