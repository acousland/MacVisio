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

Version 0.22.2 fixes a separate post-open stall. AppKit's focus transition sent an action from an unchanged inspector field, which previously triggered whole-document rich-text synchronization and formula recalculation. An unchanged displayed string now returns without committing; unchanged document replacements also return before calculation. The standard NSDocument initializer records the file modification date for save conflict handling.

The offscreen `--profile-open` report does not run the subsequent focus transition and must not be treated as a complete responsiveness measurement. Exercise the actual application event loop with:

```sh
open -n -W build/MacVisio.app --args --open-check /absolute/path/drawing.vsdx /absolute/path/open-check.json -ApplePersistenceIgnoreState YES
```

This read-only diagnostic opens the drawing, allows two seconds of normal event-loop processing after showing its window, and records main-thread heartbeat gaps, unchanged diagram/edit state, and file metadata readiness. It exits unsuccessfully if it detects an unintended edit or a post-open main-thread gap of at least half a second. Diagnostic opening events do not interpret the output report argument as another document. The report contains counts and timing/state checks, not drawing text.

On the local three-page drawing, two live checks recorded maximum post-open main-thread gaps of 0.11 and 0.14 seconds with no changed diagram or edited state. Opening itself took 8.19 seconds on the first run and 1.83 seconds on the repeat; cold-start costs remain variable. The memory monitor sampled a peak RSS of about 625 MiB on the first run. These checks address the unintended post-open recalculation; the application still reads the document synchronously before showing it.
