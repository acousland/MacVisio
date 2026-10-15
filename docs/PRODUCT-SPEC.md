# MacVisio product specification

Version 1.0 · Research date: 16 October 2026 · Status: specification draft for implementation planning

**Product:** a native macOS professional diagramming application, using Microsoft Visio as the functional and file-interchange benchmark.

**Primary compatibility baseline:** Microsoft Visio Professional 2019 for Windows, matching the existing project objective. Current Visio Professional 2024, Plan 2 and web documentation inform a separately identified extension roadmap. This document does not replace the full compatibility objective with a smaller editor milestone.

**Evidence boundary:** Microsoft public documentation and the repository were reviewed. No running Microsoft Visio instance was used for this research. Existing implementation descriptions below are repository-reported capabilities, not a fresh execution audit. All requirements, UI choices, architecture proposals and numerical targets are MacVisio design decisions unless explicitly described as Microsoft behavior.

The [research and source register](PRODUCT-RESEARCH.md) records citations, inconsistencies, limitations and local evidence. The [requirements register](product-requirements.json) is a machine-readable extraction of the normative requirement tables below.

## 1. Product purpose

MacVisio lets professionals create, understand, maintain and exchange structured diagrams on macOS without requiring a Windows desktop for everyday work. Its central promise is trustworthy editing: a drawing should retain its structure, appearance, data and intended behavior through editing and exchange with the supported Visio versions.

The target product combines a responsive Mac document application with a structured drawing engine, reusable intelligent shapes, specialist diagram solutions and explicit compatibility reporting. A drawing that looks correct while losing its formulas, connectors or data does not satisfy that promise.

### 1.1 Product outcomes

1. A Mac user can open a supported Visio drawing, make a normal professional edit, save it and hand it back to a Windows colleague.
2. A process analyst can build a swimlane or BPMN diagram whose relationships survive layout changes and validation.
3. An architect can maintain large network, cloud, UML and entity-relationship diagrams using reusable shapes and meaningful connections.
4. A facilities or engineering user can work in real dimensions and produce correctly scaled output.
5. An organization can maintain templates, custom stencils, linked data and repeatable diagram workflows without hidden degradation.

### 1.2 Product principles

- Preserve the user's source and expose the consequences of unsupported edits.
- Treat shape behavior, structure and drawing semantics as first-class product features.
- Make the common operation direct; expose precision through inspectors and ShapeSheet.
- Keep local creation, editing, saving and export usable offline.
- Adapt interaction to macOS conventions while retaining recognizable Visio concepts.
- Publish compatibility by version, format and workflow, with evidence.

### 1.3 Intended positioning

Primary positioning: a native Mac workspace for professionals who exchange Visio files and need more than browser diagramming. Initial adoption should focus on mixed Mac/Windows teams and users with substantial existing drawing libraries. Research here establishes the benchmark's capabilities; it does not establish demand, market size or willingness to pay. Those need customer interviews and product trials.

No subscription price or commercial license model is set by this specification. Packaging decisions must not prevent users from reading or exporting their own documents after a trial or entitlement expires.

### 1.4 Product validation targets

These are proposed research targets, not observed results: in a study with at least 12 representative users, at least 90% should complete J01/J02 without assistance; a first-time diagrammer should create and export a five-step connected process in a median of five minutes after a short introduction. Existing Visio users should be able to find shape data, page scale and connection-point editing without help in at least 80% of trials. Record failures and task times by persona; do not average away specialist failures. Validate demand and compatibility on permissioned real documents before using trial conversion or sales projections to justify expansion.

## 2. Benchmark and scope contract

Microsoft distinguishes a basic Visio experience in eligible Microsoft 365 plans, a fuller web experience in Plan 1, and a subscription including the Windows desktop application in Plan 2. Standard and Professional 2024 are separate perpetual editions. Professional is the relevant specialist-diagram benchmark. [Microsoft edition comparison][S01]

Microsoft documents browser-based Visio use on Mac. MacVisio's proposed distinction is a native desktop application with local professional workflows. [Visio on Mac FAQ][S02]

| Benchmark | Use in this specification | Boundary |
| --- | --- | --- |
| Visio Professional 2019, exact installed build | Mandatory compatibility baseline, including functions and VSD/VSDX read/write | Runtime inventory and differential evidence still required |
| Visio Professional 2024 | Contemporary desktop content and UX reference | Newer content is an extension unless independently present in 2019 |
| Visio Plan 2 | Advanced subscription workflows and integrations reference | Subscription-only features do not automatically become 2019 requirements |
| Visio Plan 1 / web | Collaboration and browser workflow reference | Web feature availability is not a ceiling on desktop requirements |
| Visio Standard | General diagramming reference | Insufficient as the full product target |

Visio 2024 documents expanded visual content, additional Professional Azure/network/software shapes and updated search and appearance. Those inform extensions, not claims that the 2019 baseline included them. [What's new in Visio 2024][S03]

### 2.1 Requirement classification

Every requirement has a scope and a delivery gate:

- **B — Baseline:** needed to satisfy the existing Visio Professional 2019 target, subject to exact-build applicability inventory. Scheduling a B requirement later never makes it optional.
- **N — Native product:** MacVisio-specific requirements for safety, usability, operation and quality.
- **X — Extension:** newer subscription/web capabilities or deliberate improvements beyond the baseline.

**G0:** evidence and inventory. **G1:** dependable general editor. **G2:** intelligent shapes and interchange. **G3:** professional diagram solutions and data. **G4:** complete baseline acceptance, including platform-dependent functions. **GX:** extensions beyond the baseline.

Unless a row specifies otherwise, an editing acceptance case includes undo, redo, save, close and reopen. File-related baseline cases include a public-content-only result and an independent Microsoft Visio round trip. UI presence alone is insufficient evidence. The gate is a proposed earliest qualification gate, not a completion claim or deadline.

### 2.2 Scope boundaries

The full baseline includes document workflows, drawing tools, intelligent shapes, ShapeSheet, masters and stencils, layout, rich text, pages/layers, structured diagrams, data-related professional functions, reporting, print/export, automation and integration functions confirmed in the target build.

Windows-specific mechanisms such as COM, VBA, ActiveX, OLE and add-ins require an explicit native equivalent or compatibility bridge. They remain outstanding baseline obligations wherever the reference inventory confirms them. Equivalent user outcomes do not establish binary add-in or script compatibility. Any decision to remove them from the full target needs an explicit scope amendment.

The product is a diagramming application. General CAD authoring, project resource management, executable BPMN process automation and a full software-model/code-generation environment are not implied merely by importing CAD, drawing Gantt charts, supporting BPMN notation or offering UML templates. If the baseline runtime inventory exposes a related function, record it rather than discarding it through this boundary.

Cloud coauthoring, modern identity/data connectors and AI assistance are extension work unless the reference inventory establishes a baseline obligation. Recreating Microsoft branding or redistributing its commercial content is not a product requirement.

## 3. Users and jobs

| Persona | Primary job | Typical document | Success condition |
| --- | --- | --- | --- |
| Business/process analyst | Explain, improve and govern a process | Flowchart, swimlane, BPMN, value stream | Clear relationships, stable layout, useful validation and easy publication |
| IT/network/cloud architect | Maintain a system's components and dependencies | Network, rack, cloud architecture | Reusable libraries, precise connections and manageable large drawings |
| Software/data architect | Communicate software and information structure | UML, ERD, data flow | Correct notation, editable compartments and relationship semantics |
| Facilities/engineering professional | Describe physical layouts and equipment | Floor plan, electrical, P&ID | Reliable units, measurement, scale and print output |
| Project/operations manager | Explain schedules and operational status | Timeline, Gantt, dashboard | Data-driven labels, dates and refresh without manual redraw |
| Template/solution author | Encode a repeatable visual language | Masters, stencils, templates, ShapeSheet | Reusable behavior and predictable instance updates |
| Reviewer | Understand and comment on a diagram | Any supported drawing | Legible view, navigation, accessible structure and portable exports |
| Enterprise administrator | Deploy and maintain a trusted desktop tool | Application/configuration | Reproducible deployment, documented support and controlled integrations |

### 3.1 Primary end-to-end workflows

| Journey | Required sequence | Failure and recovery contract |
| --- | --- | --- |
| J01 — Edit a colleague's drawing | Open VSDX/VSD → inspect compatibility → edit text and structure → save → colleague edits in Visio | Preserve source; show feature-specific limitations; offer a safe copy when changes would invalidate unsupported content |
| J02 — Create a process | Select template → drop and connect → insert branch → add lanes → align → validate → publish | Preview reflow; keep labels and glue; undo the entire layout change |
| J03 — Reuse an intelligent shape | Open stencil → drop master → resize/control-handle edit → edit data → update master | Retain instance overrides; explain guarded cells; retain identity and formulas |
| J04 — Maintain architecture | Open large multipage document → search → navigate → change component → reroute → export | Work remains responsive; unaffected pages and routes do not change arbitrarily |
| J05 — Produce a scaled plan | Set paper/drawing units → import CAD/reference → place measured shapes → dimension → print at scale | Show scaling preview; identify unsupported CAD entities and fonts; prevent silent unit conversion |
| J06 — Visualize operational data | Import table → map keys/fields → link shapes → style values → refresh → resolve changes | Preview additions/deletions; retain prior snapshot when source is unavailable |
| J07 — Recover work | Edit during background save → interrupt process → relaunch → recover → compare last saved version | Show which edits were saved/recovered; never silently replace a newer external version |
| J08 — Review and hand over | Open → follow page links → inspect data → comment → export/share | File permissions and review identity remain distinct from local drawing edits |

## 4. Product experience

### 4.1 Information architecture

Use a Home window for recent/pinned documents, New, Open, templates and local libraries. Each drawing opens in a native document window. The drawing window contains:

- Title and document state, including save progress and compatibility status when relevant.
- A compact, customizable command ribbon or toolbar: Home, Insert, Design, Data, Process, View and Developer; show contextual solution commands when needed.
- A left Shapes pane with stencil tabs, local search, favorites and document masters.
- A central canvas with rulers, guides, page boundaries, pan/zoom and selection tools.
- A right inspector with Style, Text, Geometry, Shape Data, Connections and Accessibility sections.
- Bottom page navigation, zoom and current units/scale.
- Optional task panes for Layers, External Data, Validation, Comments and ShapeSheet.

The exact arrangement is a MacVisio design proposal. It is not a pixel-level claim about Microsoft's UI. Avoid opening every advanced pane by default. Tooltips explain user outcomes; compatibility reports may expose technical details when they explain a material limitation.

### 4.2 Interaction requirements

| ID | Scope / gate | Requirement | Acceptance evidence |
| --- | --- | --- | --- |
| MV-UX-01 | N / G1 | Keep document state, selection, view position and active tool independent per window. | Switching among three edited drawings preserves each state and routes commands to the active document. |
| MV-UX-02 | N / G1 | Provide searchable commands with enabled/disabled explanations. | A user can find align, connection points and drawing scale without knowing the menu location. |
| MV-UX-03 | N / G1 | Use native file dialogs, standard save/close behavior and discoverable Command-key shortcuts. | Keyboard-only New/Open/Save/Save As/Close/Undo succeeds; typing text never triggers canvas tools. |
| MV-UX-04 | N / G1 | Support Light, Dark and System appearances independently of document colors. | The same file exports identical colors in all appearances; controls and selection remain legible. |
| MV-UX-05 | N / G1 | Show selection context, mixed values and units in inspectors. | Mixed formatting is identified and changing one property preserves unrelated properties. |
| MV-UX-06 | N / G1 | Provide clear, reversible previews for destructive or document-wide operations. | Layout, master replacement and unit changes identify scope; cancel leaves the model untouched. |
| MV-UX-07 | N / G2 | Provide a compatibility pane with page/shape navigation and actionable limitations. | Selecting an issue reveals its object, affected capability and safe alternatives. |
| MV-UX-08 | N / G1 | Make long work cancellable and communicate progress without blocking other documents. | Cancelling an open/import leaves no partial active document; saving another drawing remains possible. |

### 4.3 Core keyboard and pointing behavior

Preserve existing MacVisio shortcuts where established. Command-N opens the chooser; Shift-Command-N creates a blank document; Command-O opens; Command-S saves; Shift-Command-S invokes Save As where the application currently provides it; Command-Z/Shift-Command-Z undo/redo. Native menu labels are the authoritative shortcut listing. Avoid introducing a shortcut that conflicts with an established application command.

Canvas tools support pointer, connector, text, free line and drawing geometry. Escape cancels an in-progress gesture before deselecting. Shift supports additive selection and geometric constraints where appropriate; Option temporarily bypasses snapping, matching existing behavior. Provide keyboard equivalents for insertion, movement, resizing, connection and ordering. Microsoft documents extensive keyboard navigation; exact Mac key mappings are product decisions. [Visio keyboard shortcuts][S04]

## 5. Normative functional requirements

### 5.0 Reference evidence and scope control

| ID | Scope / gate | Requirement | Acceptance evidence |
| --- | --- | --- | --- |
| MV-REF-01 | N / G0 | Establish a working licensed Visio Professional 2019 reference installation with a frozen build and prerequisites. | Record successful application launch, COM activation where needed, locale/fonts and required data/solution dependencies. |
| MV-REF-02 | B / G0 | Inventory every baseline command, template/solution, filter, cell/function and automation surface. | All discovered items have stable inventory IDs, version/edition evidence and a requirement/workflow mapping. |
| MV-REF-03 | N / G0 | Maintain independent reference fixtures and expected semantic/visual outcomes. | Each requirement maps to at least one fixture or explicit non-document check; positive and failure cases have authored expectations. |
| MV-REF-04 | N / G0 | Record preservation, rendering, editing, behavior and interchange evidence separately. | Coverage reports cannot mark full compatibility from a parser result or native-metadata reopen alone. |
| MV-REF-05 | N / G0 | Keep unresolved applicability and scope changes visible. | Unknown prerequisites remain in the denominator; removing a confirmed baseline obligation requires a recorded product-scope decision. |

### 5.1 Documents, persistence and recovery

| ID | Scope / gate | Requirement | Acceptance evidence |
| --- | --- | --- | --- |
| MV-DOC-01 | B / G1 | Create blank drawings and drawings from metric/US/custom templates. | New documents inherit intended pages, styles, masters, scale and defaults without editing the template. |
| MV-DOC-02 | N / G1 | Maintain recent and pinned drawings with missing-file recovery. | A moved/deleted recent file produces Locate/Remove actions without changing other recents. |
| MV-DOC-03 | B / G1 | Open supported documents read/write or read-only, and prevent duplicate writable windows for the same file. | Opening one file twice activates the existing document; a read-only source cannot be overwritten. |
| MV-DOC-04 | N / G1 | Save atomically with original-file preservation on write failure. | Disk-full, permission and interrupted-write cases leave the last valid destination readable. |
| MV-DOC-05 | N / G1 | Save immutable snapshots while retaining edits made during the write. | An edit made after snapshot capture remains dirty and is present after the next successful save. |
| MV-DOC-06 | B / G1 | Support Save, Save As and copy/export with clearly distinct destination semantics. | Save As changes the active destination; exporting a copy does not silently change it. |
| MV-DOC-07 | N / G1 | Provide autosave and crash recovery with explicit recovered-version state. | Forced interruption recovers the last completed recovery checkpoint and identifies unsaved work. |
| MV-DOC-08 | N / G1 | Detect external modification before replacing a file. | A second writer's change offers reload, compare where available, or save copy; it is never silently overwritten. |
| MV-DOC-09 | B / G1 | Support undo/redo for model edits as coherent user actions. | A drag, text commit, import and layout operation each undo without leaving orphaned references. |
| MV-DOC-10 | N / G2 | Version native storage and migrate only during an intentional save. | Older supported documents open read-only without migration; saving produces a documented current version. |

### 5.2 Canvas and shape editing

Microsoft's introductory workflow combines templates, shapes, text and connections. The requirements below extend that foundation into explicit MacVisio behavior. [Beginner tutorial][S05]

| ID | Scope / gate | Requirement | Acceptance evidence |
| --- | --- | --- | --- |
| MV-EDT-01 | B / G1 | Insert, duplicate, delete, copy and paste shapes and connectors across pages/documents. | Copies remap IDs and internal references, preserve glue and include required resources. |
| MV-EDT-02 | B / G1 | Support single, range, additive, marquee and nested-group selection. | Locked/hidden objects respect policy; overlapping and nested shapes can be selected predictably. |
| MV-EDT-03 | B / G1 | Move, nudge, resize, rotate, flip and numerically position shapes. | Transform tests preserve off-center pins, signed dimensions and nested coordinate systems. |
| MV-EDT-04 | B / G1 | Align, distribute, space and reorder selected objects. | Operations use defined bounds and retain relative connector attachment and text. |
| MV-EDT-05 | B / G2 | Provide guides, guide points, ruler origins, grid and configurable snap/glue targets. | Snapping visibly identifies its target; bypass and per-layer settings work at multiple zooms. |
| MV-EDT-06 | B / G2 | Support nested grouping, ungrouping and editing members without unintended flattening. | Regrouped/ungrouped drawings retain world geometry, text, data and connections. |
| MV-EDT-07 | B / G2 | Draw and edit lines, rectangles, ellipses, freeform paths, arcs, Béziers, polylines and NURBS. | Representative geometry rows remain editable after public-format exchange. |
| MV-EDT-08 | B / G2 | Support baseline shape operations such as union, combine, fragment, intersect, subtract and trim where reference-confirmed. | Curves, holes, fill rules and text behavior match registered reference fixtures. |
| MV-EDT-09 | B / G2 | Apply fill, line, dash, transparency, gradients, patterns, shadows and supported effects. | Explicit formatting and theme-derived formatting remain distinguishable and round-trip. |
| MV-EDT-10 | B / G2 | Respect selection, resize, movement, rotation and other shape protection settings. | Protected operations explain the constraint and do not overwrite guarded formulas. |
| MV-EDT-11 | B / G1 | Find text, shapes and data across pages, with replace where applicable. | Unicode search reveals the result and preserves unselected rich-text formatting on replace. |
| MV-EDT-12 | B / G2 | Insert, crop, resize and manage supported images and foreign graphic previews. | Image identity, aspect ratio, transparency and intended clipping survive save/reopen. |

### 5.3 Text, fields and formatting

| ID | Scope / gate | Requirement | Acceptance evidence |
| --- | --- | --- | --- |
| MV-TXT-01 | B / G1 | Edit shape, connector and independent text with mixed character formatting. | Multi-run font, weight, color, size and decorations survive selected-text edits and exchange. |
| MV-TXT-02 | B / G2 | Support paragraph alignment, spacing, indentation, tabs, bullets and vertical alignment. | Multiparagraph fixtures match approved text-flow and exported layout expectations. |
| MV-TXT-03 | B / G2 | Move, resize and rotate text blocks independently of shape geometry. | Rotated/grouped/scaled text retains margins, orientation and placement in all render paths. |
| MV-TXT-04 | B / G2 | Provide fields for shape data, document/page information, dates, dimensions and formulas. | Editing referenced data updates the displayed field; source formulas and format pictures persist. |
| MV-TXT-05 | B / G2 | Support Unicode, bidirectional text, international input and reference-confirmed complex text behavior. | IME composition, combining characters, RTL paragraphs and emoji do not corrupt text indexes. |
| MV-TXT-06 | N / G1 | Report missing fonts and apply deterministic substitution. | Opening a missing-font file lists substitutions; save preserves the original requested font metadata. |
| MV-TXT-07 | B / G2 | Provide text measurement and shape-size behavior driven by text/formulas. | Label edits update dependent geometry once without layout oscillation or losing caret state. |
| MV-TXT-08 | B / G2 | Provide reference-confirmed spelling/proofing and text-format defaults. | Language/default changes affect intended text scope and preserve unsupported proofing metadata. |

### 5.4 Connections, routing and automatic layout

Visio distinguishes connecting shapes through automatic connection workflows and explicit connection points. The proposed routing contract adds deterministic behavior and measurable safety. [Add connectors][S06]

| ID | Scope / gate | Requirement | Acceptance evidence |
| --- | --- | --- | --- |
| MV-CON-01 | B / G1 | Create and edit directed/undirected connectors with endpoint, line and arrow styles. | Endpoints, labels and arrowheads remain independently editable after exchange. |
| MV-CON-02 | B / G2 | Distinguish static glue to a port from dynamic attachment to a shape. | Moving/resizing/rotating the shape preserves the chosen attachment semantics. |
| MV-CON-03 | B / G2 | Create/edit named connection points, direction/type and glue rules. | Valid/invalid endpoint combinations behave like reference cases, including group members. |
| MV-CON-04 | B / G2 | Support straight, orthogonal and curved routing with editable route handles. | Manual bends remain stable until explicitly rerouted; auto routes avoid registered obstacles. |
| MV-CON-05 | B / G2 | Provide line jumps, crossing styles, corner rounding and connector label placement. | Crossing changes update jump presentation without modifying graph connectivity. |
| MV-CON-06 | B / G2 | Provide auto-connect, connector splitting and reference-confirmed healing on deletion. | Inserting/removing a process shape updates only intended edges and retains labels/data. |
| MV-CON-07 | B / G2 | Route correctly through groups, containers, lanes and page-scale transforms. | Nested/rotated/scaled fixture endpoints resolve to the same world location after reopen. |
| MV-CON-08 | B / G2 | Offer hierarchical, flowchart, tree and reference-confirmed general layout commands. | Preview identifies changed objects; pinned positions and explicit route constraints are honored. |
| MV-CON-09 | N / G2 | Make layout deterministic for a fixed graph, configuration and engine version. | Repeated layout of identical input produces identical positions and routes. |
| MV-CON-10 | N / G2 | Preserve unedited imported routes until a relevant edit requires recalculation. | A text-only edit does not reroute an unrelated page or connector. |

### 5.5 Stencils, masters, templates and themes

Visio stencils contain reusable masters and can be saved and shared. Intelligent behavior requires master identity and instance inheritance, beyond retaining a thumbnail. [Custom stencils][S07]

| ID | Scope / gate | Requirement | Acceptance evidence |
| --- | --- | --- | --- |
| MV-LIB-01 | B / G2 | Open, search, browse, pin and reuse stencils with master previews and metadata. | A user can find/drop a custom master offline without copying a whole drawing. |
| MV-LIB-02 | B / G2 | Retain master IDs, universal/local names, group trees, geometry and behavior. | Distinct masters with similar names do not merge; instance references remain valid. |
| MV-LIB-03 | B / G2 | Apply inherited cells/sections and local overrides with correct precedence. | A master edit updates inherited values while protected local overrides remain unchanged. |
| MV-LIB-04 | B / G2 | Create, rename, edit, reorder and delete custom masters/stencils. | Modified custom stencils reopen in both applications with usable editable masters. |
| MV-LIB-05 | B / G2 | Export a selection as a reusable master including dependencies. | The exported master works in a new empty document with images, data, controls and glue intact. |
| MV-LIB-06 | B / G2 | Create/save templates with page settings, defaults, libraries and solution metadata. | New drawings from the template reproduce intended settings without sharing writable state. |
| MV-LIB-07 | B / G2 | Support document masters, replacement and update behaviors confirmed in the baseline. | Replacement maps connections/data intentionally and reports unmapped features before commit. |
| MV-LIB-08 | B / G2 | Apply themes, variants and quick styles while retaining explicit overrides. | Changing theme updates inherited appearance and preserves fixed brand colors. |
| MV-LIB-09 | N / G1 | Maintain content provenance and redistribution permissions for bundled libraries. | Every shipped library has origin, version and documented distribution permission. |

Microsoft describes themes as coordinated colors and effects; MacVisio must preserve theme relationships as well as rendered colors. [Theme behavior][S08]

### 5.6 ShapeSheet and intelligent behavior

Microsoft describes ShapeSheet as the formula-based representation of object appearance and behavior, with sections, rows, cells and values. Cell references can span shapes, groups, pages, masters, styles and the document. [ShapeSheet concepts][S09], [cell references][S10]

| ID | Scope / gate | Requirement | Acceptance evidence |
| --- | --- | --- | --- |
| MV-SHS-01 | B / G2 | Model document, page, style, master and shape sheets with stable section/row/cell identity. | Source formulas, cached values, units and inherited/local state remain individually inspectable. |
| MV-SHS-02 | B / G2 | Parse reference-confirmed expressions, operators, literal types and units. | A versioned expression corpus covers precedence, coercion, errors and localized/universal forms. |
| MV-SHS-03 | B / G2 | Resolve names, sheet IDs, escaped row names and cross-object references. | Rename, duplicate, delete and cross-document paste update references without collisions. |
| MV-SHS-04 | B / G2 | Recalculate through an incremental dependency graph with cycle/error diagnostics. | A changed property updates all dependents; unrelated pages are not recalculated. |
| MV-SHS-05 | B / G2 | Implement guarded values, inheritance and reference-redirection behavior. | GUARD/SETATREF and master overrides match reference fixtures during drag and cell editing. |
| MV-SHS-06 | B / G2 | Implement baseline geometry, text, color/theme, string, numeric, date/time and lookup functions. | Every inventory function has version-specific semantic tests, including invalid inputs and contextual evaluation. |
| MV-SHS-07 | B / G2 | Provide control handles, constraints, live tooltips and formula-driven shape behavior. | Dragging a control updates its intended cells; cancel restores the exact pre-gesture state. |
| MV-SHS-08 | B / G4 | Support confirmed actions/events and formula-triggered commands through an explicit execution policy. | User gestures produce documented action order; opening untrusted documents cannot silently execute external commands. |
| MV-SHS-09 | B / G2 | Provide a ShapeSheet editor with formula/value views, typed editing and diagnostics. | Users can add/remove permitted rows/sections and navigate from an error to its source cell. |
| MV-SHS-10 | N / G2 | Preserve unsupported formulas and expose stale cached results. | Unsupported expressions remain unchanged; the UI distinguishes cached display from verified calculation. |
| MV-SHS-11 | N / G0 | Maintain a function/cell coverage registry independent of raw occurrence counts. | Each entry records syntax, types, context, version, tests and known differences; parser success is a separate metric. |

The authoritative reference catalogs are Microsoft's [cells][S11] and [functions][S12]. Their existence does not prove every documented item belongs to the 2019 target; the exact-build inventory determines applicability. Formula execution that can open files, invoke commands or automate other applications belongs to the execution policy, not the unrestricted scalar evaluator.

### 5.7 Pages, layers, containers and physical drawing

Layers control aspects of drawing organization. Containers have membership behavior; lists arrange members in a sequence and are used by specialized shapes. These are separate concepts from groups and z-order. [Layers][S13], [containers and lists][S14]

| ID | Scope / gate | Requirement | Acceptance evidence |
| --- | --- | --- | --- |
| MV-PAG-01 | B / G1 | Add, duplicate, rename, reorder, navigate and delete foreground/background pages. | Page links and background associations remain valid; deletion identifies dependents. |
| MV-PAG-02 | B / G2 | Compose backgrounds, borders/title blocks and foreground-context fields. | One shared background displays correct page-specific fields on different foreground pages. |
| MV-PAG-03 | B / G2 | Manage layer membership, visibility, lock, print, color, snap, glue and active defaults. | Multiple membership and connector cases match registered reference rules. |
| MV-PAG-04 | B / G3 | Provide containers with membership, headings, padding, fit-to-content and lock behavior. | Moving a container moves intended members while preserving graph connections. |
| MV-PAG-05 | B / G3 | Provide ordered lists and swimlane/phase structures with insertion and reordering. | Reordering lanes updates contained items and headings as one reversible transaction. |
| MV-PAG-06 | B / G2 | Separate paper dimensions, drawing units, drawing scale and printer scaling. | A one-metre object at 1:50 prints at 20 mm when output is explicitly 100%. |
| MV-PAG-07 | B / G3 | Provide dimension lines, measured shapes and reference-confirmed area/length tools. | Dimensions recalculate after geometry edits and remain correct across unit changes. |
| MV-PAG-08 | B / G2 | Support page auto-size, fixed pages, orientation, margins and tiled output. | Preview and printed/exported page bounds agree, including backgrounds and page breaks. |

### 5.8 Shape data, external data and reporting

Microsoft documents importing data from spreadsheets, databases and other sources, linking rows to shapes and refreshing data. Data graphics include text, bars, icon sets and color by value. [Data import][S15], [data graphics][S16]

| ID | Scope / gate | Requirement | Acceptance evidence |
| --- | --- | --- | --- |
| MV-DAT-01 | B / G2 | Create/edit typed Shape Data fields, labels, prompts, lists, ordering and display formats. | Text, list, number, Boolean, date, duration and currency values round-trip with locale-safe storage. |
| MV-DAT-02 | B / G3 | Import tabular data with header/type preview, validation and reusable column mapping. | Empty values, duplicate headers, malformed dates and large tables produce row-level diagnostics. |
| MV-DAT-03 | B / G3 | Link rows to shapes by explicit stable keys, including one-to-many links where reference-confirmed. | Reordered source rows preserve identity; ambiguous keys require user resolution. |
| MV-DAT-04 | B / G3 | Refresh manually/on a configured schedule with a change preview and conflict policy. | Additions, deletions, changed types and local overrides are resolved before commit. |
| MV-DAT-05 | B / G3 | Define reusable data graphics with thresholds, legends, missing-value behavior and placement. | Refresh updates presentation without replacing shape geometry or original data. |
| MV-DAT-06 | B / G3 | Generate filtered/grouped/summarized reports from shape data. | Report totals reconcile to the selected pages/shapes and export to CSV and a printable view. |
| MV-DAT-07 | N / G3 | Retain a local last-known data snapshot and expose source freshness. | Offline open remains useful; the UI shows last successful refresh and failed connection state. |
| MV-DAT-08 | B / G4 | Supply baseline-confirmed source connectors through native adapters or a documented bridge. | Each Excel/Access/SQL/SharePoint/ODBC/OLEDB source type has an explicit version/authentication/support matrix. |
| MV-DAT-09 | X / GX | Generate process diagrams from tabular data with explicit mapping and reconciliation. | A changed source updates graph structure while retaining matched shapes' manual annotations. |
| MV-DAT-10 | X / GX | Offer controlled two-way synchronization for selected table workflows. | Conflicting edits require a preview; the user can export a change set without modifying the source. |

Desktop Data Visualizer documentation describes Excel-driven creation and two-way synchronization and identifies a Plan 2 requirement. Separately, Microsoft lists the Excel Data Visualizer add-in for retirement in March 2026. MacVisio should implement its own table-to-diagram workflow rather than depend on that add-in. [Desktop generation][S17], [add-in retirement notice][S18]

### 5.9 Specialist diagram solutions

A solution is more than a shape pack: it may include metadata, constraints, layout, dialogs, validation, import/export and reporting. The baseline template/solution inventory must expand these families into named, testable workflows. Microsoft's process-diagram catalog is a starting point rather than an exhaustive inventory. [Process diagrams][S19]

| ID | Scope / gate | Requirement | Acceptance evidence |
| --- | --- | --- | --- |
| MV-SOL-01 | B / G1 | Provide basic flowchart shapes, decisions, branches, subprocess and off-page references. | A multipage branching process remains navigable and editable after exchange. |
| MV-SOL-02 | B / G3 | Provide cross-functional flowcharts with lanes, phases, orientation and automatic membership. | Inserting/reordering lanes preserves process relationships and associated labels. |
| MV-SOL-03 | B / G3 | Provide BPMN 2.0 notation and the reference-confirmed Analytic graphical validation behavior. | Events, activities, gateways, pools/lanes and flow types retain attributes; known invalid cases produce issues. |
| MV-SOL-04 | B / G3 | Provide UML families confirmed for the 2019 baseline, with notation-specific editing. | Class, sequence, activity, state, use-case, component, deployment and communication fixtures have independent acceptance cases. |
| MV-SOL-05 | B / G3 | Provide entity-relationship/database notation, keys, attributes and relationship endpoints. | Crow's-foot/other registered notations retain cardinality, optionality and editable labels. |
| MV-SOL-06 | B / G3 | Provide basic/detailed network and rack workflows with equipment data and connections. | Ports, rack placement and equipment reports remain meaningful after layout and export. |
| MV-SOL-07 | B / G3 | Provide baseline cloud/infrastructure libraries with versioned content. | Each library entry has a provenance/version record and works with scale, connectors and themes. |
| MV-SOL-08 | B / G3 | Provide org-chart authoring, data import, hierarchy layout, photos and secondary reporting. | A source hierarchy with duplicate display names uses stable identity and detects cycles/missing managers. |
| MV-SOL-09 | B / G3 | Provide floor-plan/office workflows with walls, doors, windows, measured equipment and dimensions. | A scale-changing plan retains real measurements and properly attached architectural elements. |
| MV-SOL-10 | B / G3 | Provide engineering families, including electrical, circuits/logic and piping/instrumentation where inventoried. | Each family's symbols, connection rules, data and solution commands pass family-specific workflows. |
| MV-SOL-11 | B / G3 | Provide timeline, calendar, Gantt and PERT workflows confirmed in the baseline. | Date/task edits update intended geometry and labels; scheduling behavior is documented per solution. |
| MV-SOL-12 | B / G3 | Provide brainstorming, business, quality, audit, fault-tree, EPC/ITIL, Six Sigma and value-stream families where inventoried. | Every registered family has a create/edit/save/reopen/print case rather than only a parser test. |
| MV-SOL-13 | B / G3 | Provide baseline wireframe and other specialist template behaviors. | Controls, lists and annotation relationships remain editable; a mockup is not advertised as an executable prototype. |
| MV-SOL-14 | B / G3 | Provide diagram validation with rule sets, issue navigation, ignore state and extension points. | Invalid fixtures produce expected rule IDs and object links; corrections clear issues deterministically. |
| MV-SOL-15 | B / G4 | Implement database-schema import/reverse engineering wherever confirmed in the reference build. | A declared database/driver matrix produces inspectable schema and diagnostics without writing to the source database. |
| MV-SOL-16 | X / GX | Add newer Azure, AWS, Kubernetes and other contemporary libraries independently of the frozen baseline. | Updates do not alter old diagrams' stored master definitions or imply broader baseline compatibility. |

Microsoft's BPMN validation checks graphical elements and does not certify attribute-value correctness or executable process semantics. MacVisio should make the same distinction. [BPMN behavior][S20], [structured validation][S21]

The UML catalog includes 2019-specific guidance; older UML Model Diagram features must not be assumed to exist in later products. [UML catalog][S22] Org-chart generation, scaled floor plans and date-driven timeline/Gantt features provide separate workflow benchmarks. [Org charts][S23], [floor plans][S24], [timelines][S25], [Gantt charts][S26]

Microsoft's database-model documentation mixes edition-era guidance and lists limits on SQL Server reverse engineering. The exact 2019 build, installation and driver set must determine MV-SOL-15 applicability; a general ERD template does not establish reverse-engineering support. [Database modeling][S27]

### 5.10 Import, export and print

Microsoft describes VSDX as an OPC/XML package, with relationships among parts, and distinguishes drawing, stencil, template and macro-enabled extensions. The VSDX specification must not be treated as a binary VSD specification. [File-format introduction][S28], [MS-VSDX][S29]

| ID | Scope / gate | Requirement | Acceptance evidence |
| --- | --- | --- | --- |
| MV-IO-01 | B / G2 | Read/write genuine public VSDX drawing content, including relationships and dependencies. | Microsoft Visio opens without repair, edits and saves the output; private MacVisio metadata is removed for validation. |
| MV-IO-02 | B / G4 | Read/write binary VSD with the geometry and semantics needed by the declared baseline matrix. | Independent Visio create/open/edit/save/reopen tests verify formulas, masters, data, glue and text beyond graphics. |
| MV-IO-03 | N / G2 | Preserve unknown/unmodified source parts and avoid broad unrelated rewrites. | No-edit saves retain part payloads; supported local edits change only expected semantic dependencies. |
| MV-IO-04 | B / G2 | Read/write baseline drawing, stencil and template families with correct public content types. | VSDX/VSSX/VSTX and baseline-confirmed legacy counterparts pass distinct interoperability suites. |
| MV-IO-05 | B / G4 | Handle macro-enabled files with preservation, execution policy and signature awareness. | Macros are never stored in a macro-free extension; modifications disclose invalidated signatures. |
| MV-IO-06 | B / G2 | Export SVG, raster images and vector PDF with explicit page, bounds, resolution and background settings. | Output size and clipping match preview; all-page PDF uses each foreground page's physical size. |
| MV-IO-07 | B / G2 | Print page ranges/all pages with scale, tiling, margins and backgrounds. | Print preview and physical dimensions reconcile on a measured reference output. |
| MV-IO-08 | B / G3 | Import/insert declared CAD and graphics formats with clear conversion semantics. | Unsupported entities are reported; an inserted reference and converted editable shapes are visibly distinguished. |
| MV-IO-09 | B / G4 | Preserve/render reference-confirmed WMF/EMF and linked/embedded object content. | Known fixtures retain previews, metadata and placement; unsupported activation is explicitly identified. |
| MV-IO-10 | N / G1 | Produce a compatibility report before saving an edit that would degrade unsupported content. | The report identifies affected objects and offers cancel, alternate format or safe copy. |
| MV-IO-11 | N / G2 | Never use private metadata as the sole carrier of a claimed interoperable feature. | Stripping native metadata leaves claimed pages, shapes, data and behavior independently testable. |
| MV-IO-12 | B / G4 | Inventory and support reference-confirmed legacy XML, graphics and export filters individually. | VDX/VSX/VTX and other target filters have explicit read/write/version status rather than an umbrella claim. |

Microsoft's graphics import list includes raster/vector formats and CAD. Its AutoCAD guidance distinguishes subscription/version limits, so MacVisio must publish exact supported DWG/DXF versions instead of claiming unrestricted CAD compatibility. [Graphics formats][S30], [AutoCAD import][S31]

### 5.11 Automation, integrations and Windows-dependent behavior

Visio's documented automation object model exposes application, document and page objects and drawing operations. Compatibility with file structure is separate from compatibility with that API and its Windows hosting mechanisms. [Object model overview][S32]

| ID | Scope / gate | Requirement | Acceptance evidence |
| --- | --- | --- | --- |
| MV-AUT-01 | N / G2 | Provide a stable local automation API for documents, pages, shapes, cells and export. | A versioned script creates a connected multipage drawing and exports it with structured errors. |
| MV-AUT-02 | N / G2 | Provide noninteractive convert, render, export and inspect commands. | Commands have documented exit codes, no interactive prompts and prevent output from replacing input accidentally. |
| MV-AUT-03 | B / G4 | Inventory the baseline automation members, event order and transaction behavior. | Every confirmed member maps to native support, bridge support or an explicit unresolved compatibility entry. |
| MV-AUT-04 | B / G4 | Provide an execution strategy for confirmed VBA/COM workflows. | Representative unmodified compatibility scripts pass via the declared bridge/runtime; translated native scripts are labeled separately. |
| MV-AUT-05 | B / G4 | Address confirmed COM/VSTO/VSL/ActiveX and third-party add-in workflows. | A published compatibility matrix names tested add-ins/versions; no claim follows solely from preserving their files. |
| MV-AUT-06 | B / G4 | Address linked/embedded OLE workflows and external-document editing. | Reference cases retain object identity and changes, with a bridge or clear unsupported activation state. |
| MV-AUT-07 | B / G4 | Reproduce baseline-confirmed Office, reporting and process-integration user outcomes. | Each integration has an exact host version, authentication/setup path and end-to-end test. |
| MV-AUT-08 | X / GX | Add contemporary Microsoft 365, Power BI, Teams and workflow integrations selectively. | Availability depends on verified APIs and tenant policy; no undocumented coauthoring protocol is assumed. |

### 5.12 Comments, sharing and coauthoring

Microsoft documents comments and coauthoring with application/storage constraints, including a restriction against simultaneous desktop/web editing. Its general service table is inconsistent with parts of the detailed coauthoring guide; version-specific testing is required. [Collaboration guide][S33], [service description][S34]

| ID | Scope / gate | Requirement | Acceptance evidence |
| --- | --- | --- | --- |
| MV-COL-01 | B / G3 | Read/write baseline comments and review annotations with author/time/object anchors. | Moving a shape retains its comments; imported threads do not acquire fabricated authorship. |
| MV-COL-02 | N / G1 | Work with local/cloud-synced folders using conflict-safe file access. | Concurrent external changes trigger conflict handling; sync storage is not presented as coauthoring. |
| MV-COL-03 | B / G4 | Inventory and address baseline review/sharing/coauthoring workflows where confirmed. | Required storage/service prerequisites and tested combinations are documented. |
| MV-COL-04 | X / GX | Provide optional native collaborative sessions with permissions, presence and anchored threads. | Two authorized users converge after simultaneous edits; revocation stops future access. |
| MV-COL-05 | X / GX | Support reconnect/offline reconciliation and selective collaborative undo. | A concurrent text edit and deletion resolve deterministically without resurrecting deleted data unexpectedly. |

### 5.13 Accessibility, security and operation

Microsoft provides accessibility and screen-reader guidance. MacVisio must implement accessible interaction using macOS APIs and expose meaningful diagram structure, rather than relying only on visual parity. [Accessible diagrams][S35], [screen-reader support][S36]

| ID | Scope / gate | Requirement | Acceptance evidence |
| --- | --- | --- | --- |
| MV-ACC-01 | N / G1 | Expose controls, canvas objects, text, relations and data through a meaningful accessibility tree. | VoiceOver can identify, select, inspect, move and connect shapes in a test process. |
| MV-ACC-02 | N / G1 | Provide visible keyboard focus and keyboard alternatives for required workflows. | A keyboard-only journey creates, labels, connects, saves and exports a drawing. |
| MV-ACC-03 | N / G2 | Support alternative text, meaningful reading order, accessible link text and non-color-only status. | Accessibility inspection identifies missing descriptions and ambiguous status indicators. |
| MV-SEC-01 | N / G1 | Bound archive expansion, parser depth, resource sizes, formulas and imported object complexity. | Crafted ZIP/XML/compound-file inputs fail safely without arbitrary file writes or unbounded main-thread work. |
| MV-SEC-02 | N / G1 | Disable document-driven external execution/network fetching by default. | Opening a drawing never launches macros, remote images, commands or data refresh without the applicable trust action. |
| MV-SEC-03 | N / G3 | Store credentials in Keychain and separate them from drawings, logs and exported diagnostics. | Inspecting a saved drawing or diagnostic bundle reveals no token/password. |
| MV-SEC-04 | B / G4 | Address baseline rights-managed/protected documents without bypassing their restrictions. | Authorized cases use a supported mechanism; unsupported protected files fail with a useful explanation. |
| MV-SEC-05 | N / G1 | Keep diagnostics local by default and make any telemetry opt-in and content-minimal. | Counts/timing can be collected without drawing text, data values or file contents. |
| MV-OPS-01 | N / G1 | Ship signed/notarized reproducible application artifacts with dependency/license records. | Release checks verify signature, dependency loading, provenance and installation on supported systems. |
| MV-OPS-02 | N / G1 | Provide authenticated updates, release notes, opt-out and user-controlled installation. | An invalid update signature is rejected; interrupted update retains a runnable application. |
| MV-OPS-03 | N / G1 | Publish exact macOS/architecture and feature-support matrices. | Installer and startup reject unsupported systems clearly; each advertised combination has release evidence. |
| MV-OPS-04 | N / G2 | Provide safe document diagnostics and a user-selected exportable support report. | The report includes app/format versions, counts, warnings and timings; sensitive content is excluded by default. |

## 6. File compatibility contract

### 6.1 Intended support matrix

This is a target matrix, not the current implementation matrix. VSD generations and filters must be enumerated from the target runtime before qualification.

| Family | Intended open/edit | Intended write | Qualification |
| --- | --- | --- | --- |
| VSDX | Native structured editing | Public VSDX | G2 foundational support; G4 full baseline semantics |
| VSD | Native structured editing | Genuine binary VSD | G4; current experimental writer is not acceptance |
| VSSX / VSTX | Master editing / instantiate new drawings | Correct stencil/template packages | G2 foundation; G4 complete baseline behavior |
| VSS / VST | Legacy master/template workflows | Reference-confirmed legacy output | G4; graphics-only conversion does not qualify |
| VSDM / VSSM / VSTM | Structure and macro preservation; controlled execution | Macro-enabled packages | G4 with execution/signature policy |
| VDX / VSX / VTX | Per-filter baseline support | Per-filter baseline support | G4 after runtime filter inventory |
| Native MacVisio | Full native document and recovery | Versioned native storage | G1; public interchange remains independent |
| SVG / PNG / JPEG / PDF | Declared insertion/import behavior | Publication output | G2; SVG/vector semantics documented separately |
| DWG / DXF | Insert/reference/convert as declared | Reference-confirmed export only | G3/G4 with exact version/entity matrix |
| WMF / EMF / other graphics | Reference-confirmed rendering/conversion | Reference-confirmed export filters | G4; no silent flattening claim |

### 6.2 Five independent compatibility dimensions

1. **Preservation:** source parts and unsupported records survive unchanged operations.
2. **Rendering:** the visible drawing matches within approved tolerances.
3. **Editing:** users can manipulate meaningful objects rather than flattened images.
4. **Behavior:** formulas, master updates, routing, validation and solution commands work.
5. **Interchange:** Microsoft Visio opens, edits, saves and reopens the result without loss or repair.

Publish these dimensions separately by feature and format. A checksum-preserved source part satisfies only preservation. A libvisio rendering satisfies neither Microsoft acceptance nor all semantics. A successful MacVisio private-metadata reopen does not establish public interchange.

### 6.3 Unsupported content policy

On open, identify each unsupported capability and whether it is preserved, cached for display, editable with restrictions or unavailable. Avoid noisy alerts for harmless opaque metadata. Show a persistent compatibility indicator only when it helps the user assess a material action.

On edit/save, evaluate dependencies. An edit that invalidates cached geometry or unknown solution state must identify the risk before replacing the source. Offer a copy, alternate format or cancellation. Preserve the original when safe updating is impossible. Protected/encrypted/signed content requires its own policy; retaining ciphertext or a stale signature is not successful editing.

## 7. Proposed domain model and architecture

This is an engineering direction for MacVisio, not a reconstruction of Microsoft's internal implementation. Evolve existing Swift/AppKit modules incrementally; a rewrite is not required by this specification.

### 7.1 Domain entities

| Entity | Required information and relationships |
| --- | --- |
| Document | Stable identity, schema version, metadata, pages, masters, styles, themes, data sources, validation rules, source package, compatibility state |
| Page | Identity/order, foreground/background relationship, physical size, drawing units/scale, page sheet, layers, objects, layout configuration |
| Shape | Identity, local/universal names, master reference, local transform, parent/group, geometry, text, formatting, sheet, data, hyperlinks, protections |
| Connector | Shape identity plus begin/end attachment, port/dynamic-glue semantics, route constraints, cached path, labels and connector sheet |
| Geometry | Ordered sections/rows, source formulas, evaluated values, units, fill rules and renderable path cache |
| Master | Stable public identity, master tree/sheet, defaults, instance inheritance and update policy |
| Sheet/cell | Owner, section/row/cell key, formula source, typed cached/evaluated result, units, inheritance, error/staleness state |
| Text | Logical Unicode text, character/paragraph runs, field tokens, text transform, language and accessibility description |
| Structured relationship | Group parent, container member, ordered-list member, lane/phase membership and graph edge as distinct relationships |
| Data source/link | Connector kind, external resource identity, credential reference, key/field mapping, snapshot, freshness and conflict state |
| Validation issue | Rule/version, affected IDs, severity, message, evidence, ignore state and suggested action |
| Source binding | Public part/record IDs, relationships, opaque payloads, original value, supported patch strategy and integrity hashes |
| Edit transaction | Model changes, identity mapping, dependency invalidations, undo information, save revision and origin |

Public IDs and internal UUIDs need explicit mappings scoped by document/page/master. A foreign connector must not lose its shape identity merely because the native graph engine stores edges separately. Preserve source formula text separately from compiled expressions and evaluated caches. Native recovery metadata must be redundant for every claimed public feature.

### 7.2 Component boundaries

| Component | Responsibility | Existing starting points |
| --- | --- | --- |
| Document shell | NSDocument lifecycle, file coordination, save snapshots, recovery and windows | `Document.swift`, `DocumentWorkflow.swift`, `WelcomeWindow.swift` |
| Model/transactions | Identity, hierarchy, operations, undo, revisioning and migrations | `Model.swift`, `DiagramOperations.swift`, `PageOperations.swift` |
| Interchange | Package/binary parsing, public serialization, source preservation and diagnostics | `VisioPackage.swift`, `VisioXML.swift`, `VisioPreservation.swift`, `VSDBinaryFormat.swift` |
| Calculation | Typed formulas, dependency tracking, context and execution policy | `ShapeSheetEngine.swift`, `TypedShapeSheet.swift`, `DiagramCalculation.swift` |
| Rendering/text | Canonical drawing, hit testing, text metrics, screen/PDF/SVG/raster consistency | `Drawing.swift`, `RichText.swift`, geometry modules |
| Connections/layout | Ports, glue, route editing, obstacle indexes and layout | `ConnectionGeometry.swift`, `OrthogonalRouter.swift` |
| Content/solutions | Masters, stencils, templates, containers and specialist behavior | `VisioStencil.swift`, `VisioLibrary.swift`, `Templates.swift`; solution modules to be added |
| Data/integrations | Adapters, key mapping, snapshots, reports and service authentication | Existing Shape Data editing; external-data modules to be added |
| Qualification | Fixture manifests, public-content checks and Windows differential execution | Existing interchange corpus and Windows harness |

Verify actual declarations before changing module boundaries; these are navigation hints, not a prescribed final source layout.

### 7.3 Calculation and rendering pipeline

Apply a user operation as a transaction → update public/native identities → invalidate affected dependencies → evaluate pure cells → schedule controlled actions if permitted → update geometry/text/routing caches → redraw affected regions → record undo and save revision.

Use one canonical coordinate/units model. Keep shape-local, parent, page-drawing, physical-paper and screen transformations explicit. Export and screen rendering should share evaluated geometry/text, with output-specific adapters. Do not convert the document model into screen points or change it when the user changes zoom.

Cache compiled formulas, XML lookups, inherited master/style resolution, text measurement, path tessellation and spatial indexes. Invalidate by revision/dependency rather than globally. Deterministic caches must never become the only semantic record.

### 7.4 Concurrency and large documents

AppKit UI mutations stay on the main thread. Parse, calculate expensive independent work, serialize and compress on bounded workers against immutable snapshots. Long operations report progress and cancellation. Results carry a document revision so stale work cannot replace newer edits. Save completion marks only its captured revision clean. Resource ownership and memory limits apply to archives, bitmap decoding, inherited master expansion and native metadata.

### 7.5 Extension interfaces

Provide versioned interfaces for format adapters, diagram solutions, validation rules, content libraries, data connectors and local automation. Capabilities declare permissions and document-version requirements. Extensions cannot silently mutate unrelated documents or perform external execution from an imported formula. Keep a possible Windows bridge behind a separate, explicit service boundary with documented setup and availability.

## 8. Quality and performance requirements

The following are proposed release targets, not measured current performance or Microsoft guarantees. Qualify on a named Apple Silicon Mac with 16 GB memory and local SSD, recording exact hardware, OS, app build and cache state. Cold and warm runs are reported separately. Network fetch time is separated from local processing.

| ID | Scope / gate | Requirement | Acceptance evidence |
| --- | --- | --- | --- |
| MV-NFR-01 | N / G1 | Prevent lost committed edits across normal save, save failure, external conflict and recovery. | Fault-injection cases preserve the last valid file and recoverable checkpoint; no known silent-loss defect ships. |
| MV-NFR-02 | N / G1 | Keep common direct manipulation responsive. | On a 1,000-shape active page, p95 input-to-feedback ≤50 ms and p95 frame time ≤33 ms during a defined drag/pan trace. |
| MV-NFR-03 | N / G2 | Open a standard document promptly. | A 10-page/2,000-shape/1,000-connector fixture opens to a usable first viewport in ≤3 s warm and ≤5 s cold at p95. |
| MV-NFR-04 | N / G2 | Bound large-document loading and support cancellation. | A 50-page/20,000-shape/10,000-connector fixture opens in ≤15 s warm at p95 with progress and no post-open UI stall >250 ms. |
| MV-NFR-05 | N / G2 | Save without freezing interaction. | Standard fixture saves in ≤3 s and large fixture in ≤10 s at p95; main-thread save work has no single >100 ms stall. |
| MV-NFR-06 | N / G2 | Bound memory and avoid unbounded growth over repeated document cycles. | Peak RSS ≤1 GB standard and ≤3 GB large; 20 open/edit/close cycles show no sustained leak after caches settle. |
| MV-NFR-07 | N / G2 | Preserve geometry and print dimensions within approved tolerances. | Numeric geometry ≤max(1e-6 inch, 1e-6 relative); printed dimension error ≤0.2 mm on a calibrated test pipeline. |
| MV-NFR-08 | N / G2 | Evaluate appearance with both numeric and visual checks. | All benchmark pages receive same-font reference renders; raster diffs are triaged by region and all material differences have dispositions. |
| MV-NFR-09 | N / G1 | Support localization-safe storage and UI. | English/Australian and decimal-comma locale tests preserve numeric/date meaning; UI accommodates longer labels. |
| MV-NFR-10 | N / G1 | Establish a tested OS/architecture support policy. | Every advertised minimum/current OS and architecture passes installation, document, font, print and update smoke checks. |

Use at least 30 measured samples per performance fixture/cache condition to calculate p95. Also report median, maximum, shape/formula/image counts and file size. A large imported raster is not equivalent to 20,000 intelligent shapes. Include formula-heavy, image-heavy and deeply grouped variants. Tolerance exceptions need a named fixture and rationale; a generic pixel-similarity score cannot excuse lost objects or changed text.

The README currently describes an Apple Silicon/macOS 27 distribution while `Package.swift` targets macOS 13. The specification does not claim older-system compatibility. G1 requires a published, internally consistent support matrix after rebuilding/testing all bundled dependencies. Broadening support is an explicit product decision.

## 9. Existing MacVisio position and gap assessment

The repository documents a functioning native editor with multipage documents, VSDX source preservation, experimental VSD output, bounded ShapeSheet support, libraries, geometry, data and local exports. It also explicitly states that full parity and Windows acceptance are incomplete. [Local README](../README.md), [compatibility matrix](COMPATIBILITY.md), [implementation plan](PLAN.md)

| Area | Repository-reported foundation | Main qualification/implementation gap | Relevant requirements |
| --- | --- | --- | --- |
| Document shell | Native windows, Home/recent files, background open/save and snapshots | Recovery/conflicts/accessibility/performance across declared platforms | DOC, UX, ACC, NFR |
| VSDX | Public parts, patching and unknown-part retention | Complete semantics, signatures and actual Visio differential acceptance | IO-01/03/05/11 |
| Binary VSD | Graphics import and experimental genuine binary output | Rich semantic read/write and verified Windows editing | IO-02/04 |
| ShapeSheet | Typed bounded evaluator, context and selected theme/text functions | Complete catalog semantics, events/actions and reference comparison | SHS-01–11 |
| Masters/libraries | Installer-library parsing, master loading and some export | Full inheritance/update identity and solution behavior | LIB-01–08 |
| Geometry/text/themes | Many primitives, controls, curves, fields and mixed text | Complete transforms, text layout, theme/effect rendering and font parity | EDT, TXT, SHS |
| Connectors/layers/pages | Ports/glue, partial orthogonal routing, layers/backgrounds/scale | Full routing/line jumps, dynamic contexts, containers/lists | CON, PAG |
| Professional solutions | General editing primitives | Typed solutions, validation, org import, CAD and engineering tools | SOL |
| Data | Shape Data editing | External sources, refresh, data graphics and reports | DAT |
| Automation/cloud | Local conversion/render diagnostics and retained source parts | API compatibility, Windows mechanisms and collaborative workflows | AUT, COL |
| Distribution | Build/release/update workflow | Consistent platform promises and release-wide evidence | OPS, NFR-10 |

Short family references in this table refer to IDs with the `MV-` prefix. This is a qualitative gap assessment based on documentation and selected source inspection. It is not a percentage-complete estimate. Existing test totals are intentionally not used as a proxy for feature coverage.

The current Windows validation note reports that the available guest lacks a working registered Visio installation. That is an evidence dependency, not proof that file output is incompatible and not permission to claim compatibility. [Windows validation](WINDOWS-VALIDATION.md)

## 10. Acceptance and qualification system

### 10.1 Reference inventory

G0 produces a machine-readable catalog of the exact 2019 build's commands, templates, masters, ShapeSheet cells/functions, automation members/events, data sources, import/export filters and solution-specific workflows. Each entry records version/edition, prerequisites, source, requirement mapping, fixture, expected behavior and current evidence status.

Separate five states: documented; observed in reference; implemented; independently tested; accepted. A feature may be implemented but remain unaccepted. A feature with unavailable reference prerequisites stays unresolved. It must not disappear from the denominator.

### 10.2 Fixture strategy

Use small synthetic fixtures with independently authored expectations, reference-authored fixtures created in licensed Visio and permissioned representative customer drawings. Keep confidential documents out of public repositories. Expand the current synthetic-only Windows harness through a separate approved fixture path before using non-synthetic content; its present manifest restrictions remain authoritative.

Every family needs positive, negative, edge and mixed-feature cases. Include deep groups, master overrides, locale changes, font absence, large diagrams, broken relationships, unusual units, cyclic formulas, malformed files, protected content, sparse tables and connector constraints. Ensure a small fixture cannot accidentally pass because a flattened cached graphic looks correct.

### 10.3 Differential round-trip protocol

1. Record reference application/build, edition, OS, locale, fonts, prerequisites and fixture hashes.
2. Create/open the fixture in Visio; record expected structure, selected cells, rendered pages and a specified edit.
3. Open it in MacVisio and compare appearance, structure and diagnostics.
4. Perform the same meaningful edit, save and strip only MacVisio private metadata from a validation copy.
5. Open that public result in Visio, check for repair/warnings, inspect structure/formulas/data/glue and edit it again.
6. Save, close and reopen in Visio, export reference PDF/SVG/raster and reimport into MacVisio.
7. Compare semantic invariants, numeric values and appearance; retain reports and all phase failures.
8. Run the reverse direction with independently Visio-authored inputs and execute the actual native UI workflow.

An independent parser is useful for structural checks but cannot replace steps performed by Microsoft Visio. Page count, labels and image comparison are necessary but insufficient on their own.

### 10.4 Release gates

| Gate | Deliverables | Exit criteria |
| --- | --- | --- |
| G0 — Reference and traceability | Working licensed reference, frozen build, complete inventory, fixtures and gap ledger | Every baseline inventory item maps to a requirement/workflow; no unsupported scope assumption remains hidden |
| G1 — Dependable general editor | Documents, basic flowcharts, common editing, accessibility, recovery, package safety and distribution | Every G1 row passes its acceptance case; no known silent-loss/security-blocking defect; support matrix published |
| G2 — Intelligent shapes and interchange | Masters, formulas, text/geometry, routing, public formats, print/export and large documents | Every G2 row passes; no private-metadata dependency for claimed public support; reference workflow results attached |
| G3 — Professional solutions and data | Typed diagram families, containers, validation, external data, reports and CAD scope | Each registered family/source has end-to-end evidence; family-specific limitations remain visible |
| G4 — Full baseline qualification | Remaining legacy formats, automation/Windows dependencies, protected content and all baseline workflows | All baseline inventory entries pass in the exact reference environment; zero unresolved material exceptions; full regression and native UI acceptance complete |
| GX — Contemporary extensions | Selected modern libraries, integrations, collaboration and generation | Each extension has independent product/security/compatibility evidence and does not regress baseline behavior |

Partial releases can ship before G4 with accurately scoped claims. The term “full Visio Professional 2019 compatibility” is reserved for G4. Gate ordering allows foundational automation or a data connector to begin earlier; it is not an instruction to defer discovering architectural blockers.

### 10.5 Coverage and release metrics

- Requirements accepted / applicable requirements, separated by gate and scope.
- Reference inventory items accepted / all applicable items, including unresolved prerequisites.
- Semantic round-trip cases passed / executed, by format and Visio build.
- Material rendering differences by family and severity.
- Formula functions/contexts accepted, plus a separate real-document occurrence-weighted measure.
- Recovery/conflict/fault-injection results and compatibility-warning accuracy.
- p50/p95 timings, memory and UI stalls on the fixed performance corpus.
- Accessibility journey completion and real-user task success/time.

Never substitute number of tests, parsed templates or evaluated formula occurrences for full compatibility coverage.

## 11. Delivery strategy and immediate backlog

Work in vertical slices that finish a real document workflow across UI, model, calculation, interchange and reference verification. Continue existing bounded fixes, but attach each to requirement IDs and fixture evidence. Do not schedule a general rewrite or a promised completion date before G0 reveals the baseline's complete surface.

| Order | Work package | Concrete result | Dependency |
| --- | --- | --- | --- |
| 1 | Reference environment and inventory | Working exact-build Visio plus indexed feature/workflow catalog and proof of installation | Supported installation/license and required services/drivers |
| 2 | Compatibility ledger and warning UX | Five-dimension status per feature/format; navigable document diagnostics | Current parser/calculation diagnostics |
| 3 | Public interchange qualification | Bidirectional small corpus with private metadata stripped; failures retained by phase | Reference environment |
| 4 | Source/model identity and inheritance | Stable master/shape/row identity, correct overrides and selective patching | Interchange cases and current model review |
| 5 | Calculation/text/theme vertical slice | Reference-verified intelligent master with control, field, theme and rich text | Inventory-prioritized functions and cells |
| 6 | Connector/container/swimlane slice | Stable glue, route editing, lane membership and reversible layout | Identity and calculation foundations |
| 7 | Data/process slice | Keyed table links, refresh preview, data graphics, BPMN issues and report export | Typed data, containers and validation framework |
| 8 | Legacy/platform feasibility | Measured VSD semantic path and Windows automation/OLE/add-in bridge feasibility | Representative baseline fixtures; begin discovery alongside steps 1–3 |
| 9 | Specialist family expansion | Independent acceptance packs for every inventoried solution | Reusable solution/validation/data interfaces |
| 10 | Full qualification and extensions | G4 evidence; separately scoped GX roadmap | All baseline dependencies and product trials |

Resourcing should cover native interaction/accessibility, format/calculation engineering, specialist solution/data engineering, and independent compatibility QA. These are workstreams, not a headcount estimate. Effort estimation follows the inventory and high-risk feasibility results.

## 12. Risks, decisions and research limits

| Risk / decision | Product consequence | Proposed resolution / owner |
| --- | --- | --- |
| Baseline surface is not yet exhaustively inventoried | A polished editor could be mistaken for completion | Compatibility lead owns G0 catalog and immutable applicability records |
| Binary VSD semantics are incomplete | Legacy customers may lose editability/behavior | Format lead qualifies independent binary fixtures and preserves experimental labeling |
| COM/VBA/add-ins/OLE depend on Windows mechanisms | Native equivalents may fail existing scripts/solutions | Architecture lead prototypes a clearly scoped bridge; product owner decides any target change explicitly |
| Microsoft docs mix versions or disagree | Wrong features could be added to or removed from scope | Reference runtime evidence settles applicability; research register retains conflicts |
| Rendering depends on fonts and platform text engines | Text can wrap differently despite correct geometry | QA maintains named fonts, substitutions and approved per-fixture differences |
| Formula/theme/master behavior has combinatorial interactions | Isolated function tests can pass while diagrams fail | Mixed-feature vertical fixtures and reference differential tests |
| Bundled library rights and third-party icon terms | Content may be technically usable but unsuitable for distribution | Release owner uses provenance records and independently authorized content; imported user content remains separate |
| OS target and dependency minimums differ | Users may install an unsupported build | Release owner publishes tested bundle-derived minimums before broadening support |
| Cloud/data APIs, tenant policy and products change | Integrations can become unavailable | Integration owner versions adapters and verifies prerequisites before release |
| Collaboration is a separate distributed-system product | File sync could be oversold as simultaneous editing | GX capability has its own convergence/permissions/recovery qualification |
| Market and pricing are unvalidated | Engineering priorities may miss adoption needs | Product owner interviews target users and runs observed document tasks |

### 12.1 Explicitly unresolved product choices

Decisions that can proceed with the stated defaults: prioritize local Mac workflows; retain Professional 2019 as baseline; use current Visio as extension reference; preserve existing native document conventions; keep telemetry off by default.

Decisions requiring evidence before commitment: exact supported macOS range and Intel support; Windows-dependent compatibility strategy; supported CAD generations; source-connector/authentication matrix; permitted bundled content; collaboration provider; commercial packaging; any relaxation of the full baseline target. They do not prevent foundational work and are not treated as approvals to implement unrelated services.

### 12.2 Completeness statement

This specification supplies the product scope, interaction model, normative requirements, architecture direction, quality targets, qualification rules and delivery approach. It is not Microsoft's internal product specification and does not claim an exhaustive command-by-command runtime inventory. G0 must create that inventory and add detailed family/member requirements where needed. Until then, full parity remains an objective with explicitly identified evidence gaps, not an achieved status.

[S01]: https://support.microsoft.com/en-us/visio/compare-visio-versions-and-features
[S02]: https://support.microsoft.com/en-us/visio/visio-for-the-web-faq
[S03]: https://support.microsoft.com/en-us/visio/what-s-new-in-visio-2024
[S04]: https://support.microsoft.com/en-us/accessibility/visio/keyboard-shortcuts-for-visio
[S05]: https://support.microsoft.com/en-us/visio/beginner-tutorial-for-visio
[S06]: https://support.microsoft.com/en-us/visio/add-connectors-between-visio-shapes
[S07]: https://support.microsoft.com/en-us/visio/create-save-and-share-custom-stencils
[S08]: https://support.microsoft.com/en-au/visio/apply-a-professional-look-to-your-drawings-with-themes
[S09]: https://learn.microsoft.com/en-us/office/client-developer/visio/about-the-shapesheet-spreadsheet
[S10]: https://learn.microsoft.com/en-us/office/client-developer/visio/about-cell-references
[S11]: https://learn.microsoft.com/en-us/office/client-developer/visio/cells-visio-shapesheet-reference
[S12]: https://learn.microsoft.com/en-us/office/client-developer/visio/functions-visio-shapesheet-reference
[S13]: https://support.microsoft.com/en-us/visio/video-manage-shapes-by-adding-layers
[S14]: https://support.microsoft.com/en-us/visio/clarify-the-structure-of-diagrams-by-using-containers-and-lists
[S15]: https://support.microsoft.com/en-us/visio/importing-data-into-visio-an-overview
[S16]: https://support.microsoft.com/en-us/visio/data-graphics-an-overview
[S17]: https://support.microsoft.com/en-us/visio/create-a-data-visualizer-diagram
[S18]: https://support.microsoft.com/en-us/visio/create-a-diagram-in-excel-with-the-visio-data-visualizer-add-in?ad=us&rs=en-us&ui=en-us
[S19]: https://support.microsoft.com/en-us/visio/process-diagrams-in-visio
[S20]: https://support.microsoft.com/en-us/visio/create-bpmn-compliant-processes
[S21]: https://support.microsoft.com/en-au/visio/validate-a-structured-diagram
[S22]: https://support.microsoft.com/en-gb/visio/uml-diagrams-in-visio
[S23]: https://support.microsoft.com/en-us/visio/create-an-organization-chart-automatically-from-employee-data
[S24]: https://support.microsoft.com/en-us/visio/video-create-a-floor-plan
[S25]: https://support.microsoft.com/en-us/visio/create-a-timeline-in-visio
[S26]: https://support.microsoft.com/en-us/visio/share-schedule-and-task-details-with-a-visio-gantt-chart
[S27]: https://support.microsoft.com/en-us/visio/create-a-database-model-also-known-as-entity-relationship-diagram-in-visio
[S28]: https://learn.microsoft.com/en-us/office/client-developer/visio/introduction-to-the-visio-file-formatvsdx
[S29]: https://learn.microsoft.com/en-us/openspecs/sharepoint_protocols/ms-vsdx/50c23601-c943-4ff2-b4a1-02445f52daf0
[S30]: https://support.microsoft.com/en-us/visio/import-or-insert-graphics-into-visio-drawings
[S31]: https://support.microsoft.com/en-us/visio/import-an-autocad-drawing
[S32]: https://learn.microsoft.com/en-us/visualstudio/vsto/visio-object-model-overview?view=visualstudio
[S33]: https://support.microsoft.com/en-us/visio/work-together-on-visio-drawings
[S34]: https://learn.microsoft.com/en-us/office365/servicedescriptions/visio-online-service-description/visio-online-service-description
[S35]: https://support.microsoft.com/en-us/accessibility/visio/make-your-visio-diagram-accessible-to-people-with-disabilities
[S36]: https://support.microsoft.com/en-us/accessibility/visio/screen-reader-support-for-visio
