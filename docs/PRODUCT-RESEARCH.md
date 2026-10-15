# MacVisio product research and evidence register

Research date: 16 October 2026. Companion to the [product specification](PRODUCT-SPEC.md).

## Method and interpretation

Research used Microsoft product, support and developer documentation, plus the MacVisio repository. Only Microsoft primary sources are used for external technical conclusions. Search-result excerpts were sufficient for some narrow feature-existence checks; selected key pages were opened for detail. No Windows Visio runtime was observed, no installer was analyzed in this research, and no customer interviews or competitor hands-on trials were performed.

The sources establish a public capability benchmark, not Microsoft's private design, implementation or exhaustive test contract. The specification's requirements, architecture, release gates and performance/usability targets are original proposals for MacVisio. A requirement's B classification means it belongs to the intended baseline scope subject to exact-build confirmation; a public page's broad “Applies To” list is not conclusive runtime evidence.

The existing repository target remains all Visio Professional 2019 functions with VSD/VSDX read/write. Current editions are references for additional capability and market context. Neither an implementation milestone nor browser limitations reduce that target.

## Microsoft source register

All sources were accessed or surfaced in research on 16 October 2026. Source IDs match the specification's link definitions. “Use” is intentionally narrow: exact edition/build availability still needs reference verification.

| ID | Primary source | Use in the specification |
| --- | --- | --- |
| S01 | [Compare Visio versions and features](https://support.microsoft.com/en-us/visio/compare-visio-versions-and-features) | Edition segmentation and general/specialist capability families; not an exhaustive 2019 command inventory |
| S02 | [Visio for the web FAQ](https://support.microsoft.com/en-us/visio/visio-for-the-web-faq) | Microsoft documents Mac browser use; web capability statements need reconciliation with newer specific guides |
| S03 | [What's new in Visio 2024](https://support.microsoft.com/en-us/visio/what-s-new-in-visio-2024) | Newer visual content, Professional network/software additions, search and appearance; kept separate from 2019 |
| S04 | [Keyboard shortcuts for Visio](https://support.microsoft.com/en-us/accessibility/visio/keyboard-shortcuts-for-visio) | Breadth of keyboard-accessible commands; Mac mappings are independently designed |
| S05 | [Beginner tutorial](https://support.microsoft.com/en-us/visio/beginner-tutorial-for-visio) | Template/shape/connection workflow and template-specific settings |
| S06 | [Add connectors between shapes](https://support.microsoft.com/en-us/visio/add-connectors-between-visio-shapes) | Connection workflows and custom connection points |
| S07 | [Create, save and share custom stencils](https://support.microsoft.com/en-us/visio/create-save-and-share-custom-stencils) | Reusable masters, custom stencil editing/sharing and web import prerequisites |
| S08 | [Apply a professional look with themes](https://support.microsoft.com/en-au/visio/apply-a-professional-look-to-your-drawings-with-themes) | Coordinated color/effect theme behavior; not proof of Mac rendering fidelity |
| S09 | [About the ShapeSheet spreadsheet](https://learn.microsoft.com/en-us/office/client-developer/visio/about-the-shapesheet-spreadsheet) | Object sheets, sections/rows/cells, formulas and evaluated values |
| S10 | [About cell references](https://learn.microsoft.com/en-us/office/client-developer/visio/about-cell-references) | Reference scopes, sheet IDs/names and escaped names |
| S11 | [ShapeSheet cells](https://learn.microsoft.com/en-us/office/client-developer/visio/cells-visio-shapesheet-reference) | Authoritative cell catalog for inventory expansion |
| S12 | [ShapeSheet functions](https://learn.microsoft.com/en-us/office/client-developer/visio/functions-visio-shapesheet-reference) | Authoritative function catalog; individual function/version semantics need separate tests |
| S13 | [Manage shapes by adding layers](https://support.microsoft.com/en-us/visio/video-manage-shapes-by-adding-layers) | Layer organization and properties; distinct from object order or group parentage |
| S14 | [Containers and lists](https://support.microsoft.com/en-us/visio/clarify-the-structure-of-diagrams-by-using-containers-and-lists) | Membership, fit-to-content, locking and ordered specialized lists |
| S15 | [Importing data: overview](https://support.microsoft.com/en-us/visio/importing-data-into-visio-an-overview) | Row-to-shape links, refresh and professional data-source families |
| S16 | [Data graphics: overview](https://support.microsoft.com/en-us/visio/data-graphics-an-overview) | Text, bars, icons and color-by-value visualizations |
| S17 | [Create a Data Visualizer diagram](https://support.microsoft.com/en-us/visio/create-a-data-visualizer-diagram) | Desktop Excel-driven generation/two-way synchronization and Plan 2 prerequisite |
| S18 | [Diagram in Excel with the Visio Data Visualizer add-in](https://support.microsoft.com/en-us/visio/create-a-diagram-in-excel-with-the-visio-data-visualizer-add-in?ad=us&rs=en-us&ui=en-us) | Explicit retirement notice naming March 2026; distinguish add-in from desktop templates |
| S19 | [Process diagrams in Visio](https://support.microsoft.com/en-us/visio/process-diagrams-in-visio) | Methodology/template families for solution inventory |
| S20 | [Create BPMN-compliant processes](https://support.microsoft.com/en-us/visio/create-bpmn-compliant-processes) | BPMN 2.0 Analytic graphical notation, connector types and validation limits |
| S21 | [Validate a structured diagram](https://support.microsoft.com/en-au/visio/validate-a-structured-diagram) | Rule-based issue reporting and structured-process validation |
| S22 | [UML diagrams in Visio](https://support.microsoft.com/en-gb/visio/uml-diagrams-in-visio) | Supported modern UML families and 2019/Plan 2 template guidance |
| S23 | [Generate an organization chart from employee data](https://support.microsoft.com/en-us/visio/create-an-organization-chart-automatically-from-employee-data) | Hierarchy input, wizard workflow, layout/photos and data comparison |
| S24 | [Create a floor plan](https://support.microsoft.com/en-us/visio/video-create-a-floor-plan) | Measured floor-plan content and custom drawing scale |
| S25 | [Create a timeline in Visio](https://support.microsoft.com/en-us/visio/create-a-timeline-in-visio) | Date-driven milestones/intervals and desktop timeline workflow |
| S26 | [Share task details with a Gantt chart](https://support.microsoft.com/en-us/visio/share-schedule-and-task-details-with-a-visio-gantt-chart) | Task/schedule presentation; not an assumption of full project-management capabilities |
| S27 | [Create a Database Model](https://support.microsoft.com/en-us/visio/create-a-database-model-also-known-as-entity-relationship-diagram-in-visio) | Database modeling and reverse-engineering caveats; mixes historical and current edition guidance |
| S28 | [Introduction to the VSDX file format](https://learn.microsoft.com/en-us/office/client-developer/visio/introduction-to-the-visio-file-formatvsdx) | OPC/ZIP/XML, relationships and six modern drawing/stencil/template extensions; macro-free vs macro-enabled distinction |
| S29 | [MS-VSDX specification](https://learn.microsoft.com/en-us/openspecs/sharepoint_protocols/ms-vsdx/50c23601-c943-4ff2-b4a1-02445f52daf0) | Formal public VSDX reference; is not a binary VSD format specification |
| S30 | [Import/insert graphics](https://support.microsoft.com/en-us/visio/import-or-insert-graphics-into-visio-drawings) | Declared raster/vector/CAD import families and inserted CAD view behavior |
| S31 | [Import an AutoCAD drawing](https://support.microsoft.com/en-us/visio/import-an-autocad-drawing) | CAD scale/layer workflow and edition-dependent version restrictions |
| S32 | [Visio object model overview](https://learn.microsoft.com/en-us/visualstudio/vsto/visio-object-model-overview?view=visualstudio) | Application/document/page object hierarchy and distinction between API and file compatibility |
| S33 | [Work together on Visio drawings](https://support.microsoft.com/en-us/visio/work-together-on-visio-drawings) | Comments, storage prerequisites, same-application coauthoring and desktop/web editing restriction |
| S34 | [Visio service description](https://learn.microsoft.com/en-us/office365/servicedescriptions/visio-online-service-description/visio-online-service-description) | Web/desktop reference matrix with caveats; directs readers to current comparison pages |
| S35 | [Make diagrams accessible](https://support.microsoft.com/en-us/accessibility/visio/make-your-visio-diagram-accessible-to-people-with-disabilities) | Accessible diagram content and review practices |
| S36 | [Screen-reader support](https://support.microsoft.com/en-us/accessibility/visio/screen-reader-support-for-visio) | Dedicated accessible authoring/navigation workflows; Mac VoiceOver support is a separate implementation requirement |

## Research findings that affect product decisions

### 1. The baseline is a professional desktop product

The public edition comparison and the existing project scope support a broader target than a flowchart editor. Specialist solution behavior, intelligent shapes, data and automation must be tracked alongside canvas commands. Browser parity would leave much of the agreed scope unresolved. This is a product-planning inference from [the comparison](https://support.microsoft.com/en-us/visio/compare-visio-versions-and-features) and [the local objective](PLAN.md).

### 2. Public preservation and successful interchange need separate tests

The format introduction describes structured package relationships; the repository already preserves unsupported parts. A saved package can therefore retain source content that the editor does not understand. The five compatibility dimensions in the specification prevent that preservation from being presented as complete editing or behavioral support. This is an inference from [VSDX packaging](https://learn.microsoft.com/en-us/office/client-developer/visio/introduction-to-the-visio-file-formatvsdx) and [local compatibility boundaries](COMPATIBILITY.md).

### 3. ShapeSheet is a major product system

The ShapeSheet concept and reference pages make formula-driven appearance/behavior part of the product model. An implementation plan needs contexts, inheritance, dependencies and an execution policy in addition to a list of supported functions. The proposed architecture is an independent MacVisio design, informed by [ShapeSheet documentation](https://learn.microsoft.com/en-us/office/client-developer/visio/about-the-shapesheet-spreadsheet).

### 4. Avoid a retired add-in dependency

The [Excel add-in notice](https://support.microsoft.com/en-us/visio/create-a-diagram-in-excel-with-the-visio-data-visualizer-add-in?ad=us&rs=en-us&ui=en-us) names March 2026 for retirement. It does not establish that the distinct [desktop Data Visualizer workflow](https://support.microsoft.com/en-us/visio/create-a-data-visualizer-diagram) was retired. The specification therefore treats native table-driven generation as an extension rather than designing around the add-in.

### 5. Standard notation is not executable semantics

Microsoft states that [BPMN validation](https://support.microsoft.com/en-us/visio/create-bpmn-compliant-processes) checks graphical elements rather than attribute correctness. MacVisio should distinguish notation, graphical validation, semantic analysis, file interchange and execution. Equivalent caution applies to UML modeling and Gantt/project-management claims.

### 6. Platform integrations need independent feasibility work

The documented [Visio object model](https://learn.microsoft.com/en-us/visualstudio/vsto/visio-object-model-overview?view=visualstudio) and local scope include automation concerns distinct from file editing. Native Mac APIs do not automatically run existing COM clients or Windows add-ins. A bridge/native-equivalent strategy needs an explicit support contract; abandoning those baseline obligations is a scope decision, not an incidental implementation choice.

## Conflicts and applicability issues

| Issue | Evidence | How the specification handles it |
| --- | --- | --- |
| Web feature availability changes | The broad comparison/support pages and current detailed guides do not consistently agree about layers/containers and custom stencil import | No exhaustive current web matrix is claimed; use exact plan/build and specific workflow verification. [Containers](https://support.microsoft.com/en-us/visio/clarify-the-structure-of-diagrams-by-using-containers-and-lists), [custom stencils](https://support.microsoft.com/en-us/visio/create-save-and-share-custom-stencils), [FAQ](https://support.microsoft.com/en-us/visio/visio-for-the-web-faq) |
| Desktop coauthoring inconsistency | The service table lists desktop real-time coauthoring as unavailable while the collaboration guide describes desktop coauthoring prerequisites | Record both; do not make unrestricted native Microsoft coauthoring an assumption. [Service table](https://learn.microsoft.com/en-us/office365/servicedescriptions/visio-online-service-description/visio-online-service-description), [guide](https://support.microsoft.com/en-us/visio/work-together-on-visio-drawings) |
| Broad “Applies To” metadata mixes product eras | Database-model page includes historical product/edition guidance and a Plan 2 note | Freeze actual installed build and drivers; verify reverse-engineering applicability before qualifying the feature. [Database model](https://support.microsoft.com/en-us/visio/create-a-database-model-also-known-as-entity-relationship-diagram-in-visio) |
| Similar UML terminology refers to different generations | Older UML static-structure/model features are not necessarily the modern UML template set | Inventory the 2019 family rather than importing every legacy UML claim. [Current UML catalog](https://support.microsoft.com/en-gb/visio/uml-diagrams-in-visio), [historical static structure](https://support.microsoft.com/en-us/visio/create-a-uml-static-structure-diagram) |
| CAD support depends on edition/version | AutoCAD guide distinguishes subscriber and non-subscriber version handling | Publish exact format/entity/version support; do not equate CAD insertion with CAD authoring. [CAD guide](https://support.microsoft.com/en-us/visio/import-an-autocad-drawing) |
| Retirement notices can coexist with older feature marketing | Add-in documentation still contains creation instructions alongside a retirement warning | Use the retirement warning for dependency planning; retain a separate desktop-generation requirement. [Add-in page](https://support.microsoft.com/en-us/visio/create-a-diagram-in-excel-with-the-visio-data-visualizer-add-in?ad=us&rs=en-us&ui=en-us) |

These inconsistencies are research limitations, not reasons to invent a unified Microsoft capability matrix. For the baseline, an observed exact-build result is the acceptance authority. Public documentation helps identify what to investigate.

## Local evidence reviewed

| Local source | What it establishes | Limitation |
| --- | --- | --- |
| [README](../README.md) | Current application workflows, format boundaries and distribution statements | Capability claims were not rerun in this documentation task |
| [Implementation plan](PLAN.md) | Full Professional 2019 target and substantial remaining work | A plan is not acceptance evidence |
| [Compatibility matrix](COMPATIBILITY.md) | Detailed implemented slices and explicit outstanding gaps | Some headings reflect earlier releases; avoid treating them as a fresh complete audit |
| [Windows validation](WINDOWS-VALIDATION.md) | Existing differential harness and reported unavailable Visio runtime | Guest state was not reinspected during this task |
| [Interchange corpus](INTERCHANGE-CORPUS.md) | Existing public-content-only synthetic validation approach | Independent parsing is not Windows Visio acceptance |
| [ShapeSheet audit](SHAPESHEET-AUDIT.md) | Distinction between syntax inventory, evaluated occurrences and semantic correctness | Occurrence counts do not establish unique feature coverage |
| [Document workflow](DOCUMENT-WORKFLOW.md) | Existing native interaction decisions and evidence boundaries | Some implementation descriptions predate newer background-loading changes |
| [Open performance](OPEN-PERFORMANCE.md) | Measured examples, profiling facilities and bounds of local measurements | One document/machine is not a general performance guarantee |
| [Package manifest](../Package.swift) | Swift target/platform and pinned dependencies | Source target does not establish the shipped bundle's minimum OS |
| [Document implementation](../Sources/MacVisio/Document.swift) | NSDocument and snapshot-based save design in selected inspected code | A selected source inspection is not a full concurrency/recovery audit |
| [Model](../Sources/MacVisio/Model.swift), [drawing](../Sources/MacVisio/Drawing.swift), [source inventory](../Sources/MacVisio) | Starting points for proposed architecture and native drawing | No rewrite recommendation follows from this inspection |

## Follow-up research needed for qualification

1. Install/license and freeze the exact Visio Professional 2019 reference build; record all relevant prerequisites.
2. Inventory the entire runtime surface and expand solution/API/filter entries into detailed subrequirements.
3. Collect permissioned, representative drawings from each target persona and observe editing/handoff tasks.
4. Verify modern feature availability in the exact plans/tenants targeted for extensions.
5. Prototype the binary VSD semantic path and Windows automation/add-in/OLE strategy early.
6. Confirm content redistribution permissions, supported platform costs and commercial packaging through the appropriate owners.

No delivery-date, budget, headcount, market-size or willingness-to-pay estimate is supported by this research alone.
