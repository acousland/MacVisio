# M3 domain and evidence contracts

16 October 2026. Design/discovery against `7c270124993bac09967109f95e603ebb47bd98ff`.
This document freezes acceptance inputs, not provisional Swift APIs. Dependent
production changes wait for accepted M1+M2 engineering commits and the applicable
M0 inventory/harness contract. The implementation must adapt to those actual APIs.

## Identity and ownership

An imported master is identified by the source document identity, master index
entry ID, master part, and its stable native identity. A style has an independent
document-scoped identity and source style ID. A sheet belongs to one explicit
owner: document, page, master shape, page shape, connector or style. A source
numeric shape ID is scoped to its page/master part. Two masters/styles with the
same display name must remain distinct; a renamed display name never remaps
references. Universal names, imported unique/base IDs and relationship IDs remain
source properties rather than interchangeable native UUIDs.

The existing imported-master expansion is valuable: retain its grouped geometry,
instance-scoped formula rewriting and minimal inherited overrides. Expansion is
an evaluated projection, not the authoritative master definition. Track which
master shape, row and cell produced an inherited value, which local override is
explicit, and which inherited item is deleted. Recalculation cannot convert a
cached inherited value into an explicit override merely by updating its cache.

The new `m3-intelligent` synthetic fixture deliberately uses master IDs 7/8 with
equal display names, styles 4/5 with equal display names, and page shape 1 in a
different page scope from master shape 1. This independently authored collision
case is a prerequisite for identity acceptance; local parser success is narrower.

## Independent relationships

Group parentage determines transform/drawing hierarchy. Container membership,
ordered-list membership, lane membership, connector topology, background-page
dependency and master-instance inheritance have separate relationship kinds and
stable IDs. None can be inferred solely from group parentage. An object may be a
transformed group child and a semantic member at the same time. List ordering is
explicit. Each relationship validates owner/member scope, cardinality and cycles
using its own rules; graph cycles do not become illegal group cycles.

A connector is a shape with a sheet, text, geometry, style, data, controls,
protections and a source identity. Its source/target graph endpoints are separate
from shape ownership and grouping. A connector's free endpoint, glued endpoint,
named/numeric connection row and direction/type must survive copy/remap and
public serialization. Text or formulas on connectors must use the shared sheet
and text semantics, not a second partial expression interpreter.

## Shared cell semantics

Store cell cached value, formula, unit, section/row identity, deletion state and
origin separately. Distinguish absent/inherited/explicit/deleted cells. Indexed
and named rows retain both identities where present; renaming updates references
through an explicit remapping plan. Formula evaluation addresses identify owner,
cell, committed input revision, reference scope and foreground background context.

The existing `ShapeSheetContext` resolves node/page hosts but has no connector,
document, master or style host. Extending it must preserve a single parser, typed
coercion/error contract and dependency engine. Dynamic/volatile references retain
conservative invalidation and visible diagnostics. Unknown functions retain cached
results with a qualified state. Catalog discovery or an occurrence of a function
name is not proof of implemented/accepted semantics in every owner context.

Master updates first resolve effective values, then invalidate only their actual
instance dependencies through accepted M1 transactions. Explicit local overrides
stay local; deleted inherited rows stay deleted. Test changed inherited value,
unchanged local override, row rename/delete, cross-instance isolation, undo/redo,
save/reopen with metadata removed, and repeated-save preservation together.

## Editing, replacement and migration

Replacement produces a reviewable immutable remapping proposal before commit.
Ports, data rows, fields, formulas, media and styles map by scoped identity and
declared structural compatibility. A display-name match alone is insufficient.
Ambiguous or unavailable targets remain explicit errors in the proposal, with no
partial mutation. Copy/paste allocates destination IDs per scope, rewrites only
references whose owner moved, and preserves references to unmoved owners or
reports the unavailable dependency. Apply as one committed, undoable edit using
the accepted M1/M2 interface, including its affected set and invalidation result.

Older native metadata must migrate from preserved public parts when those parts
contain semantics absent from the old model. A source-free older native document
does not gain invented master identities. Preserve its useful editable behavior
and explicitly diagnose unavailable source semantics. Public hashes remain a
necessary cache check; a native-cache reopen is never a public capability test.

## Presentation and publication

Node and connector rich text share UTF-16 edit ranges, paragraph/character cells,
fields, requested fonts and unchanged-source-run preservation. Use accepted M2
input and diagnostics contracts for caret/composition and unsupported content.
Text measurement follows the accepted M1 execution policy. Paint, selection,
scroll and hit testing cannot evaluate formulas or mutate sheets (AC-01/02).

Geometry/theme/text/connector changes publish an evaluated scene with explicit
dependency keys. Screen/export share accepted M1 scene semantics (AC-06/07).
View-only overlays stay separate. A layer may be visible while nonprinting; print
policy is explicit rather than an accidental consequence of canvas visibility.
Drawing scale and printer scale are independent. The physical acceptance pack
must measure one metre at 1:50 as 20 mm at printer scale 100%, with named fonts,
page bounds, margins, output resolution and tolerance. The current synthetic
fixture records page/background/scale source cells; it does not establish that
physical or rendered acceptance.

## Preservation and rebasing

No-edit saves retain public and opaque part bytes. An instance edit patches only
the intended public shape/row/cell; master/style/theme resources and unrelated
shapes remain intact. Master/style edits patch their authoritative source parts,
then preserve inherited instance references rather than flattening every page.
Dependency packaging follows relationships and content types into a fresh empty
host, never assumes conventional `visio/pages/page1.xml` paths, and never merges
resources on display-name similarity. Validate destination-scoped relationship
IDs and resource collisions before writing.

Repeated saves rebase against the successful committed snapshot. A failed write
does not replace the last valid baseline; a completed older save cannot overwrite
newer live edits or clear their dirty state (AC-04/05). Unsupported public content
uses M0/M2's preservation/editing policy and object-level diagnostic contract
(AC-08). Native metadata may accelerate reopening but cannot be the only carrier
of any claimed public capability.

## Source integration checks before implementation

These are source-confirmed boundaries in the frozen implementation, not defects
claimed in features it does not yet implement:

- `VisioPreservation.write` returns early when archived original pages equal live
  pages. A new master/style/document-sheet edit must participate in that decision.
  Test an edit to a definition with no directly edited page, then a second save,
  public-only reopen, explicit instance override and failed-write retry together.
- `VisioFormat.NativeEnvelope` stores a page-oriented model and bindings, with
  versioned hydration of previously missing public semantics. New domain storage
  needs an explicit migration/version contract and hash-checked public hydration.
  A valid older cache must not hide newly modeled master/style/connector content.
  Test both source-backed and source-free older native documents; never invent
  source identities for the latter.
- `ShapeSheetContext` builds `Sheet.*` identifiers from nodes only. Adding a sheet
  dictionary to an edge alone will not make connector references work. Extend the
  shared owner/dependency path, including node→connector and connector→node cells,
  scoped numeric IDs, host-dependent errors and local cyclic components. The
  accepted M1 dependency runtime must receive the resulting invalidation.
- Selection/stencil fragments currently transport page nodes and edges. New
  intelligent instances need their master/style/media/row dependencies and scoped
  remapping plan in a fresh empty host. A flattened fragment that looks correct
  immediately after drop cannot establish update/replacement behavior. Test the
  fresh-host public package, mutate its master, preserve explicit instance cells,
  and check expected-only source changes with native metadata removed.

No provisional M1/M2 method names are prescribed here. Integrate their actual
accepted contracts before choosing adapters or implementing these checks.

### Observed M1 extension points after unlock

Read-only review of committed M1 source at
`8ba1ff463127e75577777483474dc51d284a38d1` identified the following extension
points. The five reviewed files matched that commit's bytes; M1 remains
unaccepted and M2 has not integrated it. Recheck these observations against the
eventual accepted M2 candidate before implementation.

- `DocumentChanges.swift` currently compares document title/version, pages,
  source resources and active page. Its semantic classification excludes a
  source-resource-only change. Authoritative master/style/document-sheet edits
  need semantic affected sets that reach calculation, presentation, dirty state
  and undo, including a definition edit whose page instances have no local edits.
- `Document.swift` rebases a calculated snapshot's preserved archive to the
  latest successful archive when source lineage matches. Storing a definition
  edit solely as a change to archived part bytes can lose that edit at this
  boundary. Keep authoritative editable definitions in committed semantic state;
  qualification must include save, definition edit, undo/redo, another save and
  public-only reopen with the same source lineage, plus an older save completing
  after the definition edit.
- `CalculationDependencies.swift` indexes node sources, UUID dependencies and
  page-local public IDs. New connector/master/style/document owners must enter
  the same dependency and scoped-resolution contract. A changed definition must
  reach inheriting instance dependents across pages while respecting explicit
  overrides. Dynamic references retain conservative invalidation and visible
  work counts. Node-only counters cannot establish bounded work for new owners.
- `CalculationJobs.swift` inspects node/page formulas for text measurement and
  publishes an immutable result through owner/snapshot/revision validation. Any
  new owner's formulas must participate in execution-policy inspection,
  cancellation, request-local sessions and stale-result rejection. Definition
  editing must retain active-text Save/Close continuation behavior from M1.
- `UndoPayloadBudget.swift` caches page/node/edge charges and separately charges
  preserved resources and document metadata. New semantic definitions and their
  affected sets must participate in retained-cost accounting, including shared
  dependency closure and an oversized single action. A source-resource charge
  alone does not account for a separately retained editable definition model.

These are required integration checks for the new M3 domain. This review runs
no peer tests, changes no peer source and grants no upstream or M3 acceptance.

Read-only review of M2 preparation at
`d2bccb9098cf718a354aea49582b2dd4825da445` adds two integration checks. Its
`DocumentDiagnostic.Target` represents document, page, shape and connector;
definition/cell navigation must extend that typed ownership for M3. Source
part/Visio-ID/cell provenance already distinguishes failures, but current
`inspectCell` actions require a page target. Master/style/document-sheet issues
must retain their actual owner and supported action rather than fabricate a page
or shape. Test equal messages on distinct definitions and stale input rejection.

M2's `NativeSupportReport` reports supplied model counts/diagnostic buckets and
explicitly limited coverage. New definition counts, owner contexts or timing
stages need an intentional schema/coverage decision; preserve its exclusion of
formula text, source IDs, font names, paths and diagnostic prose. Its anonymous
legacy import-note bridge does not establish producer accuracy or a safe-save
policy for intelligent source features. M2 remains unaccepted preparation.

## Current evidence and open gates

`scripts/m3-public-evidence.py` compares public XML structure, all formula/value/
unit/identity attributes, text fragments, relationship kinds/content types and
opaque payload hashes. It ignores recognized native metadata, XML prefix and
attribute spelling/order, and relationship/content-type order. Shape/row/text
order remains meaningful. Its strict structural differences require disposition;
it does not prove semantic equivalence when Visio rewrites a formula or structure.
Mutation tests demonstrate that semantic losses are detected. The Swift fixture
tests cover no-edit preservation and isolated instance text edits against the
existing implementation, not the proposed new domain model.

Per-child acceptance must retain all five M0 evidence dimensions, exact inventory
and requirement IDs, local input/edit/undo/save checks, public-content validation
copies, reference-created and MacVisio-created directions, exact Visio build,
repair prompts, rendered/behavior/physical results and unresolved differences.
The M3 catalog must retain unknown runtime inventory items until the reference is
available. No full package or milestone is accepted because its decomposition,
fixture generator, parser or oracle checks pass.

Microsoft schema references consulted for fixture authorship:

- [Masters element](https://learn.microsoft.com/en-us/office/client-developer/visio/masters-elementvisio-xml)
- [DrawingML format scheme](https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.drawing.formatscheme)
- [DrawingML theme elements](https://learn.microsoft.com/en-us/dotnet/api/documentformat.openxml.drawing.themeelements)
