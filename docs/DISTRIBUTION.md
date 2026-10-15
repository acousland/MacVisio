# Releases and updates

Source and downloads are hosted at https://github.com/acousland/MacVisio. Version 0.18.0 integrates the pinned Sparkle 2.10.0 framework. The initial release targets Apple Silicon and macOS 27, reflecting the deployment floor of its bundled legacy reader.

The MacVisio menu includes **Check for Updates…** and **Automatically Check for Updates**. Scheduled checks are enabled by default. Sparkle presents available releases and asks before installation. Command-line conversion/rendering and the isolated launch diagnostic do not initiate update checks.

The feed URL is `https://github.com/acousland/MacVisio/releases/latest/download/appcast.xml`. Both the appcast and the ZIP use the app's Ed25519 update key; signed feeds and signature verification before extraction are required by the bundle. The public key is committed in Info.plist. The private key is stored in the local Keychain under the MacVisio account and in the encrypted GitHub Actions secret `SPARKLE_PRIVATE_KEY`. It is excluded from source and release assets.

## Version 0.22.2

Version 0.22.2 prevents untouched inspector fields from triggering document-wide recalculation after opening, preserves exact values behind rounded fields, and uses normal NSDocument file metadata. The source suite passes 391 Swift tests and the bundled readers/renderers pass verification. A live event-loop diagnostic confirms unchanged document state and post-open responsiveness on the local drawing. See [release notes](RELEASE-0.22.2.md) and [opening performance](OPEN-PERFORMANCE.md).

## Version 0.22.1

Version 0.22.1 fixes group labels being painted over by member backgrounds, honors cached text visibility, and reduces repeated style inheritance work during import. Compatibility notes are available in the status bar. The app is Developer ID signed, notarized, and stapled; Gatekeeper assessment passes. The source suite passes 387 Swift tests. See [release notes](RELEASE-0.22.1.md) and [opening performance](OPEN-PERFORMANCE.md). The distribution requires Apple Silicon and macOS 27 or newer.

## Version 0.22.0

Version 0.22.0 is published with a Developer ID signature, accepted Apple notarization, and a stapled ticket. The final archive passes Gatekeeper and Sparkle archive/feed signature verification. This release requires Apple Silicon and macOS 27 or newer; the signed appcast records that deployment floor. It includes the dark/light/system appearance choices, tabbed ribbon, and bounded line-theme/VSD connector compatibility work. The release assets include `release-verification.json` and `SHA256SUMS.txt`; the source suite passes 378 Swift tests and 7 script tests. See [release notes](RELEASE-0.22.0.md).

## Publishing another release

1. Increase both version fields in `scripts/Info.plist`.
2. Run `swift test`, build the bundle and run `python3 scripts/verify-app.py`.
3. For a Developer ID release, set `MACVISIO_SIGNING_IDENTITY` while building; submit a ZIP with `xcrun notarytool`, wait for acceptance, then staple the app. Notarization credentials stay in your local Keychain.
4. Run `scripts/package-release.sh`. This creates the final ZIP, signed appcast, checksum and signature verification report under `build/releases/<version>`.
5. Publish those files together on the matching GitHub `v<version>` release. The latest release must always include `appcast.xml`.

Notarization remains required by default when verifying a Developer ID release. An explicitly authorized release without notarization uses `MACVISIO_ALLOW_UNNOTARIZED=1` during packaging. The verification report records `notarized: false` and the override; archive, feed and bundle signature checks remain required. Version 0.19.0 initially used this exception, then its assets were replaced with a notarized and stapled build once the Keychain profile was restored. The current 0.18.0 and 0.19.0 downloads are both notarized and stapled.

The tag/dispatch release workflow tests and builds the source, signs the update ZIP and feed using the GitHub secret, and publishes the assets. It skips an already published release. The workflow's bundle currently uses an ad hoc code signature; Apple Developer ID certificate export and CI notarization credentials have not been configured. For future notarized releases, use the local signing/notarization route above. A valid Ed25519 update signature is independent of Apple's code signature.

The build workflow uploads a ZIP rather than a raw app bundle so executable permissions and framework symlinks survive artifact downloads. Push builds also verify the update/feed signing pipeline using the repository secret; pull requests run without that secret. Test artifacts are not public Sparkle releases.

## Validation boundaries

The 0.19 source test suite passes 284 tests. Bundle verification exercises actual VSDX and experimental binary VSD conversion/export, the bundled independent parser, native rendering and relocatable dependencies. The isolated native launch check confirms a visible active editor and Save routing. Release packaging verifies archive CRCs, update signatures, the signed feed, extracted bundle signatures, executable mode and framework symlinks. Version 0.19 is Developer ID signed, notarized and stapled; its extracted ZIP passes Gatekeeper assessment as a notarized release. See [bundle verification](bundle-verification.json), [release verification](release-verification.json), [opening performance](OPEN-PERFORMANCE.md) and [compatibility](COMPATIBILITY.md).

To probe the live signed feed using Sparkle without installing an update:

```sh
swiftc -F build/MacVisio.app/Contents/Frameworks -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/MacVisio.app/Contents/Frameworks \
  scripts/check-update.swift -o build/check-update
build/check-update build/MacVisio.app
```

Public release ZIPs are downloaded without GitHub authentication for archive and code-signing checks. The notarized packages also pass stapled-ticket and Gatekeeper checks. A probe using the bundled Sparkle framework verified the live signed feed and detected build 19 as an available update for build 18. An actual installation of a later version through Sparkle has not yet been exercised. Full Visio parity, Microsoft Visio acceptance, Intel and older macOS distributions remain unverified.
