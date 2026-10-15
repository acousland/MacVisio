MacVisio 0.23.2 addresses long interface stalls when opening, editing, and saving large drawings.

- VSDX and native document loading runs in the background. The editor appears after loading completes, with normal document switching and file-modification tracking preserved.
- Rich-text synchronization uses indexed shape lookups and leaves unchanged formatting alone. Geometry addresses and parsed formulas are cached within their appropriate lifetimes.
- Edits recalculate changed pages while retaining untouched imported caches and their known formula warnings. Document-wide text fields still update; changing the underlying document archive forces full geometry calculation. Undo/Redo restores the cached warnings with the drawing.
- Saving serializes an immutable snapshot in the background. Edits made during writing remain unsaved changes; overlapping saves are serialized in request order.
- An interaction diagnostic exercises selection, page switching, insertion, and Undo/Redo without saving its input.

All 445 Swift tests and seven packaging tests pass. Regression coverage includes edits during saving, overlapping saves, failure recovery, duplicate opens, file-modification tracking, and formula/text-field correctness across pages, including drawings with unsupported formulas.

Local validation on a complex drawing measured shape insertion at 0.75–1.55 seconds across its pages, compared with the earlier 4.7-second repeated-edit stalls. Background saving took 13.6 seconds with a maximum 12-millisecond main-loop gap; the saved snapshot reopened correctly and later edits stayed dirty. Background opening took 5.25 seconds with a maximum 145-millisecond main-loop gap. These timings depend on the drawing and machine.

Requires Apple Silicon and macOS 27 or newer. Install using **MacVisio > Check for Updates…**, or expand the ZIP and move MacVisio.app to Applications. Full Visio compatibility remains unfinished; binary VSD writing remains experimental.
