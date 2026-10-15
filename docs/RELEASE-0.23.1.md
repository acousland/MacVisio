MacVisio 0.23.1 fixes “The document could not be saved” errors on complex imported VSDX drawings.

- Expanded native editing metadata could exceed both the single-part and total package limits. Large metadata is now compressed and stored in bounded private parts. Reopening verifies segment hashes and streams decompression within a declared-size budget. Existing small metadata remains readable.
- Supported edits continue to patch the public Visio package. Tests retain unknown vendor parts and verify edited public drawing content without MacVisio metadata.
- Page-local shape lookups and cached defaults reduce repeated work during metadata preparation and recalculation. Identical saved baselines share one synchronization pass.
- Save alerts include the underlying MacVisio failure reason. A failed serialization leaves the existing file unchanged and the document edited.

All 424 Swift tests and seven packaging tests pass. Validation covers actual NSDocument saves, repeated overwrites, Save As, VSDX/native/experimental VSD reopening, oversized imported metadata, stale-segment cleanup, rejected saves, and compressed-data validation. An edited copy of the locally supplied complex drawing now saves and reopens with its shape identities and page counts preserved. Native-window testing also confirms that adding a shape, saving, closing, and reopening retains the edit.

Requires Apple Silicon and macOS 27 or newer. Install using **MacVisio > Check for Updates…**, or expand the ZIP and move MacVisio.app to Applications. Full Visio compatibility remains unfinished; binary VSD writing remains experimental.
