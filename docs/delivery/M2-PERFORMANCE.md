# MV-NFR-02 responsive direct manipulation — qualified

25 October 2026. **Passed without exception.** Requirement: on a 1,000-shape active page, p95 input-to-feedback ≤50 ms and p95 frame time ≤33 ms during a defined drag/pan trace.

**Trace** (`MacVisio --measure-drag-pan <drawing> <report>`): the authored `spec-interaction.vsdx` (1,000 shapes, 500 connectors, one page) in an on-screen, screen-sized editor. Five runs of a 240-step single-shape drag at fit-page zoom (every shape visible) through the canvas mouse handlers, then a 240-step pixel pan at 2.5× fit zoom through the editor scroll view, both at 120 Hz. Input-to-feedback runs from delivering an input to the display-link target time of the first presented frame after it was handled and drawn; frame time is the interval between successive presented frames carrying new content.

**Host:** Mac16,10 (Apple M4, 10 cores), macOS 27.0.1 (26A434), 60 Hz display, release build.

| Run | Drag latency p95 | Drag frame p95 | Pan latency p95 | Pan frame p95 |
| --- | --- | --- | --- | --- |
| [1](../evidence/performance/mv-nfr-02-run1.json) | 42.9 ms | 16.7 ms | 32.4 ms | 16.7 ms |
| [2](../evidence/performance/mv-nfr-02-run2.json) | 41.2 ms | 16.7 ms | 32.4 ms | 16.7 ms |
| [3](../evidence/performance/mv-nfr-02-run3.json) | 40.8 ms | 16.7 ms | 32.4 ms | 16.7 ms |

The baseline before this work redrew the entire canvas on each drag step (~96 ms) and ran frames ~250 ms apart; scrolling repainted the whole viewport. The changes: drag steps invalidate only the moved shapes and affected connectors, the drag preview is rebuilt once per frame, the canvas shows content through 256-point tile layers so scrolling moves rendered tiles, and the grid is stamped from a cached tile. Each run's single slowest drag frame (~140 ms) is the initial grab, which builds the gesture preview; it is inside the p95 budget and is recorded, not hidden.

Limits: one controlled host and display; synthetic events delivered to the editor's own handlers rather than through the window server; no claim for other hardware, larger pages or other gestures (MV-NFR-03 to -06 are separate gates).
