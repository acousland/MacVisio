# Releases and updates

Source and downloads are hosted at https://github.com/acousland/MacVisio. Version 0.18.0 integrates the pinned Sparkle 2.10.0 framework. The initial release targets Apple Silicon and macOS 27, reflecting the deployment floor of its bundled legacy reader.

The MacVisio menu includes **Check for Updates…** and **Automatically Check for Updates**. Scheduled checks are enabled by default. Sparkle presents available releases and asks before installation. Command-line conversion/rendering and the isolated launch diagnostic do not initiate update checks.

The feed URL is `https://github.com/acousland/MacVisio/releases/latest/download/appcast.xml`. Both the appcast and the ZIP use the app's Ed25519 update key; signed feeds and signature verification before extraction are required by the bundle. The public key is committed in Info.plist. The private key is stored in the local Keychain under the MacVisio account and in the encrypted GitHub Actions secret `SPARKLE_PRIVATE_KEY`. It is excluded from source and release assets.

## Publishing another release

1. Increase both version fields in `scripts/Info.plist`.
2. Run `swift test`, build the bundle and run `python3 scripts/verify-app.py`.
3. For a Developer ID release, set `MACVISIO_SIGNING_IDENTITY` while building; submit a ZIP with `xcrun notarytool`, wait for acceptance, then staple the app. Notarization credentials stay in your local Keychain.
4. Run `scripts/package-release.sh`. This creates the final ZIP, signed appcast, checksum and signature verification report under `build/releases/<version>`.
5. Publish those files together on the matching GitHub `v<version>` release. The latest release must always include `appcast.xml`.

The tag/dispatch release workflow tests and builds the source, signs the update ZIP and feed using the GitHub secret, and publishes the assets. It skips an already published release. The workflow's bundle currently uses an ad hoc code signature; Apple Developer ID certificate export and CI notarization credentials have not been configured. For future notarized releases, use the local signing/notarization route above. A valid Ed25519 update signature is independent of Apple's code signature.

The build workflow uploads a ZIP rather than a raw app bundle so executable permissions and framework symlinks survive artifact downloads. Push builds also verify the update/feed signing pipeline using the repository secret; pull requests run without that secret. Test artifacts are not public Sparkle releases.

## Validation boundaries

The 0.18 source test suite passes 283 tests. Bundle verification exercises actual VSDX and experimental binary VSD conversion/export, the bundled independent parser, native rendering and relocatable dependencies. The isolated native launch check confirms a visible active editor and Save routing. Release packaging verifies archive CRCs, update signatures, the signed feed, extracted bundle signatures, executable mode and framework symlinks. The initial distribution is Developer ID signed, notarized and stapled; the extracted ZIP passes Gatekeeper assessment. See [bundle verification](bundle-verification.json), [release verification](release-verification.json) and [compatibility](COMPATIBILITY.md).

To probe the live signed feed using Sparkle without installing an update:

```sh
swiftc -F build/MacVisio.app/Contents/Frameworks -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/MacVisio.app/Contents/Frameworks \
  scripts/check-update.swift -o build/check-update
build/check-update build/MacVisio.app
```

The public ZIP was downloaded without GitHub authentication and passed the same archive, code-signing and notarization checks. A probe using the bundled Sparkle framework successfully verified the live signed feed and identified build 18 as current. The same probe detected build 18 as an available update for an isolated copy marked build 17. An actual installation of a later version through Sparkle has not yet been exercised. There is only one published updater-enabled version. Full Visio parity, Microsoft Visio acceptance, Intel and older macOS distributions remain unverified.
