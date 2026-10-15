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
