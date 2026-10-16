# M2 release trust evidence

## Final local notarization follow-up

The root integration candidate `0839994456aa82f3533456c75f9f10da1ebcd2bb`
is now Developer ID signed (team5NF98M544G), hardened, Apple Accepted through
user-selected `renoir-notary`, stapled and accepted by Gatekeeper. Its exact
final ZIP/feed verification and four actual public-key positive/tamper cases
pass. The signed app's native rich-input/save/reopen/export replay also passes.
See [current M2 acceptance](M2-NATIVE-ACCEPTANCE.md) and
[component-rights review](M2-CONTENT-RIGHTS-REVIEW.md).

The preparation evidence below remains historical. Its intended-signing/profile
input is resolved by the final notarization receipt; installed update/recovery,
minimum-OS installations, global VoiceOver and remaining rights/reference gates
are still unaccepted. No candidate was installed, updated or published.


This is a bounded WP-12 tooling slice, not package acceptance. AR-09 requires a
candidate-specific stable release manifest and an independent development path.
No signed installation, VoiceOver, content-rights, or platform journey is accepted
by this work. No release is published and no installed application is updated.

## WP-12-T01 decomposition recorded before implementation

| Child | Bounded work | Evidence and acceptance boundary |
| --- | --- | --- |
| T01a — ZIP and XML audit | Read archive/parser entry points and existing malformed fixtures; record limits and unresolved cases. | Source audit only; no parser modifications or assertion that hostile-input qualification passed. |
| T01b — CFB and legacy process audit | Read compound-file bounds and converter invocation/output/time limits. | Source audit only; native process isolation and adversarial fixtures remain separate work. |
| T01c — Formula and external action audit | Trace evaluator limits, external relationships, hyperlinks and imported actions. | Source audit only; no automatic action/fetch acceptance without runtime evidence. |
| T01d — Release evidence boundary | Bound manifest/feed/archive ingestion, reject unsafe paths and require local hash-linked evidence. | Implement and test Python policy; does not establish runtime input security. |

Only T01d and the release-tooling portions of T02/T04 are implemented here. T03
requires actual signed installed-update and recovery runs on declared platforms.

## Read-only input audit

| Surface | Observed source contract | Remaining acceptance |
| --- | --- | --- |
| ZIP/OPC | `VisioPackage.swift`: 100 MiB archive, 10,000 entries, 16 MiB part, 128 MiB total; bounded chunk extraction, CRC checking, duplicate/symlink/path rejection; in-memory import. | Existing `VisioFormatTests` have DTD, traversal, malformed/nonfinite geometry and highly compressed oversize cases. This slice did not execute them or establish a hostile corpus/platform acceptance. |
| XML | `VisioXML.swift` rejects DTD/entity declarations, requires UTF-8, disables external entities and has depth/node budgets. Initial audit found the budget check occurred after DOM allocation; the parent M2 change moves streaming preflight before DOM construction and owns its regression fixtures. | Treat pre-DOM hardening as the parent's separately validated change; no XML acceptance is invented here. |
| CFB/legacy | `CompoundFile.swift`: 128 MiB input/aggregate bound, checked sector indexes, FAT/DIFAT/stream cycle detection, directory depth below 128 and 16,384 visited entries. `LegacyVisioFormat.swift` checks 100 MiB input and signature, invokes a fixed helper with a path argument and null stdin/stderr, limits stdout to 64 MiB and pages to 1,000, requests termination after 30 seconds. | Termination is not an OS sandbox or guaranteed hard kill. Adversarial helper CPU/memory/termination and resource-exhaustion runs remain unaccepted. |
| Formula | `ShapeSheet.swift` bounds source characters, parse nesting below 64, evaluation below 10,000 operations/depth 64 and rejects unsupported functions; geometry/recalculation paths have additional budgets. | Fuzzing, cross-engine resource exhaustion and prohibited imported-action fixture journeys remain unaccepted. |
| External actions/resources | `VisioFormat.swift` records external relationships and normalizes internal paths inside the package; reusable/stencil readers exclude external relationships. `SVGImport.swift` accepts embedded data images with a part-size bound. `EditorFeatures.swift` follows only explicit user-invoked http/https/mailto hyperlinks. | Source inspection is not proof of all routes: runtime no-fetch/no-execution fixtures, embedded-object handling and converter resource behavior remain required. |

No imported-content execution or network behavior was enabled by this slice.

## Implemented tooling boundary

- Stable/development markers and feed routing are set before code signing. The
  development feed names the exact development prerelease; scheduled checks are
  disabled. Publication uses prerelease/`--latest=false`, keeping stable latest
  separate. Tag/version consistency and immutable published assets are retained.
- Stable candidates require observed Developer ID, intended team, hardened
  runtime, stapled notarization/Gatekeeper and valid Sparkle ZIP/feed signatures.
  Separate CryptoKit verification checks both archive and feed against the pinned
  public key, so a wrong private signing key cannot verify its own signatures.
  The old environment override is removed. Candidate-only preparation can never
  accept publication.
- Stable acceptance binds ZIP/feed SHA256, version/build, bundle ID, source
  commit and complete derived bundle platform inventory to retained hashed local
  run artifacts. Missing installed-update, accessibility, security, performance,
  compatibility, rights or platform acceptance fails. A manifest cannot replace
  actual cryptographic observations. The evidence reviewer is still responsible
  for the truth and adequacy of retained runs; the script is not build provenance
  attestation or an automated replacement for those journeys.
- Mach-O inventory covers all regular bundled binaries using `lipo` and `otool`,
  intersects architectures and raises the floor across every dependency and the
  plist. This run did not produce or qualify a new app bundle.
- Release ZIP and JSON/XML evidence ingestion has bounded sizes and rejects
  traversal, duplicate/encrypted/special entries, escaping/upward symlinks and
  writes through symlink aliases. Local support reports allowlist bundle metadata
  and never read drawings, preferences, credentials, environment or logs.

## Validation and remaining prerequisites

On 2026-10-16, `python3 -m unittest discover -s scripts/tests -v` passed 28 tests:
21 new release-policy tests plus seven existing interchange-tool tests. Tests
cover observed-signature rejection even with the old override, missing/changed
candidate evidence, interrupted acceptance records, exact platform floors,
unsafe ZIPs, channel separation, stale reports and default support redaction.
Temporary synthetic acceptance records and mocked crypto commands are clearly
test data; they are not product acceptance evidence. Shell syntax and diff
whitespace and workflow YAML syntax checks pass. The standalone CryptoKit script
passes the public RFC 8032 empty-message signature vector and rejects changed
bytes. No full Swift package build/test or signed install was run by this
release-tooling subtask.

A read-only audit of the cached pinned Sparkle 2.10.0 artifact (SHA256
`17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959`)
found nine framework symlinks, all downward relative (`Versions/Current/...` and
`Current -> B`). The release ZIP policy accepted all actual framework entries
wrapped under `MacVisio.app/Contents/Frameworks`. Upward links remain deliberately
unsupported; the dead upward-resolution branch was removed.

Stable publication remains unaccepted. Required external prerequisites include
exact intended Developer ID team/notarization evidence (available identities are
not candidate acceptance), protected stable environment and retained
candidate-producing qualification run; real signed update install/invalid
signature/interruption/recovery with usable settings/documents; actual platform,
VoiceOver/keyboard, controlled performance, security and compatibility journeys;
and bundled-content inventory/redistribution-rights review. None were performed
or represented as accepted. No publish, push or installed update was attempted.

## Follow-up: independent pinned-key feed verification

This follow-up owns only `scripts/verify-update-signature.swift`,
`scripts/verify-release.py`, `scripts/tests/test_release_policy.py` and this file.
It adds release-tooling validation and does not accept an installed-update
journey or any milestone gate.

Before implementing the parser, the actual local pinned Sparkle 2.10 output at
`build/releases/development/0.23.3-e16604f368d2/appcast.xml` was inspected as bytes.
The file is 1,280 bytes, SHA256
`76c5aec9ea16789179bbe1941b0c17ac4e4f93b6362a407c137c8e64292f6c45`.
The signature footer starts at byte 1,136 immediately after `</rss>`; its declared
`length: 1136` equals that exact position. A standalone CryptoKit probe verified
the signature over those first 1,136 bytes with the repository's pinned public
key. No XML reserialization or whitespace normalization was used.

The helper's existing archive invocation remains supported. Its new
`--feed appcast.xml public-key` mode reads at most 1 MiB plus a one-byte overflow
probe, requires UTF-8 without NUL bytes and exactly one signature marker, then
accepts only the observed canonical footer format. The footer must be at most
256 bytes, contain one canonical 64-byte Ed25519/base64 signature, one canonical
positive decimal length equal to the footer's actual byte offset, and end with
the pinned output's single LF after `-->`. Duplicate markers/fields, changed
lengths, alternate formatting and all extra trailing content fail. CryptoKit
verifies the exact signed prefix against the pinned public key independently of
`sign_update` and its private key/account checks.

The release verifier performs this check before parsing feed XML or trusting its
enclosure URL. It still requires the existing Sparkle archive/feed checks and
independent pinned archive verification, and records
`feedPublicKeySignatureVerified: true` only after success. A stale accepted
report is still removed when any check fails.

Tests retain the exact public development-feed bytes inline so CI needs no
private key, network or local candidate directory. Real CryptoKit checks cover
the positive feed, wrong public key, changed signed XML/signature, duplicate
markers/fields, wrong/overflow/noncanonical lengths, unsigned XML before or after
the footer (including an attacker-adjusted length), trailing comments/whitespace,
missing footer/newline, CRLF/alternate marker, invalid base64/UTF-8/NUL and an
oversized file. A verifier test proves pinned-feed failure stops before XML and
private signer execution. The existing RFC 8032 archive test remains intact.

Follow-up validation on 2026-10-16: `python3 -m unittest discover -s scripts/tests -v`
passed all 80 Python tests, including 25 release-policy tests. The four new
feed-focused tests cover the actual positive signature, 24 malicious variants,
wrong key, bounded reading and early verifier failure. A direct invocation of
the new helper on the actual local candidate feed also exited successfully.
`git diff --check` passed.

Only standalone Swift helper invocations and Python tests are exercised; there
is no full Swift build, key export, signing operation, network access, publication
or installed update in this follow-up. Actual signature authenticity for this
development feed does not establish stable or installed-update acceptance.
