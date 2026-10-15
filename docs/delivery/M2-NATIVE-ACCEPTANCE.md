# M2 native editor delivery and acceptance

Planning baseline: `7c270124993bac09967109f95e603ebb47bd98ff`. Branch: `codex/m2-native-editor`.

M2 is **in progress, unaccepted**. Preparation and independent trust work do not imply that M1 or M0 has passed. M1 runtime/transaction/calculation/scene APIs will only be integrated from a real handoff with passing local evidence. No distribution is authorized.

## Ownership and overlap

This managed worktree owns M2. The original checkout's uncommitted Home changes were inspected read-only on 16 October 2026: adaptive 780×640 preferred / 480×440 minimum layout, navigation, document actions and template columns. M2 does not replace or copy that work. Locate/Remove can be added through the recent store and workflow only after the Home integration point is agreed; Home acceptance remains open until those changes are integrated intentionally.

The bounded `release_trust` subagent owns release scripts/tests, release workflow, distribution docs and M2-RELEASE-TRUST.md. It may commit those files only. The primary owns XML preflight/tests, all native work, backlog/status/handoff and this evidence note. No concurrent writers share source files.

## Large-task decomposition (before implementation)

Each child preserves its parent acceptance; passing one child does not close its parent.

| Parent | Bounded children | Dependency / evidence |
| --- | --- | --- |
| WP-10-T02 | A: stable cross-page search results including text/data/shape; B: UTF-16-safe selected replacement preserving other runs and fields; C: command search with validation reason; D: native event/focus journey | A/B can be prepared against value models. UI integration waits M1. D requires actual input routing. |
| WP-11-T01 | A: scene-ID semantic object model and reading order; B: AppKit elements with graph relations, labels and frames; C: select/inspect/move/connect actions; D: VoiceOver journey | Wait M1 scene identity contract. Controller tests are insufficient for D. |
| WP-11-T02 | A: focus traversal and visible focus; B: movement/resize protection; C: connection start/target/cancel; D: no-pointer create/text/save/export journey | Wait M1 transactions and WP-10 command integration. |
| WP-11-T03 | A: UTF-16/run editing corpus; B: deterministic missing-font inventory/substitution without metadata rewrite; C: IME/RTL/composition event journey | A/B can be prepared. C needs native input method evidence. |
| WP-11-T04 | A: actionable content checks; B: spelling/proofing reference disposition; C: narrow-window/long-label editor; D: appearance/export equivalence | Native checks are independent of Visio inventory; reference proofing remains unaccepted without M0 evidence. |
| WP-12-T01 | A: ZIP/CFB/native-metadata bound and path audit; B: XML streaming preflight before DOM; C: formula/external-resource nonexecution audit and malformed fixtures; D: converter/process resource policy | A-C independent of M1. D coordinates with accepted M1 long-job policy. |
| WP-13-T03 | A: source-preservation policy by feature dimension; B: edited-object/source binding impact; C: save preflight with cancel/copy/alternate-format; D: original bytes/failure/multiwindow journeys | A follows M0 ledger; B-D wait M1 committed snapshots and WP-13 diagnostics. |

## Acceptance fixtures and truthful evidence layers

| Fixture | Intended claim | Required evidence |
| --- | --- | --- |
| Native branching process | Home → template → shapes/branch/connect/arrange → second page/off-page link → save/reopen → PDF/SVG | Model assertions plus real mouse/keyboard journey and public output inspection. No Visio parity implied. |
| Two documents / duplicate URL / read-only / missing recent | Correct routing, state retention and safe source handling | Native windows, dirty/selection/zoom state, canonical file identity, Locate/Remove, overwrite rejection. |
| Search rich text | Across-page text, shape/data results; replacement preserves unrelated styles, fields and Unicode | Mixed runs, RTL, combining text, emoji, protected nodes, one undo; actual text input cannot trigger canvas shortcuts. |
| Accessible graph | Stable shape/edge IDs, order, names, relations, frames and actions | Semantic AppKit assertions plus VoiceOver create/select/move/connect/inspect/save/export. |
| Material diagnostic | Unsupported/cyclic/stale calculation + import issue on separate pages | Object/cell provenance, cached/evaluated state, issue navigation, no cross-document leakage, save impact agrees. |
| Harmless opaque metadata | Preserve bytes with quiet presentation | No warning solely for harmless opaque parts; no unsupported-behavior claim. |
| Input trust | Malformed ZIP/XML/CFB, resource caps, imported action/hyperlink content | Safe rejection before expensive allocation, no automatic execution or external fetch. |
| Candidate distribution | Stable versus development identity and actual bundle platform matrix | Ad hoc/stale/missing manifest rejected; Developer ID, notarization, signed feed/archive; real installed-update/interruption/recovery evidence. |

Unavailable prerequisites remain open: licensed exact-build Visio reference, intended Developer ID credentials/notarization, signed installed-update fixtures, supported-platform installation matrix, real VoiceOver and IME acceptance. Local unit/controller tests are implementation evidence only. A known intermittent full-suite failure cannot be closed by an isolated green rerun.

## Initial source findings

- `ImportNotes.swift` displays only anonymous import strings; `calculationIssues` is not shown there. Object identities and feature dimensions are absent.
- `CanvasView` has a canvas label but no semantic graph children; key handling supports nudge/tools/text, not a complete focus/connection journey.
- `findShapes` searches active-page text/data only and selects all matches; no command search or replacement.
- XML depth/node validation currently runs after `XMLDocument` construction, so budgets are too late to protect DOM allocation. The independent fix moves the streaming pass ahead of the DOM and enforces the part byte limit.
- ZIP bounds/path/checksum, CFB chain/cycle limits and native metadata decode bounds already exist and should be retained. Tests must target boundary violations and imported-action behavior, not merely repeat parsing success.

## Executed local evidence

- `swift test --scratch-path build/m2-swift -j 2 --filter InputTrustTests` — **7 passed**, 0 failures, 16 October 2026; log `build/m2-input-trust.log`. Covers UTF-8/DTD/entity rejection, pre-DOM byte/depth/node limits, ordered whitespace/Unicode preservation, unsafe package targets, corrupt CFB header, inert imported actions and bounded formulas. This is a focused native trust slice, not complete WP-12-T01 acceptance or converter isolation qualification.
- Recent-history Remove/Locate storage is prepared without changing the separate Home layout. Removing suppresses merged system entries; locating preserves pins and coalesces references. UI integration and actual missing-file/native journey remain open.
- `swift test --scratch-path build/m2-swift -j 2 --filter RecentDrawingTests` — **9 passed**, 0 failures, 16 October 2026; log `build/m2-recents.log`. New cases cover persisted removal of pinned/system entries, explicit reopening, relocated pinned entries, coalescing and non-file rejection. Repeated only after the pin-suppression behavior changed; these results do not close the missing-file UI journey.
- `swift test --scratch-path build/m2-swift -j 2 --filter DocumentDiagnosticTests` — **4 passed**, 0 failures; log `build/m2-diagnostics.log`. Provenance survives Codable, identical prose does not collapse different object/cell failures, legacy notes cannot invent navigation targets, and cache state remains explicit. Producer/pane/save integration remains unaccepted and gated.
