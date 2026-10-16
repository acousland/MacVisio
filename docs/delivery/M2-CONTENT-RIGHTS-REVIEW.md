# M2 content and redistribution review

This review covers the five third-party components initially checked in qualified5
and rebound to the final qualified6 source commit
`0839994456aa82f3533456c75f9f10da1ebcd2bb`, archive SHA256
`5f081eea719d3693631586d42a9494a1fb135933ea0385346283ccf429a95028`.
`build/m2-rights-review/final-license-verification.json` verifies every final
license byte against the same upstream records. A later candidate must rebind
the inventory to its own archive and confirm the notices.
It records technical license compliance evidence; it does not assert ownership
of the application's original work or approve publication.

| Component | License route and distribution conditions | Observed evidence |
| --- | --- | --- |
| libvisio 0.1.11, including the two converter helpers | MPL 2.0: retain notices and make corresponding covered source available, with a source-location notice. | Bundled MPL text exactly matches the official source archive. The bundled SOURCES.txt identifies the exact upstream source archive. An actual download matches the installed formula's SHA256. The formula contains no source patch; the bundle script changes Mach-O load paths on copies. |
| librevenge 0.0.6, including stream/generator libraries | Use the MPL 2.0 option identified in the upstream README; the installed formula offers MPL 2.0 or LGPL 2.1-or-later. Retain MPL notices and corresponding source access. | Same source/download/notice checks pass. The extra bundled LGPL text is retained; this review does not infer that both alternative license routes must be applied simultaneously. |
| ICU 78.3, including Unicode data | Preserve the complete Unicode/ICU license and included third-party notices. | The entire bundled 27,718-byte LICENSE matches the official release-78.3 file byte for byte. The installed formula/source URL identifies 78.3. No separate font file is bundled. |
| ZIPFoundation 0.9.20 | MIT: preserve the copyright and permission notice. | Bundled LICENSE exactly matches pinned revision 22787ffb59de99e5dc1fbfe80b19c97a904ad48d. |
| Sparkle 2.10.0 and nested helpers | Preserve its MIT notice plus the external BSD/MIT/zlib notices included in its LICENSE. | The complete bundled 6,154-byte license matches pinned revision eef1a539a373c1f1a320624b1130fc5de7b2e100. This includes the bsdiff, sais-lite, Ed25519 and signature-verifier notices. |

The MPL source archives were fetched from the exact URLs already shipped in
SOURCES.txt, without installing or executing them. Hashes are retained in
`build/m2-rights-review/source-verification.json`; byte comparisons of all five
license files are in `build/m2-rights-review/license-verification.json`. The
archives remain alongside those records. These checks establish availability at
review time; release maintenance must continue to meet source-access obligations.

Primary terms and notices: [MPL 2.0 sections 3.1–3.4](https://www.mozilla.org/en-US/MPL/2.0/),
[Mozilla's distribution FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/),
[ICU 78.3](https://github.com/unicode-org/icu/blob/release-78.3/LICENSE),
[ZIPFoundation 0.9.20](https://github.com/weichsel/ZIPFoundation/blob/0.9.20/LICENSE),
[Sparkle 2.10.0](https://github.com/sparkle-project/Sparkle/blob/2.10.0/LICENSE).

The app icon is rendered by `scripts/MakeIcon.swift` from gradients, paths and
rounded rectangles; that script reads no external image or font asset. The
candidate inventory records the script and icon hashes. No standalone stencil,
template or font files occur in the candidate's resources. Built-in shape and
template definitions are application code and still require the application's
owner to confirm their provenance along with the rest of that code.

The remaining owner input is specific: confirm authority to redistribute the
application source, built-in shapes/templates and generated icon, and identify
any external contribution or copied asset that this source/resource inventory
does not reveal. The repository has no root application LICENSE; this review
does not assign one or presume that an open-source grant is required for the
owner's own work. Until that input is recorded against the final candidate,
`redistribution_rights_accepted` remains false.
