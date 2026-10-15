MacVisio 0.22.2 fixes an unintended full-document recalculation after opening a drawing.

- Moving focus from an untouched inspector field to the canvas no longer commits an edit. This prevents a costly recalculation, unexpected edited state, and changes caused by rounded inspector numbers.
- No-op document operations retain the imported cached values instead of recalculating every shape.
- Opening uses the standard NSDocument initializer, establishing the file modification-date baseline used for save conflict handling.
- A live opening diagnostic exercises the event loop, deferred focus/layout actions, document edit state, and main-thread heartbeat after the window appears. The earlier offscreen import profile did not cover this transition.

Validation: 391 Swift tests pass, including untouched inspector fields, exact fractional dimensions, actual edits with Undo, and opening metadata/source preservation. The local live-window check leaves the drawing unchanged and unedited, with post-open main-thread gaps below 0.15 seconds across two runs. Private drawings and diagnostics remain outside the repository and release.

Requires Apple Silicon and macOS 27 or newer. Install using **MacVisio > Check for Updates…**, or expand the ZIP and move MacVisio.app to Applications.

Full Visio compatibility remains unfinished; binary VSD writing remains experimental.
