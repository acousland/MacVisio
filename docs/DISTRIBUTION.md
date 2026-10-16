# Releases and updates

Source and downloads are hosted at https://github.com/acousland/MacVisio. Version 0.18.0 integrates the pinned Sparkle 2.10.0 framework. The initial release targets Apple Silicon and macOS 27, reflecting the deployment floor of its bundled legacy reader.

The MacVisio menu includes **Check for Updates…** and **Automatically Check for Updates**. Scheduled checks are enabled by default. Sparkle presents available releases and asks before installation. Command-line conversion/rendering and the isolated launch diagnostic do not initiate update checks.

The stable feed URL is `https://github.com/acousland/MacVisio/releases/latest/download/appcast.xml`. Both the appcast and the ZIP use the app's Ed25519 update key; signed feeds and signature verification before extraction are required by the bundle. The public key is committed in Info.plist. The documented signing routes use the local Keychain MacVisio account or the encrypted GitHub Actions secret `SPARKLE_PRIVATE_KEY`. Private signing material is excluded from source and release assets. Development builds use the separate channel described below.

## Version 0.23.3

Version 0.23.3 reduces large-VSDX metadata encoding and decoding work. Existing large drawings adopt the compact representation on their next save; opening does not rewrite them. The background open/save behavior from 0.23.2 remains in place. See [release notes](RELEASE-0.23.3.md).

## Version 0.23.1

Version 0.23.1 fixes complex VSDX save failures by compressing and bounding native editing metadata. Actual NSDocument save/reopen tests cover large imported payloads, repeated saves, preserved opaque parts, and safe failure handling. See [release notes](RELEASE-0.23.1.md).

## Version 0.23.0

Version 0.23.0 adds Home/New/Open screens, recent and pinned drawings, separate drawing windows, and document switching. See [release notes](RELEASE-0.23.0.md) and [document workflow](DOCUMENT-WORKFLOW.md).

## Version 0.22.2

Version 0.22.2 prevents untouched inspector fields from triggering document-wide recalculation after opening, preserves exact values behind rounded fields, and uses normal NSDocument file metadata. The source suite passes 391 Swift tests and the bundled readers/renderers pass verification. A live event-loop diagnostic confirms unchanged document state and post-open responsiveness on the local drawing. See [release notes](RELEASE-0.22.2.md) and [opening performance](OPEN-PERFORMANCE.md).

## Version 0.22.1

Version 0.22.1 fixes group labels being painted over by member backgrounds, honors cached text visibility, and reduces repeated style inheritance work during import. Compatibility notes are available in the status bar. The app is Developer ID signed, notarized, and stapled; Gatekeeper assessment passes. The source suite passes 387 Swift tests. See [release notes](RELEASE-0.22.1.md) and [opening performance](OPEN-PERFORMANCE.md). The distribution requires Apple Silicon and macOS 27 or newer.

## Version 0.22.0

Version 0.22.0 is published with a Developer ID signature, accepted Apple notarization, and a stapled ticket. The final archive passes Gatekeeper and Sparkle archive/feed signature verification. This release requires Apple Silicon and macOS 27 or newer; the signed appcast records that deployment floor. It includes the dark/light/system appearance choices, tabbed ribbon, and bounded line-theme/VSD connector compatibility work. The release assets include `release-verification.json` and `SHA256SUMS.txt`; the source suite passes 378 Swift tests and 7 script tests. See [release notes](RELEASE-0.22.0.md).

## Qualified M2 development prerelease

Source `0839994` has a Developer ID signed, hardened, Apple-notarized and
stapled development candidate. Gatekeeper, ZIP/feed signatures, public-key tamper
checks and native rich-input/save/reopen/export pass. Actual official Sparkle
installed-update/rejection/interrupted-download/retry checks pass on isolated
owned copies; prior and updated apps open the preserved drawing and recorded
settings remain intact. Signed loopback feeds were used for this local test.

The agreed M2 engineering checkpoint is complete on arm64/macOS27.0.1. The
binary inventory derives a27.0 floor; installation on27.0 and broader platforms
is not claimed. Japanese and VoiceOver testing are excluded by user instruction.
The exact candidate is published as the [M2 preview](https://github.com/acousland/MacVisio/releases/tag/development-v0.23.3-0839994456aa); its archive and all other public asset hashes match the qualified files. Stable `publicationAccepted` is false. Stable release,
controlled performance and Visio compatibility gates retain their separate
qualification requirements. See [final M2 qualification](delivery/M2-QUALIFICATION.md).

## Current channel and publication contract

The build defaults to `development`. Before signing, `build-app.sh` records
`MacVisioReleaseChannel`, sets a feed URL for the exact
`development-v<version>-<source revision>` prerelease and disables scheduled
update checks. Development archives live under
`build/releases/development/<version>-<revision>/`. The release workflow publishes
these with `--prerelease --latest=false`; they cannot replace the stable latest
feed. Manual development update checks use that same prerelease's feed. The runtime updater delegate rejects development background and information probes even if Sparkle has a persisted automatic-check preference from a stable build. The development automatic-check menu is disabled; the stable preference is not rewritten. Unconfigured builds reject all checks. This is
an isolated development channel. The local installed-update journey above qualifies the updater engine using controlled feeds; public endpoint delivery is not claimed.

Stable builds require `MACVISIO_RELEASE_CHANNEL=stable` and an explicit
`MACVISIO_SIGNING_IDENTITY='Developer ID Application: …'`. Only stable bundles
use `https://github.com/acousland/MacVisio/releases/latest/download/appcast.xml`.
A stable marker alone does not authorize publication. Verification observes the
actual ZIP/feed Sparkle signatures, extracted bundle signature, Developer ID
team, hardened runtime, stapled ticket and Gatekeeper notarization assessment.
The archive also passes independent CryptoKit verification with the pinned public
key, preventing a mismatched private signing key from validating itself.
There is no ad hoc stable route and `MACVISIO_ALLOW_UNNOTARIZED` has no effect.

The version notes above describe historical releases. They do not accept a new
candidate. The historical unnotarized exception and ad hoc public workflow have
been removed from the current tooling.

## Preparing and accepting a stable candidate

1. Choose the source commit and update both version fields in `scripts/Info.plist`.
   Complete source/bundle verification and build the stable bundle with the
   intended Developer ID identity. Signing credentials remain outside source.
2. Submit that bundle for Apple notarization, wait for acceptance and staple it.
   Run `scripts/package-release.sh --channel stable --candidate-only`. This
   produces the final ZIP, signed appcast, checksums and an **unaccepted**
   `release-verification.json` under `build/releases/stable-candidates/<version>/`.
   Existing candidate directories are never overwritten.
3. Retain these exact ZIP/feed bytes for qualification. Exercise the actual
   signed update install, invalid signatures, interruption, rollback/recovery,
   documents/settings preservation and all other acceptance gates. Repackaging
   changes the candidate hash and invalidates its acceptance.
4. Create `stable-manifest.json` with the contract below and retained local
   evidence. Re-run:

   ```sh
   python3 scripts/verify-release.py build/releases/stable-candidates/<version> \
     --channel stable --manifest /absolute/path/to/stable-manifest.json
   ```

   A successful final report records `publicationAccepted: true`. Failed
   verification removes a stale report. `--candidate-only` always records false.
5. Stable publication is a separate manual workflow dispatch, using the
   `stable-release` environment and an existing Actions run containing an
   artifact named `stable-candidate`. Its root must contain the exact ZIP,
   appcast, `stable-manifest.json` and evidence paths. The workflow checks out the
   selected source ref, repeats verification, requires the manifest's full source
   commit to match, then publishes explicit assets on `v<version>`. Existing
   releases are never replaced. Configure environment protections and retain
   qualification artifacts before enabling that operation.

This change does not supply signing credentials, an approved candidate-producing
qualification workflow or accepted journeys. No candidate is currently accepted
by this tooling change. Local packaging/verifier commands do not publish.

## Stable manifest and evidence

The manifest is JSON, at most 1 MiB. Required top-level fields are:

| Field | Contract |
| --- | --- |
| `schemaVersion` | Integer `1`. |
| `channel` | `stable`. |
| `candidate` | Exact `candidate` object from the candidate verification report, including ZIP/feed SHA256, byte length, version/build, bundle ID, feed URL and full derived platform inventory. |
| `sourceCommit` | Full 40-character source commit matching the verifying checkout. |
| `teamID` | Intended 10-character Developer ID team, matched to actual code-signature output. |
| `acceptance` | Exactly one hash-linked local evidence record for each gate below. Each reference has `path` and `sha256`. |

Each evidence record requires `gate`, `status: accepted`, `candidateSHA256`,
`reviewer`, `recordedAt`, `platforms`, `checks` and a nonempty `artifacts` list of
local `{path, sha256}` references. Records and artifacts must stay inside the
manifest directory, including after resolving symlinks. Paths/URLs outside it,
missing files, changed hashes, skipped/failed checks and evidence for a different
candidate fail. Every record's `platforms` must list the derived architectures
and their exact minimum macOS versions, in inventory order. The evidence must
come from actual runs and rights review; the verifier checks its binding and
completeness, not the truth of a human's assertion. Synthetic Python fixtures
exist only in temporary test directories.

Every named check must have the value `passed`:

| Gate | Required checks |
| --- | --- |
| `platform` | `launch`, `open-edit-save-reopen` |
| `installedUpdate` | `signed-install`, `invalid-signature`, `interruption`, `rollback-recovery`, `documents-settings-preserved` |
| `security` | `zip-xml-cfb-limits`, `formula-resource-limits`, `no-automatic-actions-or-fetch` |
| `accessibility` | `keyboard` |
| `performance` | `controlled-latency`, `intermittency-disposition` |
| `compatibility` | `declared-slice`, `no-silent-loss` |
| `contentRights` | `bundled-content-inventory`, `redistribution-rights` |

VoiceOver operation testing was explicitly removed from the release requirements by the user on16 October2026. Semantic accessibility and native keyboard evidence are retained; no VoiceOver pass is claimed. Japanese testing was also explicitly excluded.

The workflow retains the supplied evidence in the candidate run; it publishes the
manifest and verification hashes, not raw support logs or drawing contents.
Protect that run and review its evidence before dispatch. This policy does not
cryptographically attest that an untrusted builder compiled the declared source.

## Platform and content contracts

`python3 scripts/release_policy.py platform build/MacVisio.app` inventories every
regular Mach-O in the bundle, including helpers, framework tools, XPC services
and dylibs. It reads each architecture and macOS load-command minimum using
`lipo`/`otool`, intersects supported architectures across all binaries, and takes
the maximum deployment floor including `LSMinimumSystemVersion`. Unsupported
platforms, unknown architectures and empty intersections fail. The appcast may
not advertise a lower floor. A candidate's declared support requires actual
journeys on each resulting architecture/minimum-OS combination; source package
settings alone are insufficient. Intel and older macOS remain unaccepted until
the bundle inventory and matching runs establish them.

Bundling Sparkle's license text does not establish rights for every bundled
library, stencil, template, icon or imported content. A candidate-specific
inventory and redistribution-rights review remain required and unaccepted here.

## Local support report

```sh
python3 scripts/release_policy.py support build/MacVisio.app \
  --output /absolute/path/to/macvisio-support.json
```

This creates a local allowlisted report containing only bundle ID, version,
build, plist deployment floor and channel. It does not read preferences,
documents, logs, paths, drawing text, account names or environment variables. It
performs no network request and sends nothing. The plist floor in this minimal
report is labelled metadata; use the separate platform inventory for the actual
whole-bundle floor. Review any extra files before sharing them manually.

## Validation boundaries

The release-policy tests exercise malformed archives, evidence traversal and
changed hashes, missing/unaccepted journeys, platform derivation, default support
redaction, stale reports and rejection of ad hoc/unnotarized stable candidates
even when the old override environment variable is set. Mocked cryptographic
commands in those tests are policy fixtures, not real signature evidence.

Real signed installation, invalid-signature rejection by the installed updater,
interruption/recovery, VoiceOver, controlled platform/performance journeys and
content-rights review remain unaccepted. The historical live-feed probe did not
install an update. See [M2 release trust evidence](delivery/M2-RELEASE-TRUST.md)
for the input audit and bounded implementation results.
