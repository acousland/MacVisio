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

These early versions imported all pages synchronously before showing the editor. Version 0.23.2 moves ordinary VSDX/native document loading to a worker, then creates the editor on the main thread. Full Visio parity remains outside these performance fixes.

Version 0.22.2 fixes a separate post-open stall. AppKit's focus transition sent an action from an unchanged inspector field, which previously triggered whole-document rich-text synchronization and formula recalculation. An unchanged displayed string now returns without committing; unchanged document replacements also return before calculation. The standard NSDocument initializer records the file modification date for save conflict handling.

The offscreen `--profile-open` report does not run the subsequent focus transition and must not be treated as a complete responsiveness measurement. Exercise the actual application event loop with:

```sh
open -n -W build/MacVisio.app --args --open-check /absolute/path/drawing.vsdx /absolute/path/open-check.json -ApplePersistenceIgnoreState YES
```

This read-only diagnostic opens the drawing, allows two seconds of normal event-loop processing after showing its window, and records main-thread heartbeat gaps, unchanged diagram/edit state, and file metadata readiness. It exits unsuccessfully if it detects an unintended edit or a post-open main-thread gap of at least half a second. Diagnostic opening events do not interpret the output report argument as another document. The report contains counts and timing/state checks, not drawing text.

On the local three-page drawing, two live checks recorded maximum post-open main-thread gaps of 0.11 and 0.14 seconds with no changed diagram or edited state. Opening itself took 8.19 seconds on the first run and 1.83 seconds on the repeat; cold-start costs remain variable. The memory monitor sampled a peak RSS of about 625 MiB on the first run. These checks address the unintended post-open recalculation. Those versions still read the document synchronously before showing it; version 0.23.2 moves that work off the main thread.

Version 0.23.3 removes duplicate page baselines from large native envelopes (inner format 4, separate from the unchanged format-3 storage manifest). Current pages reconstruct omitted originals by UUID; genuinely distinct originals are still encoded. Small drawings retain format 2, and the reader accepts formats 1/2/4. Content-types registration updates only the already-encoded public hash member rather than encoding a large envelope twice. The `--profile-open` report now separates metadata decompression, JSON decoding and public-part hash checking.

On a locally supplied three-page drawing, background saving fell from 13.59 to 4.46 seconds and reopening the saved result from 5.66 to 2.77 seconds. The main-loop save gap remained 12 ms and edits during saving remained dirty. All 52 public package parts were byte-identical after the unchanged save; all 6,628 node IDs remained intact. Decoded native metadata fell from 262,025,680 to 131,591,361 bytes. This is one local comparison, excluding cloud download time. Existing large drawings need one save to adopt the compact representation; opening alone never migrates the file. Older MacVisio versions bypass format-4 native metadata and reimport public content, so use the current version to retain native identities.
