# M2 search and text preparation

Branch: `codex/m2-native-editor`. Slice status: **implemented_unaccepted**. These value-model helpers are preparatory engineering. M2, WP-10-T02 and WP-11-T03 remain unaccepted; native edit integration waits for accepted M1 contracts.

## Bounded decomposition recorded before implementation

| Parent (L) | Child | Scope and completion evidence |
| --- | --- | --- |
| WP-10-T02 | A | Cross-page value-model results with page/shape identity, surface, UTF-16 range and exact source snapshot; deterministic ordering; text/shape/data corpus. |
| WP-10-T02 | B | Targeted text replacement with stale-result, lock/protection, field and grapheme-boundary checks; unrelated character/paragraph/opaque metadata retained; focused tests. |
| WP-10-T02 | C | Command search, enabled-state explanations and committed single-undo edit integration; deferred until accepted M1. |
| WP-10-T02 | D | Native search/navigation/input-focus journey; verify canvas shortcuts cannot run during text input; deferred. |
| WP-11-T03 | A | UTF-16 replacement corpus covering mixed runs, RTL, decomposed combining characters and emoji; model tests only. |
| WP-11-T03 | B | Pure deterministic missing-font inventory and rendering choice from an injected installed-font catalog; requested metadata stays untouched; focused tests. |
| WP-11-T03 | C | Real native input/composition/IME, selection, keyboard and save/reopen journeys; deferred and cannot be closed by unit checks. |

Each child retains the parent acceptance requirements. A/B results do not imply command-search, input routing, IME, VoiceOver, undo, save/reopen, layout or Visio compatibility acceptance.

## Integration contract

`DocumentSearch.find(Query, in:)` returns a `Results` random-access collection. Each match carries stored page/object IDs, an explicit text/shape/data surface, UTF-16 range and the exact source string. Results follow stored page, node, surface and connector order. Each stored background page is searched once. Hidden and locked objects remain discoverable; visibility and edit eligibility are separate concerns. Shape search covers kind title, object UUID and preserved source ID. Data search covers property key, label and value; connector labels are searchable text.

Queries use fixed `en_US_POSIX` case-insensitive matching by default, with an explicit case-sensitive option. Empty queries/domains produce complete empty results. Nonoverlapping matches cover whole grapheme clusters; a query for one scalar inside an emoji/flag/combining cluster produces no partial-cluster match. AppKit selection offsets come directly from the source UTF-16 string, including canonical-equivalent accent matches.

`Query.maxResults` defaults to 10,000; accepted explicit budgets are 1...100,000. `Results.completion` is `complete`, `truncated` or `invalidBudget`. Invalid budgets return no matches with `invalidBudget`; a limit becomes `truncated` only when one extra accepted match proves incompleteness. Callers must surface that state rather than claim the whole document has been searched. Boundary checks walk forward as needed and stop with the result budget, without allocating an index for all text characters.

`DocumentSearch.replacementBlock(for:in:)` supplies actionable disabled-state reasons. `replacing(_:with:in:)` revalidates the current snapshot and returns a candidate value. It supports shape text and connector labels; shape identity and shape-data surfaces support navigation only. Typed data conversion, formulas and data editing require a separate committed edit. Stale source strings are compared by exact UTF-8 bytes, so canonically equivalent text with different UTF-16 offsets cannot reuse an old match. Invalid, empty, overflowing or partial-grapheme ranges are rejected.

Replacement checks current shape/group/layer locks, inherited `LockTextEdit`, duplicate/missing target and ancestor IDs, cycles, malformed run mappings and unmapped fields. Formula-dependent protection is blocked pending accepted calculation evidence rather than treating a cached false value as authoritative. Matches intersecting a nonempty text field, or crossing an empty field, are rejected. Adjacent fields, field tokens/definitions, character/paragraph source indices, requested font names, opaque style cells and unrelated sheet metadata are retained. Replacement text inherits the first selected character and paragraph styles. Exact no-op text replacement retains the original snapshot. Unselected runs retain their boundaries; replacements never flatten the whole rich-text string.

`FontSubstitution` accepts an injected catalog of installed font names, an ordered fallback list and optional explicit aliases. Exact installed spelling wins, then case-folded installed names, explicit alias order, fallback order, and finally the `System` rendering sentinel. Ambiguous catalog/policy ordering is resolved deterministically by UTF-8 byte order. Catalog deduplication and requested-name inventory distinguish canonical-equivalent byte spellings. The inventory includes base styles, every stored run and empty field runs, with page/node/run provenance. It never mutates the diagram or rewrites requested names, source indices or opaque font cells. It does not claim glyph coverage or layout equivalence; the native font renderer has not been changed.

No provisional transaction, calculation or scene API is consumed. The accepted M1 integration must obtain a current committed snapshot, revalidate eligibility, commit the candidate as one edit/undo operation, recalculate as required, and navigate using the accepted scene contract. It must also map source selections into the text editor when empty field placeholders are visible and reject cross-document results. This helper's IDs alone are not a document-instance identity.

## Local evidence

- Swift parse-only validation passes for both helpers and both test files. No full Swift build was run by this worker.
- The primary's first focused cached run passed 16 tests (10 search, 6 font) in `build/m2-search-text.log`, before the final result-budget and ancestor/catalog review changes.
- The primary's final full native run after result-budget and review changes passed: **485 tests executed, 13 skipped, zero failures**, in 15.759 seconds; log `build/m2-full-native.log`. The skips concern installer assets and the independent packaged reader. This includes all 17 new tests (11 search, 6 font): cross-page/domain/order/identity, case sensitivity, UTF-16 RTL/combining/emoji, full-cluster-only search, exact result budget/truncation/invalid budgets, repeated selected text with different styles, cross-run insertion/deletion/no-op, fields and empty fields, stale exact bytes/invalid ranges, current locks/protection, typed-data read-only status, duplicate/missing targets, connector labels, malformed runs/unmapped fields, font aliases/fallbacks/determinism/inventory and unchanged requested metadata.

The new search/font tests do not exercise command search, native find UI, real IME/composition events, actual RTL caret navigation, keyboard focus or canvas shortcut routing, VoiceOver, single undo, save/reopen, native installed-font enumeration/rendering, exported glyph layout or Visio compatibility. Those acceptance layers remain open. This passing run does not dispose of M1's historical intermittent full-suite failure.
