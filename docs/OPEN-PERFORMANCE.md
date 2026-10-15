# VSDX opening performance

Version 0.19 addresses repeated work during master expansion. XML cell dictionaries and child indexes are now cached for each parsed element. Structural edits invalidate those caches. Master formula references use a shared compiled expression; formulas without sheet references return before building an identifier map. Shape formatting is updated once per master instance shape, and unchanged formulas avoid repeated value copies.

The import retains the existing size limits, ZIP checksum verification, public XML, unknown parts, cached values and instance-specific master semantics. The regression suite includes a synthetic 300-cell master with two instances and a local formula override. No customer drawing is included in the repository or release.

In local validation, loading and exporting a large three-page drawing fell from roughly 17–19 seconds to 3.1–3.4 seconds. Every page's SVG content matched the earlier build after normalizing generated clip IDs. The native editor's first viewport completed in about 3.1 seconds: package extraction took about 7 ms, page import about 2.75 seconds, validation about 160 ms, editor setup about 50 ms and the viewport draw about 100 ms. These measurements describe one drawing and machine, rather than a universal speed guarantee. All 284 local tests pass.

Version 0.22.1 also caches each resolved style family/ID for the duration of an import, preserving per-shape/master overrides and the existing inheritance depth bound. This avoids repeated style-chain traversal and theme-selector comparisons. In three alternating runs per version on the same machine and locally available drawing, the median import plus first viewport fell from 4.27 seconds in 0.22.0 to 1.92 seconds in 0.22.1. Shape/connector counts remain unchanged; all 52 source package parts survive an unchanged save byte for byte. These are local results, excluding process startup and cloud download time. Rendering now honors cached group DisplayMode and HideText values, so recovered labels intentionally change the preview.

Use the diagnostic CLI to measure a drawing:

```sh
build/MacVisio.app/Contents/MacOS/MacVisio --profile-open drawing.vsdx open-timing.json
```

The report separates package decompression, document XML, masters, individual pages, validation, editor setup and the first offscreen viewport draw. It contains counts and timings rather than drawing text. It measures loading and rendering in-process; process startup and a cloud provider fetching an unavailable file are separate costs. The report destination must differ from the input drawing.

The app still imports all pages synchronously before showing its editor. Large drawings can therefore cause a shorter main-thread pause even with the faster importer. Full Visio parity remains outside this performance fix.
