# M2 native support-summary preparation

Branch: `codex/m2-native-editor`. WP-12-T04 slice status: **implemented_unaccepted**. M0's local ledger/harness is integrated at `7921840`; M1 remains in progress. This addition consumes the existing value model and diagnostic transport without freezing provisional transaction, scene, calculation or resource interfaces. Native support-export integration waits for accepted M1 contracts.

## Bounded scope

`NativeSupportReport` prepares an immutable, `Encodable` value from a supplied `Diagram`, `[DocumentDiagnostic]`, caller-supplied bundle metadata and typed timing samples. It does not open/read/write files, inspect bundles, collect runtime measurements, obtain a committed snapshot, own revisions, show UI or send a report. The existing `scripts/release_policy.py support` command still produces only its bundle-metadata report; no new model data is wired into that command.

The summary explicitly carries schema version, the supplied native diagram model version and the allowlisted app bundle metadata. `CFBundleIdentifier`, `CFBundleShortVersionString`, `CFBundleVersion`, `LSMinimumSystemVersion` and `MacVisioReleaseChannel` are the only accepted metadata keys. Callers must pass actual bundle metadata rather than document-derived or arbitrary values. Missing fields remain absent. The plist deployment floor is metadata, not evidence of whole-bundle platform qualification. The model version does not assert a source file, native envelope, storage manifest or external producer version.

Page, shape and connector totals count each stored page/node/edge once, including background pages, hidden/locked objects and group members. Background reuse does not multiply the totals. These are supplied model counts, not rendered-instance counts, validation results or a claim that all source features were imported.

## Redaction and coverage contract

The report retains no drawing text, title/page/layer names, object/source IDs, formulas, shape data, hyperlinks, embedded bytes, font names, paths, diagnostic codes/prose/input keys/source provenance or arbitrary timing labels. Diagnostic records contribute only a tuple of typed origin, feature dimension, severity and display/cache state plus an occurrence count. Repeated records count repeatedly; source identity is never inspected to deduplicate them. Ordering is deterministic. Severity remains distinct, including informational records.

Diagnostics always carry `coverage: suppliedRecordsOnly` and `suppliedRecordCount`. Zero means no diagnostic records were supplied. It does not establish a clean document, producer integration, successful evaluation, freshness against a committed input key, or complete diagnostic coverage. No revision-validation or provenance-accuracy claim is made.

Timings accept only a closed `TimingStage` enum. Every supplied stage reports accepted/rejected sample counts, optional aggregate total and maximum seconds, and an explicit total-overflow indicator. Only finite nonnegative samples contribute durations; negative/NaN/infinite samples count as rejected and are never converted to zero. A stage with only rejected samples has no durations. Summation overflow leaves the total absent with `totalOverflowed: true`, while retaining accepted count and finite maximum. No supplied stage means no stage entry. The summary never invents missing phases or a whole-job total, because stages can be nested or inclusive. Timing coverage is also `suppliedRecordsOnly`; the helper itself performs no measurement.

The allowlist permits the actual app's version/build/identifier/platform/channel strings by design. It excludes unrelated bundle fields, preferences, logs, environment, accounts and credentials. Integrators remain responsible for supplying actual bundle metadata rather than putting private values into an allowlisted metadata field.

## Evidence and remaining acceptance

The focused test source covers secret sentinels across text, titles/page names, data, formulas, fonts/runs, hyperlinks/credentials/paths, embedded bytes, source IDs, diagnostic prose/code/source/input key and unrelated bundle metadata. It also checks stored/background/group/hidden counts; supplied model/app versions; typed diagnostic grouping and duplicate occurrences; absent record/metadata/timing coverage; finite/nonnegative rejection, zero duration and total overflow; and independence of two supplied snapshots.

- `swiftc -frontend -parse Sources/MacVisio/NativeSupportReport.swift Tests/MacVisioTests/NativeSupportReportTests.swift` and whitespace validation passed.
- The primary agent's focused `NativeSupportReportTests` run passed **6 tests, zero failures**; log: `build/m2-support-report.log`.
- No full-suite result for this updated slice is claimed. The preceding M0-integrated full run (503 tests, 12 skipped, zero failures) predates these six tests. This worker did not run a full Swift build.

This preparation does not accept WP-12-T04 or MV-OPS-04. A real user-selected local export flow, accepted committed-snapshot ownership, current diagnostic producer coverage/freshness, actual runtime timing adapters, reviewable sharing behavior, platform/content-rights qualification and native end-to-end privacy checks remain open. No original checkout was changed, and no network/publish/push action was performed.
