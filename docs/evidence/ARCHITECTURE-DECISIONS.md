# M0 architecture decisions (WP-04)

25 October 2026. Reference: Visio Professional 2019 **16.0.10730.20102** (32-bit, unactivated) on Windows 11 ARM64 in `mondrian-win`; frozen as QEMU snapshot `m0-reference-20261025` (restore with `scripts/windows/start-reference-snapshot.sh`). Per owner decision, an infeasible capability is recorded as an **open blocker**, never as an approved scope exclusion. The 27 feasibility children in [feasibility-decisions.json](feasibility-decisions.json) remain owned by their downstream packages.

## ADR-01 Binary VSD (WP-04-T01, owner WP-30)

**Measured.** MacVisio's direct writer: Visio 2019 opens **0 of 7** synthetic `.vsd` fixtures ("An exception occurred"). Reading Visio-authored `.vsd` (Visio saved each VSDX fixture as VSD) through the bundled libvisio adapter yields graphics, not semantics: page names become "Page N", connectors flatten into plain shapes (flowchart: 8 shapes + 8 connectors read as 43 shapes, 0 connectors) and page sizes drift by ~0.003 pt. Visio opens and saves its own VSD normally.

**Decision.** Keep the **direct** binary path for both reading and writing and extend it semantically in WP-30; keep libvisio only as a graphics fallback for streams the direct reader does not yet understand. No macOS adapter can write VSD. Binary VSD stays labelled **experimental** in the product and release notes until a WP-30 child passes the bidirectional Visio check. Status: open blocker for VSD compatibility claims.

## ADR-02 Automation and add-in hosting (WP-04-T02, owner WP-31)

**Measured.** A JavaScriptCore host exposing a Visio-shaped object model ([AutomationPrototype.swift](../../Sources/MacVisio/AutomationPrototype.swift)) ran a translated script whose outcome matched Visio 2019's COM run exactly: 3/3 shapes, geometry and Unicode text ([comparison](reference/comparison.json), [script](reference/translated.js), [VBA reference](reference/visio-macro.bas)). Unmodified VBA does not execute: MacVisio has no VBA runtime, and COM/VSTO/VSL/ActiveX add-ins are Windows binaries.

**Decision.** Translated automation runs on an in-process JavaScriptCore object model that mirrors Visio's type library (211 interfaces, 18 event interfaces observed). Unmodified VBA, COM clients and Windows add-ins are an **open blocker**; results are always reported separately for unmodified and translated scripts.

## ADR-03 OLE objects (WP-04-T03, owner WP-32)

**Observed.** The reference has no Office applications installed (Excel, Word, Access, PowerPoint all absent), so embedded Office objects cannot be created or edited there; `InsertObject` for Excel and Paint objects failed. **Decision:** preserve OLE parts and their cached previews (EMF/WMF) without activation; editing embedded objects is an **open blocker** until a reference with Office installed and a macOS editing route exist.

## ADR-04 Protected and rights-managed files (WP-04-T03, owner WP-32)

**Observed.** Document protection is exposed (`Document.Protection` = 0 on a new drawing); no Rights Management client is installed. **Decision:** honour Visio's document/shape protection cells; never bypass rights management. Opening rights-managed (IRM) drawings is an **open blocker** pending an authorised RMS tenant and test document.

## ADR-05 CAD import/export (WP-04-T03, owner WP-28)

**Observed.** The reference ships CAD add-ons (Open/Insert/Convert AutoCAD Drawing, Export to AutoCAD DWG/DXF); a minimal synthetic DXF was rejected by `Page.Import` ("Identify the file type you are importing"), so the exact accepted DXF/DWG versions are not yet established. **Decision:** CAD stays an **open blocker** until WP-28 records exact DWG/DXF generations accepted by the reference and chooses a macOS reader/writer with licence review.

## ADR-06 Data sources (WP-04-T03, owner WP-23/WP-26)

**Observed.** 17 ODBC drivers (Access, Excel, Text, dBase, Paradox, Oracle, SQL Server; 32- and 64-bit) and the Visio database add-ons (Database Wizard, reverse engineer, refresh) are present; `DataRecordsets` is available. **Decision:** implement data linking natively on macOS (file sources first, ODBC through iODBC/unixODBC where licensed); database reverse engineering remains an **open blocker** until WP-26 selects a supported engine matrix.

## ADR-07 VSDX interchange (owner WP-14/WP-20)

**Measured.** Visio 2019 required a `visio/windows.xml` part and Visio's own glue formulas (`_WALKGLUE`/`PAR(PNT())` endpoints with `_XFTRIGGER` triggers); without them it rejected files or dropped all glue. With both, the 7 synthetic VSDX fixtures pass open, inspect, edit, Save As, reopen, PDF and SVG with 0 differences, and MacVisio rereads Visio's saved copies identically (pages compared by name; Visio moves background pages). **Decision:** VSDX is the primary interchange format; every package change is checked in both directions against the frozen reference before release.
