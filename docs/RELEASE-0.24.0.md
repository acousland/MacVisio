# MacVisio 0.24.0

This release completes the M0–M2 milestones: a dependable native editor, checked against a real Microsoft Visio Professional 2019 reference.

**Visio interchange.** Connectors are now glued the way Visio expects. Visio 2019 previously opened MacVisio connectors as loose lines and dropped their glue on save; it now sees every connection, keeps it through Save As, and MacVisio reads Visio's saved copies back identically. All seven synthetic VSDX comparison drawings pass open, inspect, edit, save, reopen and PDF/SVG export in Visio 2019, in both directions. Binary `.vsd` remains experimental and does not yet open in Visio 2019.

**Responsiveness.** Dragging and panning on a page with 1,000 shapes and 500 connectors now meets the 50 ms input and 33 ms frame targets with margin: the canvas draws through cached tiles, so scrolling moves already-drawn content and a drag redraws only what moved.

**Home.** The Home window is a compact launcher that fits smaller displays, reflows its templates, and opens a recent drawing when you click its row.

Accessibility (including VoiceOver) and Japanese input testing are outside this release's scope by owner decision; no claims are made for them. Full Visio parity is not claimed.

Apple Silicon and macOS 27.0.1 or later are required.
