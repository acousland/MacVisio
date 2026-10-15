MacVisio 0.23.0 adds a document start screen and drawing-window workflow informed by Microsoft's Visio documentation.

- Launch to Home with recent and pinned drawings, search, and a template chooser. Home does not read drawing contents until you open a file.
- File > Open (Command-O) shows the Open screen; Browse Files (Shift-Command-O) opens the native file picker directly. Choose Home, New, or Open from the start screen; browse for multiple files or create a blank, flowchart, organization, network, or swimlane drawing.
- Drawings use separate native windows. View > Switch Windows and Control-Tab / Control-Shift-Tab switch between them while preserving their zoom, selection, and edits. Opening an already-open normalized file path activates its existing window.
- The ribbon's File tab returns to Home, with Back to Drawing, Save, Save As, and Close Drawing actions. Closing the last drawing returns to Home. Closing drawings uses native unsaved-change handling.
- Open Recent and successful saves update local history. Pins remain when recent history is cleared.

Validation: 405 Swift tests and seven packaging tests pass. Native-window checks cover cancelling a close, saving while closing, returning to Home, reopening from Recents, pinning, and forward/reverse drawing shortcuts with retained zoom. Dark and light start-screen previews were checked at the minimum supported width. The bundled import/export and native menu-routing checks also pass.

The reference is Microsoft's published documentation; a live Visio 2024 runtime was unavailable. Startup layout, last-window behavior, and Mac shortcuts are MacVisio adaptations. This release does not establish full Visio parity or change the synchronous document importer. See docs/DOCUMENT-WORKFLOW.md for evidence and behavior details.

Requires Apple Silicon and macOS 27 or newer. Install using **MacVisio > Check for Updates…**, or expand the ZIP and move MacVisio.app to Applications. Full Visio compatibility remains unfinished; binary VSD writing remains experimental.
