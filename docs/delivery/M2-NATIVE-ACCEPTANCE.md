# M2 native editor delivery and acceptance

Planning baseline: `7c270124993bac09967109f95e603ebb47bd98ff`. Branch: `codex/m2-native-editor`.

M2 is **in progress, unaccepted** with the accepted M1 engineering prerequisite integrated. Accepted local M1 runtime/transaction/calculation/scene contracts are integrated at `d797a67`; broader M0/reference/performance and M2 qualification are still open. Notarization through the user-selected `renoir-notary` profile is authorized and complete; installation, installed updates and publication remain outside the earlier authorization limits.

## Current notarized candidate and qualification

Source commit `0839994456aa82f3533456c75f9f10da1ebcd2bb` passes **745 Release tests,
12 fixture-dependent skips, 0 failures** in40.976s, plus **87 Python tests** in28.171s.
Foundation formatting, nine import boundaries and the154-requirement/171-entry
ledger pass. The retained records use the `build/m2-qualified6-` prefix.

The exact app is Developer ID signed with team `5NF98M544G`, hardened, accepted
by Apple using `renoir-notary`, stapled and accepted by Gatekeeper as
**Notarized Developer ID**. Submission ID:
`889a4950-4527-4ee1-afdb-4fc3a5577151`. The final archive is
`build/releases/development/0.23.3-0839994456aa/MacVisio-0.23.3.zip`, SHA256
`5f081eea719d3693631586d42a9494a1fb135933ea0385346283ccf429a95028`.
Exact archive/feed signatures, pinned-public-key verification, bundle seal,
framework symlinks, executable modes and ZIP CRC pass. Real CryptoKit checks
also accept the exact ZIP/feed and reject altered copies; this is cryptographic
evidence, not an installed-updater journey. No archive or feed was published.

A real native rich-text check on the earlier `fbd851b` executable exposed
Command-Z reaching document history while an inline formatting session was
active. `0839994` implements the standard Undo/Redo responder selectors on the
inline text view, keeping even exhausted input history inside that session.
The regression retains a prior committed document edit, formats a selected
UTF-16 run, routes Undo/Redo from the window's actual first responder, and
asserts unchanged document identity. Two initial harness attempts used
NSApp.sendAction without the test host's application action-routing environment;
their failed-dispatch logs are retained rather than presented as a successful
before/after proof. The native replay below verifies the actual menu shortcuts.

The **exact signed bundle**, without a wrapper or signature change, launched on
arm64/macOS27.0.1 (observed pid78985). Existing Australian Option-E showed acute
marked text; Escape cancelled it without changing Process. Option-E then E
committed U+00E9. A suffix includes Hebrew, emoji and decomposed `e`+U+0301.
Selecting only café and pressing Command-B, Command-Z and Command-Shift-Z
respectively applies, removes and restores that run's bold formatting while the
committed canvas/inspector text stays unchanged. Native save/close/reopen retains
only that bold run and a clean document. Native Check Document Now selects the
deliberate misspelling. Actual SVG export and public VSDX XML independently retain
the exact Unicode string and only café as bold. The app quit normally; its own
new recent entry was removed, and the candidate's original code seal still
verifies. See `build/m2-qualified6-native-replay.json` and the two
`build/m2-native-journey/Qualified6-RichInput` outputs.

The final five component license texts match upstream byte for byte; both MPL
source archives were actually downloaded and match the installed formulas'
hashes. The final candidate is rebound in
`build/m2-rights-review/final-license-verification.json`. See
[M2 content-rights review](M2-CONTENT-RIGHTS-REVIEW.md) for obligations and the
remaining application-owner provenance input. This is now a substantive
third-party review, rather than a license-presence inventory.

Remaining acceptance is specific: observable real VoiceOver operation, Japanese/
Chinese candidate-picker and minimum-width native cases, the broader appearance/
proofing/reference matrix, actual installed updates/interruption/recovery,
minimum-OS27.0 installations, application-owner provenance, and the applicable
licensed exact-build Visio/reference and controlled performance gates. The
current tool's app-targeted input does not provide global VoiceOver cursor/action
evidence. Native dead-key composition is real marked-text evidence but does not
assert CJK candidate-picker qualification. The temporary Japanese source was authorized and added, but the current bridge
could not switch the system Input menu. The user then requested **skip and restore**.
Japanese was removed; Australian-only and Input-menu-off were verified. The globe
key returned to Show Emoji & Symbols. Adding the source had also automatically
added Japanese Dictation; it was removed, restoring English (Australia) only with
Dictation off. The owned Latin-only draft was retained as skipped evidence, its
recent entry removed, and both test apps quit normally. No CJK pass is asserted.
See `build/m2-qualified6-japanese-input.json`; its prior pending state is retained
separately.

## Earlier local candidates and qualification

Final source candidate `fbd851bd9f915229b542fb6092d01e6e3f83424a` passes **744 Release tests, 12 fixture-dependent skips, 0 failures** in39.646s (`build/m2-qualified5-release-native.log`). The unchanged Python tooling passes87 tests (`build/m2-qualified5-python.log`); foundation formatting/import boundaries and the154-requirement/171-command ledger pass (`build/m2-qualified5-format.log`, `build/m2-qualified5-ledger.log`). The exact development bundle/archive and bounded native replay pass as recorded below.


The `ae9d815` actual native replay verifies that both ordinary edit/Undo and proposal Apply/single Undo restore a clean title bar. It then exposed a committed X inspector field retaining25.4mm after the model correctly undid to480pt. `bf8d3e4` refreshes already-committed focused fields, preserves pending/marked input and refreshes on field exit. The new field-editor regression and full744-test run pass; the final exact-byte native replay is retained separately. Earlier candidate outcomes remain in `build/m2-window-badge-native-attempt1.json` and `build/m2-inspector-native-attempt1.json`.

`bf8d3e4`'s synchronous end-edit refresh ran before AppKit's Return commit action in the native replay (`build/m2-inspector-native-attempt2.json`). `fbd851b` defers that refresh and strengthens the regression to send actual Return through NSWindow. The final exact-byte replay passes:1in →25.4mm/Edited, one Undo →169.333mm/clean, then Tab keeps the saved value and clean state. A locked shape disables its X field and cannot move; one Undo restores editable/clean state. Native reopen retains both pages and Export All Pages to PDF produces two independently rendered and visually inspected pages. The original fixture hashes and modes remain unchanged, and the probe exits normally (`build/m2-qualified5-native-replay.json`).

The final local development archive is `build/releases/development/0.23.3-fbd851bd9f91/MacVisio-0.23.3.zip`, SHA256 `dbf1d866f5cc79587588639a52659806f7e4981a6b319216f056f00bf5fd2939`. Its ZIP/feed/pinned-key/bundle/executable/symlink checks pass; exact bundle/public-reader/render checks also pass. Reports: `build/m2-qualified5-package.log`, `build/m2-qualified5-bundle-verification.json`, `build/m2-qualified5-bundle-platform.json`, `build/m2-qualified5-content-inventory.json`. It remains ad hoc signed, arm64/macOS27.0, uninstalled/unpublished and publicationAccepted:false. Rights review, signed installed updates, platform/reference and real AT/IME acceptance remain open.

The integrated implementation through `b321c5e` passed **742 Release tests, 12 fixture-dependent skips, 0 failures** in37.234s (`build/m2-final-release-native.log`), **87 Python tests** (`build/m2-feature-python-2.log`), foundation formatting/import boundaries and the154-requirement/171-command ledger. Earlier failed compile/focus/source-traversal cases remain retained; the corrected full run includes them. The old legacy-overwrite expectation now asserts required refusal, unchanged original and separate-copy/reopen.

`build/m2-final-native-journey.json` records actual native observations against the exact candidate executable, SHA256 `8413ffa67f47751bb931de05b7b7d4ddef01cf21a79dc893aa6dcff91d0b7bfa`: keyboard-only single-page author/connect/text/find/undo/save/PDF/SVG; mixed-input multipage and renamed off-page follow; canonical-alias dirty/selection/zoom retention; locked-file Cancel; missing recent Locate/Remove; exact-source issue navigation; affected-source Cancel/copy; and native redacted support export. Original synthetic source hashes remain unchanged. Public XML/SVG and rendered PDF were independently inspected (`build/m2-final-public-output-inspection.json`, `build/m2-final-export-review.png`). The PDF/SVG exports precede the multipage extension.

A native preview Apply/single Undo check exposed a stale **Edited** title-bar badge even though the saved identity and close-without-save behavior were correct. `df97cc0` added window synchronization and passed all742 Release tests (37.424s), but the actual replay still exposed AppKit's separate document-actions counter (`build/m2-window-badge-native-attempt1.json`). `0dc735a` reconciles that counter when the saved snapshot is restored. The window assertions fail on the original source (`build/m2-window-saved-badge-before.log`); its full run retained one fit-to-page failure after legacy scrollers hid (`build/m2-qualified2-release-native.log`). `ae9d815` settles layout and bounded scroller transitions before final fit; the new forced-legacy regression and full743-test run pass. Exact-byte native replay is recorded below. The `b321c5e` bundle/archive and complete journey are retained as the preceding candidate, not silently relabeled as the new bytes.

The earlier candidate's real development ZIP/feed/pinned-key/bundle checks pass (`build/m2-final-package.log`). It is ad hoc signed, unpublished, uninstalled and **publicationAccepted:false**. Actual bundle floor is arm64/macOS27.0, with14 Mach-O files. Current content/license presence is inventoried and redistribution rights remain unreviewed (`build/m2-final-content-inventory.json`). No signed installed-update journey is implied.

VoiceOver was initially off, enabled through native Settings and Use VoiceOver welcome, and its real process observed. The current input bridge produced no independently observable VO cursor/action result; it was restored off and Settings closed. This is **not a VoiceOver pass**. Native Unicode paste is **not a real IME composition pass**. Those gates, complete native rich-run/narrow/proofing/appearance matrix, intended Developer ID/team/notarization, installed updates/recovery, platform installations, content rights and applicable exact Visio/reference/controlled performance remain open. M2 and M3 integration acceptance remain false.

## Ownership and overlap

This managed worktree owns M2. The original checkout's uncommitted Home changes were inspected read-only on 16 October 2026: adaptive 780×640 preferred / 480×440 minimum layout, navigation, document actions and template columns. M2 does not replace or copy that work. M2 adds bounded Locate/Remove callbacks and row actions to its own Home baseline. The original adaptive layout remains separate; native Home/window acceptance is still open.

Completed bounded workers contributed search/command UI, canvas accessibility and diagnostics/save integration respectively. The primary owns inspector/workflow/import/trust integration, backlog/status/handoff and this evidence note. Source changes are committed through `0839994`; final checks run on a frozen source, and commits stage explicit owned paths.

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

Unaccepted prerequisites remain open: licensed exact-build Visio reference, intended candidate/team signing and notarization, signed installed-update fixtures, supported-platform installation matrix, real VoiceOver and IME acceptance. Local unit/controller tests are implementation evidence only. A known intermittent full-suite failure cannot be closed by an isolated green rerun.

## Historical source findings before implementation

- `ImportNotes.swift` displays only anonymous import strings; `calculationIssues` is not shown there. Object identities and feature dimensions are absent.
- `CanvasView` has a canvas label but no semantic graph children; key handling supports nudge/tools/text, not a complete focus/connection journey.
- `findShapes` searches active-page text/data only and selects all matches; no command search or replacement.
- XML depth/node validation currently runs after `XMLDocument` construction, so budgets are too late to protect DOM allocation. The independent fix moves the streaming pass ahead of the DOM and enforces the part byte limit.
- ZIP bounds/path/checksum, CFB chain/cycle limits and native metadata decode bounds already exist and should be retained. Tests must target boundary violations and imported-action behavior, not merely repeat parsing success.

## Historical independent preparation evidence

These records describe the exact earlier source/artifact noted. The accepted M1 integration and current feature qualification are recorded below; earlier dependency statements are historical.

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

## Historical M0 contract integration

Integrated actual M0 delivery commit `02dea53354784dce057b046ea0e7f3df82cee1b9` after reviewing its handoff, locally passing tooling/full-suite evidence and verifying all14 retained artifact hashes. This imports the five-dimension ledger, public synthetic guards/corpus/runner and scoped instrumentation. M0/G0/reference/absolute-performance acceptance remains false. M2 backlog execution records are preserved alongside M0 dispositions. M1 interfaces remain unintegrated and gated. The earlier development archive is still the exact pre-integration `e16604f` preparation artifact, not this combined source.

M0-integrated validation: `swift test --scratch-path build/m2-swift -j 2` passed **503 tests executed, 12 skipped, 0 failures** (`build/m2-m0-integrated-native.log`); all **76 Python tests passed** (`build/m2-m0-integrated-python.log`); `scripts/build-evidence-ledger.py` validation passed (`build/m2-integrated-ledger.log`). These results validate the combined local preparation, without closing M0/G0 or M1 acceptance.

## Historical additional independent preparation

`NativeSupportReport` adds redacted drawing/issue/timing counts as a value-only preparation slice: **6 focused tests passed** (`build/m2-support-report.log`). Records explicitly say supplied-record coverage; arbitrary diagnostic codes/prose/provenance, drawing text/data/URLs/fonts/IDs and timing labels never enter the report. Native export/snapshot/producer adapters remain gated.

Runtime update-channel hardening also closes a source-audited gap: Info.plist automatic-check defaults alone can be overridden by persisted Sparkle preferences. `AppUpdates` now uses the actual pinned Sparkle delegate API to reject development background/information checks, allow manual checks, disable the automatic-check menu and leave the stable user preference alone; absent/invalid channel markers fail closed. The protocol selector was verified against the pinned local Sparkle2.10.0 headers. **3 focused tests passed** (`build/m2-update-runtime-policy.log`), including actual delegate calls and menu/policy behavior. No updater was started or update installed by these tests. The earlier `e16604f` development archive predates this runtime fix; it remains unaccepted and is superseded by the current source for review.

Final independent-preparation regression after support-summary and runtime-channel additions: **512 tests executed, 12 skipped, 0 failures**, 14.919 seconds (`build/m2-preparation-final-native.log`). No M1 interfaces have been integrated; these are local preparation checks. Earlier 7/27-test focused log paths were superseded after adding new cases by the final8/28-test runs explicitly recorded above; no failed or intermittent result is being discarded or resolved by those additions.

Pinned-feed follow-up (`1c9dcce`): authenticate the exact signed feed prefix with the pinned public key before trusting its XML/URL. Actual1280-byte development appcast verifies with signed-prefix/marker offset1136 (`build/m2-pinned-feed-verification.json`); malformed/tampered/duplicate/length/trailing-content cases fail closed. **80 Python tests passed**, including25 release-policy tests and24 malicious feed variants (`build/m2-final-python.log`). This supersedes the prior76-test combined tooling run without changing native app source or accepting a stable/installed update.

Hostile-container follow-up (`7fe3665`): **6 focused tests passed** (`build/m2-container-trust.log`) for actual ZIP duplicate/symlink/unsafe-name/checksum/budget records and CFB FAT/directory/mini-FAT cycles, with positive controls. The source audit in `M2-INPUT-TRUST-AUDIT.md` records decoded-image and converter hard-deadline/isolation work as open. This test-only addition does not replace the existing 512-test app-source regression or close WP-12-T01.

## Accepted M1 integration

Reviewed actual accepted M1 branch `0ea6b33ad086abf59b8538bce50ec57ded7dcd68`, including all112 retained artifact hashes in its foundation/native/recovery records; two explicitly historical superseded binary digests remain separate (`build/m2-m1-accepted-review.json`). M1 now explicitly passes local engineering acceptance and permits M2 integration. Earlier blocked/locked observations in retained review files are historical.

Merged M1 at `d797a67`, preserving M2 new models/tests, AppUpdates, RecentDrawings and XML preflight. M1's qualified adaptations supersede M0's older source instrumentation at conflicting runtime/render/benchmark sites; both backlog formats retain M0/M1/M2 task records. Combined baseline: **655 tests,15 skips,0 failures** in37.0s (`build/m2-m1-integrated-native.log`). Native M2 implementation is active. Stable distribution, numerical performance, platform/reference and actual accessibility/IME qualification remain open and are not implied by this integration.
