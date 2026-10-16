# MacVisio 0.23.4 stable release candidate

State: **published as latest stable, with the owner-approved performance exception recorded**. [MacVisio0.23.4](https://github.com/acousland/MacVisio/releases/tag/v0.23.4). All five anonymous public downloads and the stable latest feed match the accepted candidate. An isolated copy of the actual published0.23.3 app upgraded through its unmodified stable feed to the exact0.23.4 executable, without a feed override.

The candidate is version0.23.4/build29, Apple Silicon, macOS27.0.1 minimum. Its stable feed is the existing latest-release Sparkle URL. The conservative patch-level floor matches the actual qualified host. Existing releases are retained; publication created the new `v0.23.4` latest release.

Archive: `build/releases/stable-candidates/0.23.4/MacVisio-0.23.4.zip`.

SHA256: `16f5b578d2d0841f5b7c8f57b848438e98fed3434b73d79b0d71d5cc8764ae22`.

Apple notarisation `9e802fb0-ef2b-4c78-94bb-77aa3a1a3cde` is Accepted; Developer ID team5NF98M544G, stapled ticket, Gatekeeper and pinned ZIP/feed signatures pass. Metadata/release-tooling source is `728b56e1ef7e1f1dcb66dfa5424cfe0e777fdea0`; product Sources and Tests are unchanged from0839994, and the compiled text section matches the previously qualified executable. The updated policy carries forward the user's explicit removal of VoiceOver testing.

Actual Sparkle tests use the published `v0.23.3` app, preserved byte-for-byte after altered-feed, altered-archive and interrupted-download cases. Retry installs the exact0.23.4 target. A second install preserves actual recorded preferences and document hashes. Both app versions open the same saved flow; the new app edits a Unicode label, saves and reopens it cleanly, with matching public VSDX text. The owned test recent is removed and both apps quit normally.

Six gate records are accepted: platform, installed update, bounded security, native keyboard, declared native/output slice and content provenance/notices. The stable manifest still fails `performance: acceptance missing`, because controlled-latency is unaccepted. The specification's1000-shape drag/pan input/frame targets require measurements not supplied by the earlier three-event script. That script's p95 was246.7404ms, a different metric; no50ms/33ms pass is inferred. Historical intermittency disposition remains qualified.

The owner explicitly approved: **“Publish stable with performance exception.”** The exact archive hash above is pinned in the release policy's exception table. The manifest retains `controlled-latency: waived_by_owner`, `status: accepted_with_exception` and the authorization text. Other candidate hashes, versions, checks and gates cannot use this exception. The final verification report exposes it as `qualificationExceptions`; no performance pass is asserted. Sixteen focused release-policy checks pass, including rejection of wrong candidate/version, falsified passed status, altered evidence, duplicate exceptions and attempted security/crypto exemptions.

Raw candidate, notarisation, bundle, updater, native and Python records are retained under `build/m2-stable-0.23.4/`; the candidate and proposed gate manifest are under `build/releases/stable-candidates/0.23.4/`. These are local evidence, with no raw drawing/support logs selected for publication.

The first bundle-check harness calculated the project root one directory too high after being placed in a nested build directory. Its failed log and script are retained; fixing the owned harness root produced the passing bundle verification without changing the signed app.

Final publication source/manifest commit: `88aff9b5f132e402bdd8e894899d5efccf74c583`. The unchanged product bundle was assembled from728b56e; subsequent changes only record policy, tests and documentation. `publicationAccepted:true` includes the explicit `qualificationExceptions` record. Public upgrade/download results are retained in `build/m2-stable-0.23.4/publication-verification.json`.
