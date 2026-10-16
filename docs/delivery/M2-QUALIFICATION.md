# M2 engineering qualification — 16 October 2026

**M2 is complete for the agreed native-editor engineering scope.** All sixteen
local task contributions are qualified against source
`0839994456aa82f3533456c75f9f10da1ebcd2bb`. The accepted M1 prerequisite is
integrated at `d797a67`. This checkpoint is available for downstream integration;
it does not approve a public release or accept a specification compatibility gate.

The user explicitly removed Japanese testing and then VoiceOver testing from
M2 requirements on 16 October 2026. Neither is counted as a pass. Native keyboard,
semantic accessibility, marked-text composition, selected-run formatting, RTL,
combining-character and emoji checks remain in scope. The prepared VoiceOver
AppleScript driver was never executed or enabled. Earlier temporary Japanese
input settings were fully restored.

## Qualified evidence

| Area | Result and retained evidence |
| --- | --- |
| Frozen source | 745 Release tests, 12 fixture-dependent skips, zero failures; 87 Python tests, zero failures. Formatting, nine import boundaries and the 154-requirement/171-entry ledger pass. `build/m2-qualified6-{release-native,python,format,ledger}.log`. |
| Documents and authoring | Native Home/template/window routing, missing recent Locate/Remove, canonical duplicate retention, read-only refusal, branching and multipage/off-page flow, find/replace, preview/single Undo, save/reopen and independently inspected PDF/SVG. `build/m2-final-native-journey.json`, `build/m2-qualified5-native-replay.json`. |
| Text and keyboard | Actual no-pointer drawing journey; native selected-run Undo/Redo; real Australian marked-text cancel/commit; mixed Unicode, spelling selection and public output. Exact signed app replay: `build/m2-qualified6-native-replay.json`. AppKit graph identity/relations/frames/actions, focus escape and protection are also covered by the final suite. |
| Adaptive appearance | Native 760×560 editor layout regression retains canvas/inspector access and can reveal the library. Real Dark, Light and System exports are byte-identical. `build/m2-closure/appearance.json`. This UI-only probe has the candidate's identical compiled text section, a separate bundle identity and an ad hoc signature; it is not described as the shipping bundle. |
| Diagnostics and safe save | Native source-object navigation, cached/evaluated provenance, multiple-document isolation, affected versus harmless content, Cancel/separate copy and unchanged source bytes; redacted native support output. `build/m2-final-native-journey.json` and the final diagnostic/save regressions. Producer coverage remains a declared bounded slice. |
| Input trust | Malformed/oversize ZIP/XML/CFB/native metadata, bounded raster decoding, real helper timeout/cancellation, inert imported actions and calibrated no-fetch fixtures pass. See [input audit](M2-INPUT-TRUST-AUDIT.md) for exact limits. Codec scratch memory and general process/network sandboxing are not claimed. |
| Distribution | Exact development bundle is Developer ID signed, hardened, Apple notarized through `renoir-notary`, stapled and Gatekeeper accepted. ZIP/feed/pinned-key signatures pass. Stable policy rejects ad hoc or incomplete evidence. |
| Actual installed updates | Official pinned Sparkle CLI/framework rejects an altered signed feed (error1000) and archive (error4005), preserving the prior bundle byte-for-byte. Termination during an actual download preserves it; retry installs the exact final candidate. Both prior and updated apps natively open the same clean eight-shape/eight-connector drawing. A second installation preserves recorded preferences, recents/pins/removals and document bytes. `build/m2-closure/update-install.json`, `update-settings.json`. |
| Platform, content and support | Bundle inventory derives arm64 and binary floor27.0; actual local qualification is arm64/macOS27.0.1. Five complete upstream component notices and both MPL source offers are verified. Source/resource provenance is recorded with its evidentiary limits. Support reports redact drawing text, source paths, formulas and credentials by default. |

The update fixture uses an owned prior executable with fixture version0.23.2,
Developer ID signing and accepted/stapled notarization
`aa01f0ca-9f34-4313-a597-896c2c306650`. Installation uses loopback signed test
feeds and the original final archive. It neither publishes nor exercises the
public GitHub delivery endpoint. Interruption was during download; it is not
evidence of an arbitrary mid-replacement power loss. See the runnable scripts
and raw logs under `build/m2-closure/`. The normal installation was untouched,
the owned recent entry was removed, and test applications quit normally.

## Exact qualified candidate

- Development ZIP: `build/releases/development/0.23.3-0839994456aa/MacVisio-0.23.3.zip`
- SHA256: `5f081eea719d3693631586d42a9494a1fb135933ea0385346283ccf429a95028`
- Executable SHA256: `5c6b52a4ea96916d0a979906ef2a8c04e995cad04a1f20c3d4b3586d043f68b7`
- Developer ID team: `5NF98M544G`; final notarization: `889a4950-4527-4ee1-afdb-4fc3a5577151`
- Actual tested platform: Apple Silicon, macOS27.0.1. The derived27.0 binary
  floor is metadata, not evidence of a27.0 installation.

## Continuing release and compatibility obligations

`publicationAccepted` remains false. No feed, release or archive was published,
and no stable release manifest was accepted. Broader supported-platform
installations, controlled numerical performance and licensed exact-build Visio
round trips retain their original release/reference owners. Original-code
authorship and asset generation support a technical provenance classification;
they do not constitute a legal ownership attestation. No full Visio, language
candidate-picker or VoiceOver qualification is claimed.

These limits are explicit in the [task evidence](M2-TASK-EVIDENCE.json) and
[handoff](M2-HANDOFF.json). Historical preparation records in the earlier
[native acceptance journal](M2-NATIVE-ACCEPTANCE.md) retain the failures and open
states that led to this final checkpoint; this qualification is the current
engineering disposition.
