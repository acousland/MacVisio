# M2 native editor delivery and acceptance

Planning baseline: `7c270124993bac09967109f95e603ebb47bd98ff`. Branch: `codex/m2-native-editor`.

M2 is **in progress, awaiting accepted M1, unaccepted**. Preparation and independent trust work do not imply that M1 or M0 has passed. M1 runtime/transaction/calculation/scene APIs will only be integrated from a real handoff with passing local evidence. No distribution is authorized.

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
- `swift test --scratch-path build/m2-swift -j 2` — **485 tests executed, 13 skipped, 0 failures**, 15.759 seconds; log `build/m2-full-native.log`. Skips require absent installer assets or a bundled independent reader. This includes the final bounded search/font slice (11 + 6 tests) and all current M2 preparation changes. One green debug suite does not dispose M1's historical suite-context saved-state intermittency, controlled performance or native/assistive-technology journeys.
- `python3 -m unittest discover -s scripts/tests -v` — **27 passed**, 0 failures; log `build/m2-python.log`. Includes 20 release policy cases and 7 prior script cases. These are policy validator fixtures, not signed-installation acceptance.
- Metadata-only `security find-identity -v -p codesigning` probe — **2 valid identities; Developer ID Application available**. Names/identifiers are omitted from retained report `build/m2-signing-prerequisite.json`. Intended final-candidate signing/team, notarization and installed-update evidence are still unaccepted; credentials are not assumed absent.
- Final focused trust rerun — **8 passed**, including a calibrated loopback observer: an explicit positive-control connection is observed, then SVG script/http-image/file-image import produces no additional connection and omits external content. This does not qualify every external-resource or converter route.
- `NativeTextRoutingTests` — **1 passed**, log `build/m2-text-routing.log`. Synthetic key events travel through an NSWindow responder chain into inline NSTextView; ordinary `v/c/t/l` insert text without selecting canvas tools, and Escape cancels without changing the committed node. This is native responder routing evidence, not physical input, real IME composition, full keyboard-only authoring or VoiceOver acceptance.
- Isolated development app built with `swift build -c release -j 2` and `scripts/build-app.sh`; `scripts/verify-app.py` passed its existing bundle/public-format/reader/render checks. Logs: `build/m2-release-build.log`, `build/m2-bundle.log`, `build/m2-bundle-verification.log`; report `build/bundle-verification.json` explicitly retains `windowsVisioValidated: false` and `fullVisioParity: false`.
- Actual inventory of 14 bundled Mach-O files reports **arm64, macOS 27.0 minimum**, not the Swift source target of macOS 13; report `build/m2-bundle-platform.json`. This is a derived candidate floor, not a tested OS/architecture support matrix.
- Development archive prepared locally with valid pinned-key Sparkle ZIP/feed signatures, ad hoc bundle signature and **`publicationAccepted: false`**. No application installation/update or release publication occurred. Archive: `build/releases/development/0.23.3-e16604f368d2/MacVisio-0.23.3.zip`; SHA256 `13203e6a17d0f9b176d5d892262c8a6346f50e350ca3106b1b4b8a0af5287227`; report beside it and log `build/m2-development-package.log`. The source code commit is `e16604f368d2067cf9c2a6f434a3748de9b92ba8`; later documentation/test-only commits do not republish or repackage these bytes.
- Real stable-build rejection with ad hoc identity and legacy unnotarized override returns exit 1 before building; report `build/m2-stable-ad-hoc-rejection.json`. Default support report `build/m2-redacted-support.json` contains only allowlisted bundle metadata, without document text, preferences, credentials or logs.
- Final Python policy run — **28 passed** (21 release-policy plus 7 existing), log `build/m2-python.log`; this supersedes the earlier 27-test run after pinned-key verification was added.
- Exact development-candidate content inventory: 5 third-party code components, 9 license/provenance artifacts and the generated app icon under Resources; no external font files or installer libraries in that directory. Hashes and declared versions are in `build/m2-content-inventory.json`, explicitly **`inventoried_unreviewed`**, with redistribution rights unaccepted. File presence is not a rights review; final M2 bytes must be inventoried again.

- `swift test --scratch-path build/m2-swift -c release -j 2` — **487 tests executed, 12 skipped, 0 failures**, 14.831 seconds; log `build/m2-release-suite.log`. Includes final loopback/native-text fixtures and the now-available bundled independent reader check. Installer-dependent cases remain skipped. This single release-mode run does not close historical M1 intermittency or whole-workflow acceptance.

## M0 contract integration

Integrated actual M0 delivery commit `02dea53354784dce057b046ea0e7f3df82cee1b9` after reviewing its handoff, locally passing tooling/full-suite evidence and verifying all14 retained artifact hashes. This imports the five-dimension ledger, public synthetic guards/corpus/runner and scoped instrumentation. M0/G0/reference/absolute-performance acceptance remains false. M2 backlog execution records are preserved alongside M0 dispositions. M1 interfaces remain unintegrated and gated. The earlier development archive is still the exact pre-integration `e16604f` preparation artifact, not this combined source.

M0-integrated validation: `swift test --scratch-path build/m2-swift -j 2` passed **503 tests executed, 12 skipped, 0 failures** (`build/m2-m0-integrated-native.log`); all **76 Python tests passed** (`build/m2-m0-integrated-python.log`); `scripts/build-evidence-ledger.py` validation passed (`build/m2-integrated-ledger.log`). These results validate the combined local preparation, without closing M0/G0 or M1 acceptance.

## Additional independent preparation

`NativeSupportReport` adds redacted drawing/issue/timing counts as a value-only preparation slice: **6 focused tests passed** (`build/m2-support-report.log`). Records explicitly say supplied-record coverage; arbitrary diagnostic codes/prose/provenance, drawing text/data/URLs/fonts/IDs and timing labels never enter the report. Native export/snapshot/producer adapters remain gated.

Runtime update-channel hardening also closes a source-audited gap: Info.plist automatic-check defaults alone can be overridden by persisted Sparkle preferences. `AppUpdates` now uses the actual pinned Sparkle delegate API to reject development background/information checks, allow manual checks, disable the automatic-check menu and leave the stable user preference alone; absent/invalid channel markers fail closed. The protocol selector was verified against the pinned local Sparkle2.10.0 headers. **3 focused tests passed** (`build/m2-update-runtime-policy.log`), including actual delegate calls and menu/policy behavior. No updater was started or update installed by these tests. The earlier `e16604f` development archive predates this runtime fix; it remains unaccepted and is superseded by the current source for review.

Final independent-preparation regression after support-summary and runtime-channel additions: **512 tests executed, 12 skipped, 0 failures**, 14.919 seconds (`build/m2-preparation-final-native.log`). No M1 interfaces have been integrated; these are local preparation checks. Earlier 7/27-test focused log paths were superseded after adding new cases by the final8/28-test runs explicitly recorded above; no failed or intermittent result is being discarded or resolved by those additions.

Pinned-feed follow-up (`1c9dcce`): authenticate the exact signed feed prefix with the pinned public key before trusting its XML/URL. Actual1280-byte development appcast verifies with signed-prefix/marker offset1136 (`build/m2-pinned-feed-verification.json`); malformed/tampered/duplicate/length/trailing-content cases fail closed. **80 Python tests passed**, including25 release-policy tests and24 malicious feed variants (`build/m2-final-python.log`). This supersedes the prior76-test combined tooling run without changing native app source or accepting a stable/installed update.

Hostile-container follow-up (`7fe3665`): **6 focused tests passed** (`build/m2-container-trust.log`) for actual ZIP duplicate/symlink/unsafe-name/checksum/budget records and CFB FAT/directory/mini-FAT cycles, with positive controls. The source audit in `M2-INPUT-TRUST-AUDIT.md` records decoded-image and converter hard-deadline/isolation work as open. This test-only addition does not replace the existing 512-test app-source regression or close WP-12-T01.

## Current upstream prerequisite

The user reported the Mac unlocked, and M1 confirmed the unlocked desktop. M1 has resumed native event qualification and is fixing its benchmark launch/key-window path before retrying the trace. The previous locked-session request is retained in `build/m2-upstream-gate.json`; the resumed state is recorded in `build/m2-upstream-resume.json`. No accepted M1 handoff exists. Independent M2 preparation is complete, and all remaining native integration and whole-task acceptance stay gated. M2 is **in_progress**, with zero completed parent tasks and no downstream integration permission. Review the actual M1 handoff and passing local milestone evidence before integration; an unlocked session alone does not satisfy acceptance.
