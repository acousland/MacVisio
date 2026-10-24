# M0 completion — reference, inventory and evidence foundation

25 October 2026. **M0 is complete.** All 17 tasks meet their acceptance criteria against the exact reference. The earlier implemented/unaccepted record is [M0-EVIDENCE.md](M0-EVIDENCE.md).

Reference: Visio Professional 2019 **16.0.10730.20102** (32-bit, `VISIO.EXE` SHA-256 `8029E125…FAEA`), Windows 11 Pro ARM64 build 26300 in `mondrian-win`, unactivated by owner choice (the product-key prompt is closed automatically during runs). Frozen as QEMU snapshot `m0-reference-20261025`.

| Task | Acceptance criterion | Evidence |
| --- | --- | --- |
| WP-01-T01 | Inventory (completed 16 Oct) | [M0-EVIDENCE](M0-EVIDENCE.md) |
| WP-01-T02 | Visio launches; 32/64-bit automation and fonts verified | Installed from the media's `Setup32.exe` ([WINDOWS-VALIDATION](../WINDOWS-VALIDATION.md)); automation from x86 PowerShell and native ARM64 PowerShell both drive build 10730; Arial, Calibri, Segoe UI, Times New Roman, Courier New and Symbol present (173 fonts) — [inventory](../evidence/reference/visio-2019-inventory.json) |
| WP-01-T03 | Restored environment runs the known-good fixture | Snapshot restored at boot ([start-reference-snapshot.sh](../../scripts/windows/start-reference-snapshot.sh)); a marker written after the snapshot was gone and the session intact; all 7 VSDX fixtures then passed with 0 differences ([comparison](../evidence/reference/restored-reference-comparison.json)) |
| WP-01-T04 | Open, inspect, edit, save, close, reopen, export pass; repair prompts captured | All 7 VSDX fixtures pass every phase; the prompt watcher logged no window other than the product-key prompt, so no repair prompt occurred |
| WP-02-T01 | Ledger (completed 16 Oct) | [evidence README](../evidence/README.md) |
| WP-02-T02 | Observed/documented/unresolved distinct | Observed exact-build inventory kept separate from the bounded documentation/source inventory; ribbon/context-menu command surfaces are not enumerable through COM and stay unresolved beyond the 714 `VisUICmds` identifiers |
| WP-02-T03 | Parser-only success cannot mark compatibility; exclusions need decisions | Ledger validator enforces it; decisions [SD-2026-10-24-01](../evidence/decisions/SD-2026-10-24-01-accessibility.md) and [SD-2026-10-24-02](../evidence/decisions/SD-2026-10-24-02-japanese-input.md) |
| WP-02-T04 | No new baseline item lost or relabelled as extension | 1,260 child items own all 17,317 observed members; validation fails on any dropped item ([generator](../../scripts/build-reference-inventory.py)) |
| WP-03-T01/T02/T05 | (completed 16 Oct) | [M0-EVIDENCE](M0-EVIDENCE.md) |
| WP-03-T03 | Bidirectional comparison; reference failures visible | Visio→MacVisio reimport of Visio-saved copies: 7/7 VSDX identical apart from Visio's single edit; the 7 VSD reference failures are listed in the report ([reimport](../evidence/reference/reimport-comparison.json)) |
| WP-03-T04 | Controlled absolute gates and invariant checks | `--measure-drag-pan` passes MV-NFR-02 three times ([M2-PERFORMANCE](M2-PERFORMANCE.md)); `run-fault-injection.py` passes 40/40 interrupted saves ([record](../evidence/performance/fault-injection.json)). Work-count/scaling invariants run in the local pre-release suite, which replaces hosted CI by owner decision |
| WP-04-T01…T04 | Measured approaches; separate unmodified/translated results; exact prerequisites; decisions published | [ARCHITECTURE-DECISIONS](../evidence/ARCHITECTURE-DECISIONS.md) |

Findings the reference exposed and that are now fixed: Visio rejected every MacVisio VSDX without a `visio/windows.xml` part, and treated MacVisio connectors as unglued because they lacked Visio's glue formulas. Open blockers recorded rather than excluded: binary VSD semantics, unmodified VBA/COM/add-ins, OLE editing, rights-managed files, CAD generations and database reverse engineering.
