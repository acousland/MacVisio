# M2 integration contracts (proposed, not an upstream API)

These contracts guide fixtures and implementation after an accepted M1 handoff. They do not freeze or implement provisional M1 APIs.

## Document diagnostics and save impact

A diagnostic record needs a stable source code, severity (`information`, `warning`, `error`), feature dimension (`preservation`, `rendering`, `editing`, `behavior`, `interchange`), origin (`import`, `calculation`, `save`, `font`, `content`), explicit display state (`evaluated`, `cached`, `stale`, `unavailable`, `notApplicable`) and a target containing page UUID, optional shape/edge UUID, optional cell address and source part/Visio ID. The stable identity derives from code + target + source identity; presentation text is not an identity key. Distinct objects with the same failure remain distinct. Document-wide notes may lack an object target but must say so; never fabricate IDs from an anonymous string.

A calculation issue identifies its committed revision/input key. Unchanged issue state may be reused only when its dependency key is valid. Navigation selects the page and shape/edge, reveals its visual bounds, exposes the cell address and retains each document's view state. The status indicator counts actionable material issues; informational preserved metadata remains available without making every drawing look unsafe. A pane is per document and reflects both importer and calculation diagnostics. Cached geometry/text must be identified as cached rather than silently described as evaluated.

Save impact consumes the exact committed save snapshot and immutable source baseline, not selection or a gesture preview. Policy is per source feature and feature dimension. Editing an affected unsupported solution, master/formula relation, signature, foreign object or legacy reconstructed source may invalidate preservation/behavior/interchange; unrelated harmless opaque bytes do not alone justify a modal warning. Signing invalidation is document-wide when the signed package changes. A destructive overwrite requires a Cancel / Save a Copy / alternate native-format path; the safe copy must use another URL and leave the source bytes unchanged. Autosave cannot auto-accept a destructive conversion. Test both successful and failed writes, subsequent edits during encoding, undo to baseline, multiple documents and external modification. An unclassified source feature remains unresolved, not presumed safe.

## Keyboard, text and accessibility

Read stable object identities, order, bounds and visibility from the accepted retained scene/runtime. UI-specific accessibility elements carry IDs, never array offsets. Reading order starts from scene order with group membership and edge source/target relations exposed. Labels use explicit alternative descriptions when the model supports them, then text/kind; missing labels produce an actionable content check. Each element is independently selectable and reveals lock/protection explanations. Accessibility frames use the actual canvas→window→screen transform and update with scrolling/zoom. A selected object and keyboard focus are separately represented but share a visible focus ring.

Tab/Shift-Tab traverse visible graph objects in a documented stable order and can leave the canvas; a modifier or explicit command enters object traversal if ordinary Tab needs to leave the control. Arrow movement, modifier resize, Return text editing, explicit connection start/target/confirm/cancel and inspect commands all respect protections and commit through accepted M1 transactions with one undo contract. Toolbar/mouse and accessibility actions invoke the same command. Menus and command search explain disabled reasons instead of silently doing nothing. Avoid adding global shortcuts that steal ordinary letters from inline text, the field editor, search or marked-text composition. Native event journey fixtures must dispatch through a window/responder chain; invoking controller methods is narrower implementation evidence.

Text ranges are UTF-16 because NSTextView/NSAttributedString use UTF-16. Reject stale results, split surrogate/composed sequences and field overlap. Preserve unchanged character/paragraph cells and requested font names; a rendered fallback is not a source-font rewrite. IME testing requires an actual marked-text composition/cancel/commit journey, and VoiceOver requires a real assistive-technology journey. Unit assertions about NSTextView do not close either gate.

## Inspector and authoring

Show mixed values rather than copying the first selected shape into every control. Changing one property changes only that property; unedited rounded text commits nothing. Show paper font/line widths in points, drawing lengths in declared units and angle units explicitly. A guarded or layer-protected cell gives an explanation and remains unchanged. Document-wide previews are reversible transient view/model proposals, then a single committed edit or cancellation; they must follow M1's preview/snapshot policy.

A basic multipage flow fixture includes start/process/decision/subprocess, branch labels, attached connectors, align/distribute, second-page target and explicit off-page link. A hyperlink string alone is not proof of an operable off-page journey. Save/reopen and PDF/SVG share accepted scene semantics; decorations do not leak into output. Native acceptance does not establish external Visio acceptance.

## Required upstream evidence before integration

- M1 actual commits and handoff: committed/preview ownership, change sets, saved-state tokens, bounded indexes/scene, diagnostic/revision behavior, long-job and resources contracts; full-suite intermittency disposition.
- M0 actual ledger/harness commits: feature dimension vocabulary, unsupported-source policy, synthetic public fixtures/evidence schema; exact reference prerequisites may remain open.
- Separate Home changes: intentional integration commit or clearly isolated extension points; never copy the unrelated original dirty diff automatically.

## Prepared diagnostic transport slice

`DocumentDiagnostic.swift` supplies the independent Codable provenance record: typed target/source, five feature dimensions, cache/display state, producer input key and safe declarative actions. Identity excludes presentation wording; equal failures on distinct objects/cells remain distinct. The legacy note bridge truthfully stays document-scoped and cannot expose an invented object/cell action. This is **implemented, unaccepted preparation** for WP-13-T01; adapters, dependency-key checks, navigable pane, affected-source save policy and end-to-end accuracy are gated on accepted M0/M1 interfaces. No current calculation or importer output is relabelled as object-aware by this addition.
