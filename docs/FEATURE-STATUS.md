# MacVisio feature status

Status date: 16 October 2026. Covers all 154 requirements in the [product specification](PRODUCT-SPEC.md).

This is a documentation/source-based assessment of the current local implementation, informed by the 0.23.3 release notes and selected source inspection. No tests or Microsoft Visio runtime checks were rerun for this assessment. In-progress working-tree changes are not treated as qualified releases.

**Implemented** means the named local capability exists with repository evidence; it does not mean every acceptance criterion or Visio equivalence has passed. **Partial** means a subset exists. **Experimental** means explicitly provisional support. **Not implemented** means the compatibility/plan documents identify the workflow as outstanding. **Not evidenced** means no adequate implementation evidence was found in this review. **Unverified** means the acceptance target has not been qualified. **Blocked** identifies a documented missing prerequisite. **Planned extension** is future scope beyond the frozen baseline.

All Microsoft Visio interoperability and full-parity acceptance remain unverified. The Windows validation notes report that the reference guest lacks installed/registered Visio; that guest state was not reinspected here. Importing a template or preserving its XML does not implement its specialist solution behavior.

| Status | Requirements |
| --- | ---: |
| Implemented | 9 |
| Not evidenced | 4 |
| Partial | 88 |
| Blocked | 2 |
| Unverified | 13 |
| Not implemented | 31 |
| Planned extension | 6 |
| Experimental | 1 |

These counts are requirement classifications, not percentages of product completion. Requirements vary substantially in size.

| ID | Feature | Status | Existing support / remaining work | Evidence |
| --- | --- | --- | --- | --- |
| [MV-UX-01](PRODUCT-SPEC.md) | Independent document windows | Implemented | Separate windows retain selection/view state; see document workflow. | [Repository evidence](DOCUMENT-WORKFLOW.md) |
| [MV-UX-02](PRODUCT-SPEC.md) | Searchable commands | Not evidenced | Shape/library and recent-file search exist; global command search is not documented. | [Repository evidence](DOCUMENT-WORKFLOW.md) |
| [MV-UX-03](PRODUCT-SPEC.md) | Native dialogs and shortcuts | Implemented | Native menus, dialogs and document actions exist; full manual keyboard qualification remains. | [Repository evidence](DOCUMENT-WORKFLOW.md) |
| [MV-UX-04](PRODUCT-SPEC.md) | Light/Dark/System appearance | Implemented | Appearance is documented; document colors remain separate. | [Repository evidence](DOCUMENT-WORKFLOW.md) |
| [MV-UX-05](PRODUCT-SPEC.md) | Context-sensitive inspectors | Partial | Geometry/style/text inspectors exist; complete mixed-value and units behavior remains. | [Repository evidence](DOCUMENT-WORKFLOW.md) |
| [MV-UX-06](PRODUCT-SPEC.md) | Operation previews and cancellation | Partial | Undo and cancelled gestures exist; general document-wide preview workflow remains. | [Repository evidence](DOCUMENT-WORKFLOW.md) |
| [MV-UX-07](PRODUCT-SPEC.md) | Navigable compatibility pane | Partial | Import/calculation notes exist; complete object navigation and actionable pane remain. | [Repository evidence](DOCUMENT-WORKFLOW.md) |
| [MV-UX-08](PRODUCT-SPEC.md) | Progress and cancellation | Partial | Background VSDX/native open/save and progress exist; complete cancellation coverage remains. | [Repository evidence](DOCUMENT-WORKFLOW.md) |
| [MV-REF-01](PRODUCT-SPEC.md) | Working Windows Visio reference | Blocked | Latest validation notes report no installed/registered Visio; not reinspected this turn. | [Repository evidence](WINDOWS-VALIDATION.md) |
| [MV-REF-02](PRODUCT-SPEC.md) | Complete reference inventory | Partial | Library/formula inventories exist; full command/API/filter/solution inventory remains. | [Repository evidence](WINDOWS-VALIDATION.md) |
| [MV-REF-03](PRODUCT-SPEC.md) | Independent acceptance fixtures | Partial | Public synthetic corpus and independent parsing exist; Visio-authored/reference expectations remain. | [Repository evidence](WINDOWS-VALIDATION.md) |
| [MV-REF-04](PRODUCT-SPEC.md) | Separate compatibility evidence | Partial | Documentation distinguishes preservation and parity; complete per-feature evidence ledger remains. | [Repository evidence](WINDOWS-VALIDATION.md) |
| [MV-REF-05](PRODUCT-SPEC.md) | Scope and applicability control | Partial | Full target and unresolved gaps are documented; exhaustive applicability denominator remains. | [Repository evidence](WINDOWS-VALIDATION.md) |
| [MV-DOC-01](PRODUCT-SPEC.md) | Blank/template drawing creation | Partial | Built-in and imported templates work; full defaults/units/solution behavior remains. | [Repository evidence](DOCUMENT-WORKFLOW.md) |
| [MV-DOC-02](PRODUCT-SPEC.md) | Recent and pinned drawings | Partial | Recents/pinning exist; complete Locate/Remove missing-file recovery is not documented. | [Repository evidence](DOCUMENT-WORKFLOW.md) |
| [MV-DOC-03](PRODUCT-SPEC.md) | Open/read-only/duplicate handling | Partial | Duplicate opens activate existing windows; explicit read-only and complete format handling remain. | [Repository evidence](DOCUMENT-WORKFLOW.md) |
| [MV-DOC-04](PRODUCT-SPEC.md) | Atomic and failure-safe saving | Partial | NSDocument saving and safe-failure tests exist; complete interruption/disk-full fault qualification remains. | [Repository evidence](DOCUMENT-WORKFLOW.md) |
| [MV-DOC-05](PRODUCT-SPEC.md) | Background snapshot saving | Implemented | Immutable snapshots preserve edits made while saving; documented/tested locally. | [Repository evidence](DOCUMENT-WORKFLOW.md) |
| [MV-DOC-06](PRODUCT-SPEC.md) | Save/Save As/export separation | Implemented | In-place Save, separate Save As and export workflows are documented. | [Repository evidence](DOCUMENT-WORKFLOW.md) |
| [MV-DOC-07](PRODUCT-SPEC.md) | Autosave and crash recovery | Unverified | NSDocument autosave is enabled; complete crash/relaunch checkpoint journey is unverified. | [Repository evidence](DOCUMENT-WORKFLOW.md) |
| [MV-DOC-08](PRODUCT-SPEC.md) | External change conflicts | Unverified | File modification metadata is retained; full competing-writer conflict test is unverified. | [Repository evidence](DOCUMENT-WORKFLOW.md) |
| [MV-DOC-09](PRODUCT-SPEC.md) | Undo and redo | Implemented | Snapshot-based undo/redo is documented and tested for supported edits. | [Repository evidence](DOCUMENT-WORKFLOW.md) |
| [MV-DOC-10](PRODUCT-SPEC.md) | Versioned native storage | Implemented | Multiple metadata versions are read; compact migration occurs on save. | [Repository evidence](DOCUMENT-WORKFLOW.md) |
| [MV-EDT-01](PRODUCT-SPEC.md) | Insert/copy/paste/delete | Partial | Common operations work; all inherited/cross-document dependencies remain incomplete. | [Repository evidence](COMPATIBILITY.md) |
| [MV-EDT-02](PRODUCT-SPEC.md) | Multiple and nested selection | Partial | Shift/marquee and group-child selection exist; complete locked/hidden object policy remains. | [Repository evidence](COMPATIBILITY.md) |
| [MV-EDT-03](PRODUCT-SPEC.md) | Move/resize/rotate/flip | Partial | Common transforms exist; full signed/singular/nested/sheared behavior remains. | [Repository evidence](COMPATIBILITY.md) |
| [MV-EDT-04](PRODUCT-SPEC.md) | Align/distribute/order | Partial | Common alignment/arrangement exists; complete reference bounds/glue behavior remains. | [Repository evidence](COMPATIBILITY.md) |
| [MV-EDT-05](PRODUCT-SPEC.md) | Guides/grid/snap/glue | Partial | Grid and layer-aware shape snapping exist; full guides/origins/outline snapping remain. | [Repository evidence](COMPATIBILITY.md) |
| [MV-EDT-06](PRODUCT-SPEC.md) | Nested groups and ungrouping | Partial | Nested groups and cached-master ungrouping exist; complete inheritance/transforms remain. | [Repository evidence](COMPATIBILITY.md) |
| [MV-EDT-07](PRODUCT-SPEC.md) | Editable geometry and curves | Partial | Many paths/curves/NURBS work; complete row, boundary and drawing-tool coverage remains. | [Repository evidence](COMPATIBILITY.md) |
| [MV-EDT-08](PRODUCT-SPEC.md) | Boolean shape operations | Not implemented | Union/intersection/subtraction and related operations are explicit outstanding geometry work. | [Repository evidence](COMPATIBILITY.md) |
| [MV-EDT-09](PRODUCT-SPEC.md) | Fills/lines/effects | Partial | Basic formatting works; full gradients/patterns/shadows/theme effects remain. | [Repository evidence](COMPATIBILITY.md) |
| [MV-EDT-10](PRODUCT-SPEC.md) | Shape protections | Partial | Guarded-cell behavior exists; full selection/move/resize/rotation protection settings remain. | [Repository evidence](COMPATIBILITY.md) |
| [MV-EDT-11](PRODUCT-SPEC.md) | Document find and replace | Not evidenced | Library search exists; full text/shape/data document search and replacement are not documented. | [Repository evidence](COMPATIBILITY.md) |
| [MV-EDT-12](PRODUCT-SPEC.md) | Images and foreign graphics | Partial | Embedded image import/export/insertion exists; crop/linked graphics/metafile coverage remains. | [Repository evidence](COMPATIBILITY.md) |
| [MV-TXT-01](PRODUCT-SPEC.md) | Mixed rich text | Partial | Selected shape text formatting works; complete connector-rich-text behavior remains. | [Repository evidence](RICH-TEXT.md) |
| [MV-TXT-02](PRODUCT-SPEC.md) | Paragraphs/tabs/bullets | Partial | Alignment and cached paragraph properties exist; full tabs/bullets/layout remain. | [Repository evidence](RICH-TEXT.md) |
| [MV-TXT-03](PRODUCT-SPEC.md) | Independent text blocks | Partial | Imported blocks/margins/transforms exist; complete interactive layout and parity remain. | [Repository evidence](RICH-TEXT.md) |
| [MV-TXT-04](PRODUCT-SPEC.md) | Text fields and formatting | Partial | Supported page/data/dimension/formula fields work; full functions/format pictures remain. | [Repository evidence](RICH-TEXT.md) |
| [MV-TXT-05](PRODUCT-SPEC.md) | Unicode/RTL/IME text | Unverified | Unicode fixtures exist; full RTL/IME/complex text acceptance is unverified. | [Repository evidence](RICH-TEXT.md) |
| [MV-TXT-06](PRODUCT-SPEC.md) | Missing-font handling | Partial | Font resolution/fallback exists; user-visible reporting and substitution parity remain. | [Repository evidence](RICH-TEXT.md) |
| [MV-TXT-07](PRODUCT-SPEC.md) | Text-driven dimensions | Partial | Native measurement and bounded text-context calculations exist; complete semantics remain. | [Repository evidence](RICH-TEXT.md) |
| [MV-TXT-08](PRODUCT-SPEC.md) | Spelling and proofing | Not evidenced | A complete language/proofing workflow is not documented. | [Repository evidence](RICH-TEXT.md) |
| [MV-CON-01](PRODUCT-SPEC.md) | Connector styles and arrows | Partial | Connectors, labels and selected arrows exist; full styles and endpoint editing remain. | [Repository evidence](ORTHOGONAL-ROUTING.md) |
| [MV-CON-02](PRODUCT-SPEC.md) | Static versus dynamic glue | Partial | Port-specific glue exists; full dynamic attachment behavior remains. | [Repository evidence](ORTHOGONAL-ROUTING.md) |
| [MV-CON-03](PRODUCT-SPEC.md) | Connection-point editing | Partial | Named/indexed point editing and snapping exist; direction/type and extended semantics remain. | [Repository evidence](ORTHOGONAL-ROUTING.md) |
| [MV-CON-04](PRODUCT-SPEC.md) | Routing and route handles | Partial | Straight/cached routes and bounded orthogonal routing exist; curved routing/handles remain. | [Repository evidence](ORTHOGONAL-ROUTING.md) |
| [MV-CON-05](PRODUCT-SPEC.md) | Crossings/jumps/labels | Partial | Labels and basic styles exist; line jumps, full rounding and placement rules remain. | [Repository evidence](ORTHOGONAL-ROUTING.md) |
| [MV-CON-06](PRODUCT-SPEC.md) | Auto-connect/split/heal | Not implemented | Basic connector creation exists; structured insertion/deletion behavior remains. | [Repository evidence](ORTHOGONAL-ROUTING.md) |
| [MV-CON-07](PRODUCT-SPEC.md) | Routing across hierarchy | Partial | Grouped/scaled connector transforms exist; complete container/lane rules remain. | [Repository evidence](ORTHOGONAL-ROUTING.md) |
| [MV-CON-08](PRODUCT-SPEC.md) | Automatic diagram layout | Partial | Basic arrangement exists; full hierarchical/tree/flowchart layout engines remain. | [Repository evidence](ORTHOGONAL-ROUTING.md) |
| [MV-CON-09](PRODUCT-SPEC.md) | Deterministic layout | Partial | Orthogonal router has deterministic bounded candidates; full diagram-layout contract remains. | [Repository evidence](ORTHOGONAL-ROUTING.md) |
| [MV-CON-10](PRODUCT-SPEC.md) | Preserve imported routes | Implemented | Cached routes retain their existing handling rather than universal automatic rerouting. | [Repository evidence](ORTHOGONAL-ROUTING.md) |
| [MV-LIB-01](PRODUCT-SPEC.md) | Stencil browsing and reuse | Partial | Searchable folder browser and master insertion exist; full pin/search/library UX remains. | [Repository evidence](STENCIL-LIBRARIES.md) |
| [MV-LIB-02](PRODUCT-SPEC.md) | Master identity and behavior | Partial | Master trees/overrides are retained in part; complete identity/behavior remains. | [Repository evidence](STENCIL-LIBRARIES.md) |
| [MV-LIB-03](PRODUCT-SPEC.md) | Master inheritance and updates | Partial | Selected inheritance/local overrides work; live master edits/instance updates remain. | [Repository evidence](STENCIL-LIBRARIES.md) |
| [MV-LIB-04](PRODUCT-SPEC.md) | Custom stencil/master editing | Partial | Selection export exists; original stencil editing and complete master management remain. | [Repository evidence](STENCIL-LIBRARIES.md) |
| [MV-LIB-05](PRODUCT-SPEC.md) | Selection-to-master export | Partial | VSSX export includes supported content/dependencies; full advanced behavior remains. | [Repository evidence](STENCIL-LIBRARIES.md) |
| [MV-LIB-06](PRODUCT-SPEC.md) | Template creation and reuse | Partial | VSTX opening/export exists; complete defaults and solution metadata behavior remains. | [Repository evidence](STENCIL-LIBRARIES.md) |
| [MV-LIB-07](PRODUCT-SPEC.md) | Master replacement and updates | Partial | Document masters are imported; full replacement/remapping/live update behavior remains. | [Repository evidence](STENCIL-LIBRARIES.md) |
| [MV-LIB-08](PRODUCT-SPEC.md) | Themes/variants/quick styles | Partial | Selected theme/variation calculations exist; full rendering and override semantics remain. | [Repository evidence](STENCIL-LIBRARIES.md) |
| [MV-LIB-09](PRODUCT-SPEC.md) | Library distribution rights | Unverified | Dependency licenses are recorded; complete redistributable content/provenance review is unverified. | [Repository evidence](STENCIL-LIBRARIES.md) |
| [MV-SHS-01](PRODUCT-SPEC.md) | ShapeSheet object coverage | Partial | Shape/page and related cells exist; complete owner/section/row semantics remain. | [Repository evidence](SHAPESHEET-AUDIT.md) |
| [MV-SHS-02](PRODUCT-SPEC.md) | Expression parser and units | Partial | Bounded typed expressions and units work; full language/coercion/errors remain. | [Repository evidence](SHAPESHEET-AUDIT.md) |
| [MV-SHS-03](PRODUCT-SPEC.md) | Names and cross-references | Partial | Many sheet/master references work; exhaustive escaping/renaming/context coverage remains. | [Repository evidence](SHAPESHEET-AUDIT.md) |
| [MV-SHS-04](PRODUCT-SPEC.md) | Incremental recalculation | Partial | Changed-page calculation/caches and errors exist; complete dependency semantics remain. | [Repository evidence](SHAPESHEET-AUDIT.md) |
| [MV-SHS-05](PRODUCT-SPEC.md) | Guards and redirected references | Partial | GUARD/SETATREF-related support exists; complete inherited/context behavior remains. | [Repository evidence](SHAPESHEET-AUDIT.md) |
| [MV-SHS-06](PRODUCT-SPEC.md) | Complete function library | Partial | Selected numeric/string/text/theme functions work; the full function catalog remains incomplete. | [Repository evidence](SHAPESHEET-AUDIT.md) |
| [MV-SHS-07](PRODUCT-SPEC.md) | Control handles and tooltips | Partial | Native handles, constraints and supported live tooltips work; full dynamics/gluing remain. | [Repository evidence](SHAPESHEET-AUDIT.md) |
| [MV-SHS-08](PRODUCT-SPEC.md) | Actions/events/commands | Not implemented | Imported actions and macros do not execute; compatible controlled action/event behavior remains. | [Repository evidence](SHAPESHEET-AUDIT.md) |
| [MV-SHS-09](PRODUCT-SPEC.md) | ShapeSheet editor | Partial | Typed cell/geometry/control editors exist; full sections/rows/navigation remain. | [Repository evidence](SHAPESHEET-AUDIT.md) |
| [MV-SHS-10](PRODUCT-SPEC.md) | Unsupported-formula diagnostics | Partial | Source/cached values and calculation issues are preserved; comprehensive stale-state UX remains. | [Repository evidence](SHAPESHEET-AUDIT.md) |
| [MV-SHS-11](PRODUCT-SPEC.md) | Function/cell coverage registry | Partial | Occurrence/syntax audits exist; complete context/version semantic coverage registry remains. | [Repository evidence](SHAPESHEET-AUDIT.md) |
| [MV-PAG-01](PRODUCT-SPEC.md) | Page management | Partial | Add/duplicate/rename/resize/delete/navigation exist; full ordering/dependency behavior remains. | [Repository evidence](COMPATIBILITY.md) |
| [MV-PAG-02](PRODUCT-SPEC.md) | Backgrounds and page fields | Partial | Shared/nested backgrounds and selected fields work; dynamic foreground context remains incomplete. | [Repository evidence](COMPATIBILITY.md) |
| [MV-PAG-03](PRODUCT-SPEC.md) | Layer properties | Partial | Visibility/lock/print/snap/glue/color work in part; multi-layer/active/formula semantics remain. | [Repository evidence](COMPATIBILITY.md) |
| [MV-PAG-04](PRODUCT-SPEC.md) | Behavioral containers | Not implemented | Groups/general primitives exist; true membership/heading/fit/locking solution behavior remains. | [Repository evidence](COMPATIBILITY.md) |
| [MV-PAG-05](PRODUCT-SPEC.md) | Ordered lists/lanes/phases | Not implemented | Simple swimlane graphics exist; ordered membership/reflow/phase behavior remains. | [Repository evidence](COMPATIBILITY.md) |
| [MV-PAG-06](PRODUCT-SPEC.md) | Drawing/paper/print scale | Partial | Drawing scale and physical rendering work; full unit/print-scale workflow remains. | [Repository evidence](COMPATIBILITY.md) |
| [MV-PAG-07](PRODUCT-SPEC.md) | Dimension and measurement tools | Not implemented | Measured scale exists; specialist dimension/area/length tools remain. | [Repository evidence](COMPATIBILITY.md) |
| [MV-PAG-08](PRODUCT-SPEC.md) | Page sizing and tiling | Partial | Page setup exists; complete auto-size, margins and tiled printing remain. | [Repository evidence](COMPATIBILITY.md) |
| [MV-DAT-01](PRODUCT-SPEC.md) | Typed Shape Data | Partial | Typed editing/validation exists; full locale/date/currency/display formats remain. | [Repository evidence](SHAPE-DATA.md) |
| [MV-DAT-02](PRODUCT-SPEC.md) | Tabular data import | Not implemented | No full external-data mapping/import workflow is documented. | [Repository evidence](SHAPE-DATA.md) |
| [MV-DAT-03](PRODUCT-SPEC.md) | Keyed row-to-shape links | Not implemented | External record linking remains outstanding. | [Repository evidence](SHAPE-DATA.md) |
| [MV-DAT-04](PRODUCT-SPEC.md) | Data refresh/conflict preview | Not implemented | External refresh and change reconciliation remain outstanding. | [Repository evidence](SHAPE-DATA.md) |
| [MV-DAT-05](PRODUCT-SPEC.md) | Data graphics and legends | Not implemented | Data bars/icons/color-by-value solution behavior remains outstanding. | [Repository evidence](SHAPE-DATA.md) |
| [MV-DAT-06](PRODUCT-SPEC.md) | Shape-data reports | Not implemented | Filtered/grouped/summarized reporting remains outstanding. | [Repository evidence](SHAPE-DATA.md) |
| [MV-DAT-07](PRODUCT-SPEC.md) | Data snapshots and freshness | Not implemented | External-data snapshot/freshness workflow remains outstanding. | [Repository evidence](SHAPE-DATA.md) |
| [MV-DAT-08](PRODUCT-SPEC.md) | External source connectors | Not implemented | Excel/database/SharePoint/ODBC/OLEDB adapters or bridges remain outstanding. | [Repository evidence](SHAPE-DATA.md) |
| [MV-DAT-09](PRODUCT-SPEC.md) | Diagram generation from tables | Planned extension | Proposed extension; no completed generation/reconciliation workflow is documented. | [Repository evidence](SHAPE-DATA.md) |
| [MV-DAT-10](PRODUCT-SPEC.md) | Two-way table synchronization | Planned extension | Proposed extension; no completed two-way workflow is documented. | [Repository evidence](SHAPE-DATA.md) |
| [MV-SOL-01](PRODUCT-SPEC.md) | Basic flowcharts | Partial | Basic flowchart shapes/connectors exist; full subprocess/off-page solution behavior remains. | [Repository evidence](COMPATIBILITY.md) |
| [MV-SOL-02](PRODUCT-SPEC.md) | Cross-functional flowcharts | Partial | Swimlane drawing primitives exist; lane/phase semantics and reflow remain. | [Repository evidence](COMPATIBILITY.md) |
| [MV-SOL-03](PRODUCT-SPEC.md) | BPMN solution and validation | Not implemented | Imported shapes may display; native BPMN attributes/rules/solution workflow remain. | [Repository evidence](COMPATIBILITY.md) |
| [MV-SOL-04](PRODUCT-SPEC.md) | UML diagram solutions | Not implemented | Library content may import; notation-specific behaviors are not implemented. | [Repository evidence](COMPATIBILITY.md) |
| [MV-SOL-05](PRODUCT-SPEC.md) | ERD/database solutions | Not implemented | General shapes/library import do not provide complete keys/cardinality/model behavior. | [Repository evidence](COMPATIBILITY.md) |
| [MV-SOL-06](PRODUCT-SPEC.md) | Network and rack solutions | Partial | Basic network template/primitives exist; equipment/port/rack/report semantics remain. | [Repository evidence](COMPATIBILITY.md) |
| [MV-SOL-07](PRODUCT-SPEC.md) | Cloud/infrastructure libraries | Partial | Installer library parsing exists; complete versioned content and behavior qualification remain. | [Repository evidence](COMPATIBILITY.md) |
| [MV-SOL-08](PRODUCT-SPEC.md) | Organization charts | Partial | Basic organization template exists; data import/hierarchy engine/photos workflow remains. | [Repository evidence](COMPATIBILITY.md) |
| [MV-SOL-09](PRODUCT-SPEC.md) | Floor plans | Partial | Scale and engineering masters import; architectural attachment/measurement tools remain. | [Repository evidence](COMPATIBILITY.md) |
| [MV-SOL-10](PRODUCT-SPEC.md) | Engineering diagrams | Partial | Engineering stencils can import as content; specialist rules/data/commands remain. | [Repository evidence](COMPATIBILITY.md) |
| [MV-SOL-11](PRODUCT-SPEC.md) | Timeline/calendar/Gantt/PERT | Not implemented | Imported graphics are not complete date/task-driven solution workflows. | [Repository evidence](COMPATIBILITY.md) |
| [MV-SOL-12](PRODUCT-SPEC.md) | Business/quality/process families | Partial | Installer templates parse; family-specific workflow behavior remains unimplemented. | [Repository evidence](COMPATIBILITY.md) |
| [MV-SOL-13](PRODUCT-SPEC.md) | Wireframes and specialist templates | Partial | Content may import; control/list/solution behaviors remain incomplete. | [Repository evidence](COMPATIBILITY.md) |
| [MV-SOL-14](PRODUCT-SPEC.md) | Diagram rule validation | Not implemented | Calculation/geometry diagnostics exist; semantic diagram rule sets/issues workflow remain. | [Repository evidence](COMPATIBILITY.md) |
| [MV-SOL-15](PRODUCT-SPEC.md) | Database reverse engineering | Not implemented | No database schema/driver import workflow is documented; baseline applicability also needs verification. | [Repository evidence](COMPATIBILITY.md) |
| [MV-SOL-16](PRODUCT-SPEC.md) | Modern cloud/Kubernetes content | Planned extension | Newer versioned libraries are extension scope; not independently qualified. | [Repository evidence](COMPATIBILITY.md) |
| [MV-IO-01](PRODUCT-SPEC.md) | VSDX read/write | Partial | Public structured read/write and patching exist; full semantics/Windows acceptance remain. | [Repository evidence](COMPATIBILITY.md) |
| [MV-IO-02](PRODUCT-SPEC.md) | Binary VSD read/write | Experimental | Graphics import and v11 writer exist; complete binary semantics and Visio acceptance remain. | [Repository evidence](COMPATIBILITY.md) |
| [MV-IO-03](PRODUCT-SPEC.md) | Preserve unchanged package parts | Implemented | Unchanged source part preservation/selective patching is documented/tested locally; not full feature parity. | [Repository evidence](COMPATIBILITY.md) |
| [MV-IO-04](PRODUCT-SPEC.md) | Drawing/stencil/template formats | Partial | VSDX/VSSX/VSTX subsets work; legacy stencil/template writing and full behavior remain. | [Repository evidence](COMPATIBILITY.md) |
| [MV-IO-05](PRODUCT-SPEC.md) | Macro-enabled file workflows | Not implemented | Opaque source retention is possible; supported macro-enabled editing/signatures/execution remain. | [Repository evidence](COMPATIBILITY.md) |
| [MV-IO-06](PRODUCT-SPEC.md) | SVG/raster/PDF export | Partial | PNG/SVG/PDF and all-page PDF exist; full option/filter/appearance coverage remains. | [Repository evidence](COMPATIBILITY.md) |
| [MV-IO-07](PRODUCT-SPEC.md) | Print ranges/all pages/tiling | Partial | Current-page printing exists; complete range/all-page/tiled printing remains. | [Repository evidence](COMPATIBILITY.md) |
| [MV-IO-08](PRODUCT-SPEC.md) | CAD and graphics import | Partial | Supported images/SVG and graphics conversion exist; CAD workflows/version matrix remain. | [Repository evidence](COMPATIBILITY.md) |
| [MV-IO-09](PRODUCT-SPEC.md) | Metafiles and foreign objects | Not implemented | WMF/EMF/OLE/linked-object rendering/editing remain explicit gaps. | [Repository evidence](COMPATIBILITY.md) |
| [MV-IO-10](PRODUCT-SPEC.md) | Pre-save compatibility report | Partial | Import/calculation notes exist; comprehensive save-impact preview and safe-copy UX remain. | [Repository evidence](COMPATIBILITY.md) |
| [MV-IO-11](PRODUCT-SPEC.md) | Public-content independence | Partial | Tests strip native metadata for supported output; all claimed feature semantics remain unverified. | [Repository evidence](COMPATIBILITY.md) |
| [MV-IO-12](PRODUCT-SPEC.md) | Legacy XML/other format filters | Not implemented | Complete VDX/VSX/VTX and filter inventory/read/write qualification remains. | [Repository evidence](COMPATIBILITY.md) |
| [MV-AUT-01](PRODUCT-SPEC.md) | Stable local object API | Partial | CLI/model operations exist; versioned external document/page/shape/cell API remains. | [Repository evidence](COMPATIBILITY.md) |
| [MV-AUT-02](PRODUCT-SPEC.md) | Headless conversion/render/export | Partial | Conversion/render/PDF/profile commands exist; complete inspect/exit-code/safety contract remains. | [Repository evidence](COMPATIBILITY.md) |
| [MV-AUT-03](PRODUCT-SPEC.md) | Baseline automation inventory | Not implemented | Complete API-member/event/transaction mapping remains outstanding. | [Repository evidence](COMPATIBILITY.md) |
| [MV-AUT-04](PRODUCT-SPEC.md) | VBA/COM compatibility | Not implemented | No compatible execution runtime or qualified bridge is documented. | [Repository evidence](COMPATIBILITY.md) |
| [MV-AUT-05](PRODUCT-SPEC.md) | Windows add-ins/ActiveX | Not implemented | COM/VSTO/VSL/ActiveX/add-in compatibility remains outstanding. | [Repository evidence](COMPATIBILITY.md) |
| [MV-AUT-06](PRODUCT-SPEC.md) | OLE document editing | Not implemented | Linked/embedded OLE activation/editing and bridge behavior remain outstanding. | [Repository evidence](COMPATIBILITY.md) |
| [MV-AUT-07](PRODUCT-SPEC.md) | Baseline Office integrations | Not implemented | End-to-end native/bridge integrations remain outstanding. | [Repository evidence](COMPATIBILITY.md) |
| [MV-AUT-08](PRODUCT-SPEC.md) | Modern Microsoft integrations | Planned extension | Power BI/Teams/Microsoft 365/workflow integrations are unimplemented extension work. | [Repository evidence](COMPATIBILITY.md) |
| [MV-COL-01](PRODUCT-SPEC.md) | Comments/review annotations | Not implemented | Preserved source parts are not an editable comments/review workflow. | [Repository evidence](COMPATIBILITY.md) |
| [MV-COL-02](PRODUCT-SPEC.md) | Cloud-synced file safety | Partial | Local file workflows and metadata exist; concurrent-writer/sync conflict safety is unverified. | [Repository evidence](COMPATIBILITY.md) |
| [MV-COL-03](PRODUCT-SPEC.md) | Baseline sharing/coauthoring | Not implemented | Applicability/prerequisites and compatible workflows remain outstanding. | [Repository evidence](COMPATIBILITY.md) |
| [MV-COL-04](PRODUCT-SPEC.md) | Native live collaboration | Planned extension | No shared session/permissions/presence implementation is documented. | [Repository evidence](COMPATIBILITY.md) |
| [MV-COL-05](PRODUCT-SPEC.md) | Offline collaborative reconciliation | Planned extension | No convergence/reconnect/selective collaborative undo implementation is documented. | [Repository evidence](COMPATIBILITY.md) |
| [MV-ACC-01](PRODUCT-SPEC.md) | VoiceOver-accessible editor | Partial | Some controls expose accessibility metadata; complete semantic canvas/tree workflow remains. | [Repository evidence](COMPATIBILITY.md) |
| [MV-ACC-02](PRODUCT-SPEC.md) | Keyboard-only authoring | Partial | Many shortcuts exist; complete no-pointer creation/connection/export journey is unverified. | [Repository evidence](COMPATIBILITY.md) |
| [MV-ACC-03](PRODUCT-SPEC.md) | Accessible diagram content | Not evidenced | Complete alt-text, reading-order and accessibility inspection workflow is not documented. | [Repository evidence](COMPATIBILITY.md) |
| [MV-SEC-01](PRODUCT-SPEC.md) | Bounded untrusted input parsing | Partial | ZIP/XML/path/metadata limits exist; complete compound/formula/resource adversarial coverage remains. | [Repository evidence](COMPATIBILITY.md) |
| [MV-SEC-02](PRODUCT-SPEC.md) | Disable automatic external execution | Partial | Macros/actions/data links do not execute; comprehensive execution/network policy acceptance remains. | [Repository evidence](COMPATIBILITY.md) |
| [MV-SEC-03](PRODUCT-SPEC.md) | Integration credentials in Keychain | Not implemented | Update-signing credentials use Keychain; user-facing data-connector credentials are not implemented. | [Repository evidence](COMPATIBILITY.md) |
| [MV-SEC-04](PRODUCT-SPEC.md) | Rights-managed/protected files | Not implemented | No qualified IRM/protected-document editing mechanism is documented. | [Repository evidence](COMPATIBILITY.md) |
| [MV-SEC-05](PRODUCT-SPEC.md) | Private/local diagnostics | Partial | Content-minimal local timing reports exist; complete telemetry/content audit remains. | [Repository evidence](COMPATIBILITY.md) |
| [MV-OPS-01](PRODUCT-SPEC.md) | Signed/notarized distribution | Partial | Notarized local releases and license records exist; CI signing/notarization is not fully configured. | [Repository evidence](DISTRIBUTION.md) |
| [MV-OPS-02](PRODUCT-SPEC.md) | Authenticated application updates | Partial | Signed Sparkle feed/archive checks exist; real end-to-end installation remains unexercised in docs. | [Repository evidence](DISTRIBUTION.md) |
| [MV-OPS-03](PRODUCT-SPEC.md) | Published platform support matrix | Partial | Apple Silicon/macOS 27 requirement is documented; broader matrix/testing remains. | [Repository evidence](DISTRIBUTION.md) |
| [MV-OPS-04](PRODUCT-SPEC.md) | Exportable support diagnostics | Partial | Open/launch/performance/verification reports exist; consolidated user-facing support report remains. | [Repository evidence](DISTRIBUTION.md) |
| [MV-NFR-01](PRODUCT-SPEC.md) | No lost edits/recovery qualification | Unverified | Snapshot/safe-failure tests exist; full disk/conflict/crash fault matrix has not been established. | [Repository evidence](OPEN-PERFORMANCE.md) |
| [MV-NFR-02](PRODUCT-SPEC.md) | Interaction performance targets | Unverified | Specific heartbeat measurements exist; defined 1,000-shape drag/pan p95 targets are unqualified. | [Repository evidence](OPEN-PERFORMANCE.md) |
| [MV-NFR-03](PRODUCT-SPEC.md) | Standard-file opening targets | Unverified | Local large-file measurements exist; specified 30-run standard-corpus p95 qualification is absent. | [Repository evidence](OPEN-PERFORMANCE.md) |
| [MV-NFR-04](PRODUCT-SPEC.md) | Large-file loading targets | Unverified | Background open exists; exact large fixture/cancellation/p95 target is unqualified. | [Repository evidence](OPEN-PERFORMANCE.md) |
| [MV-NFR-05](PRODUCT-SPEC.md) | Save performance targets | Unverified | One large drawing measured 4.46-second save/12-ms main-loop gap; defined corpus/p95 targets are unqualified. | [Repository evidence](OPEN-PERFORMANCE.md) |
| [MV-NFR-06](PRODUCT-SPEC.md) | Memory/leak targets | Unverified | Individual memory samples exist; standard/large/20-cycle thresholds are unqualified. | [Repository evidence](OPEN-PERFORMANCE.md) |
| [MV-NFR-07](PRODUCT-SPEC.md) | Geometry/print tolerances | Unverified | Scale/geometry tests exist; specified numeric/calibrated-print acceptance is unqualified. | [Repository evidence](OPEN-PERFORMANCE.md) |
| [MV-NFR-08](PRODUCT-SPEC.md) | Reference visual qualification | Blocked | Local renders exist; full same-font Visio comparison depends on working reference environment. | [Repository evidence](OPEN-PERFORMANCE.md) |
| [MV-NFR-09](PRODUCT-SPEC.md) | Locale/localization qualification | Unverified | Selected Unicode/type tests exist; complete decimal-comma/date/long-label matrix is unqualified. | [Repository evidence](OPEN-PERFORMANCE.md) |
| [MV-NFR-10](PRODUCT-SPEC.md) | OS/architecture qualification | Unverified | Current distribution is narrow; complete promised-platform release matrix is unqualified. | [Repository evidence](OPEN-PERFORMANCE.md) |

Additional evidence: [README](../README.md), [release 0.23.3](RELEASE-0.23.3.md), [background save implementation](../Sources/MacVisio/Document.swift), [native menus](../Sources/MacVisio/main.swift), [editor accessibility/inspectors](../Sources/MacVisio/EditorUI.swift), [window workflow](../Sources/MacVisio/DocumentWorkflow.swift).

The specification and its requirements JSON remain the canonical intended scope. This status report is a separate snapshot and does not alter their acceptance criteria.
