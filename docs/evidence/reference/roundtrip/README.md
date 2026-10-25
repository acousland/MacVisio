# Visio round-trip reference (M3, G2)

Visio Professional 2019 (16.0.10730) authors four drawings with its own automation
(`scripts/windows/VisioRecipes.ps1`):

| Drawing | Content |
|---|---|
| flowchart | Basic Flowchart masters, AutoConnect dynamic connectors with labels, Shape Data, theme |
| intelligent | Rich text with a PAGENAME field, User/Prop formulas, control handle, masters, arc/oval/polyline/spline, rotation and flip, protections, hyperlink |
| structure | Container with members, callout annotation, group, hidden/non-printing layer, connector glued to a connection point |
| pages | Background page with PAGENAME/PAGECOUNT title block, 1:50 metric scale, two foreground pages |

MacVisio saves each one unchanged and with the edits in `edits.json` (`--apply-edits`), with its
private metadata part removed. Visio then describes the original and every MacVisio output
(`Snapshot-VisioDrawings.ps1`: pages, layers, connects, masters, styles, and per shape its key
cells, text, fields, User/Prop rows, controls, geometry rows, connection points and containers).
`scripts/compare-visio-snapshots.py` requires unchanged saves to be identical and edited saves to
differ only where the edit acts, plus the routes of connectors glued to a moved shape and page
fields after a page is added.

Result (`comparison.json`): all 14 MacVisio outputs pass. Run again with
`python3 scripts/run-roundtrip-reference.py` (guest running and signed in).
