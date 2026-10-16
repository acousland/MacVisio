import Foundation

/// A redacted, in-memory summary of caller-supplied values. This type does not
/// open a document, collect diagnostics/timings, own a revision, or export a file.
/// No drawing strings, object identities, or diagnostic provenance are retained.
struct NativeSupportReport: Encodable, Equatable {
    enum Redaction: String, Encodable { case countsAndAllowlistedBundleMetadata }
    enum Coverage: String, Encodable { case suppliedRecordsOnly }

    struct Application: Encodable, Equatable {
        /// Only these explicit bundle metadata fields are eligible for export.
        /// Callers must supply bundle metadata, never document-derived values.
        static let allowedKeys: Set<String> = [
            "CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion",
            "LSMinimumSystemVersion", "MacVisioReleaseChannel"
        ]
        let bundleMetadata: [String: String]

        init(bundleMetadata: [String: String]) {
            self.bundleMetadata = bundleMetadata.filter { Self.allowedKeys.contains($0.key) }
        }
    }

    struct Format: Encodable, Equatable {
        /// The supplied Diagram's model version, not an inferred source-file,
        /// VSDX envelope, storage-manifest or external producer version.
        let nativeModelVersion: Int
    }

    struct Counts: Encodable, Equatable {
        /// Counts stored pages and objects once, including background pages,
        /// hidden/locked objects and group members. Not rendered occurrences.
        let pages: Int
        let shapes: Int
        let connectors: Int
    }

    struct DiagnosticBucket: Encodable, Equatable, Hashable {
        let origin: DocumentDiagnostic.Origin
        let dimension: DocumentDiagnostic.Dimension
        let severity: DocumentDiagnostic.Severity
        let displayState: DocumentDiagnostic.DisplayState

        init(_ record: DocumentDiagnostic) {
            origin = record.origin; dimension = record.dimension
            severity = record.severity; displayState = record.displayState
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(origin.rawValue); hasher.combine(dimension.rawValue)
            hasher.combine(severity.rawValue); hasher.combine(displayState.rawValue)
        }

        fileprivate var sortKey: [String] {
            [origin.rawValue, dimension.rawValue, severity.rawValue, displayState.rawValue]
        }
    }

    struct DiagnosticCount: Encodable, Equatable {
        let bucket: DiagnosticBucket
        let count: Int
    }

    struct Diagnostics: Encodable, Equatable {
        let coverage: Coverage
        /// Counts supplied record occurrences, without identity-based deduping.
        /// Zero records does not assert that this document has no issues.
        let suppliedRecordCount: Int
        let buckets: [DiagnosticCount]
    }

    /// Closed vocabulary: arbitrary profiler labels cannot enter the report.
    /// This is an input contract, not a claim that a producer is integrated.
    enum TimingStage: String, Encodable, CaseIterable {
        case open, validation, editorSetup, firstViewport
        case event, commit, calculation, textLayout, scenePreparation, route, draw
        case snapshot, encoding, save, close, mainLoopGap
    }

    struct TimingSample {
        let stage: TimingStage
        let seconds: Double
    }

    struct TimingAggregate: Encodable, Equatable {
        let stage: TimingStage
        let acceptedSampleCount: Int
        let rejectedSampleCount: Int
        /// Nil when no valid samples were supplied or the finite sum overflowed.
        let totalSeconds: Double?
        let maximumSeconds: Double?
        let totalOverflowed: Bool
    }

    struct Timings: Encodable, Equatable {
        let coverage: Coverage
        let suppliedRecordCount: Int
        /// Only supplied stages occur. Missing phases are not zero-duration work.
        /// Stages may be inclusive/nested; no cross-stage total is manufactured.
        let stages: [TimingAggregate]
    }

    let schemaVersion: Int
    let redaction: Redaction
    let application: Application
    let format: Format
    let counts: Counts
    let diagnostics: Diagnostics
    let timings: Timings

    init(snapshot: Diagram, diagnostics records: [DocumentDiagnostic],
         bundleMetadata: [String: String], timings samples: [TimingSample] = []) {
        schemaVersion = 1
        redaction = .countsAndAllowlistedBundleMetadata
        application = Application(bundleMetadata: bundleMetadata)
        format = Format(nativeModelVersion: snapshot.version)
        counts = Counts(pages: snapshot.pages.count,
                        shapes: snapshot.pages.reduce(0) { $0 + $1.nodes.count },
                        connectors: snapshot.pages.reduce(0) { $0 + $1.edges.count })

        var buckets: [DiagnosticBucket: Int] = [:]
        for record in records { buckets[DiagnosticBucket(record), default: 0] += 1 }
        diagnostics = Diagnostics(coverage: .suppliedRecordsOnly, suppliedRecordCount: records.count,
                                  buckets: buckets.map { DiagnosticCount(bucket: $0.key, count: $0.value) }
                                    .sorted { $0.bucket.sortKey.lexicographicallyPrecedes($1.bucket.sortKey) })

        var accumulators: [TimingStage: TimingAccumulator] = [:]
        for sample in samples { accumulators[sample.stage, default: TimingAccumulator()].append(sample.seconds) }
        timings = Timings(coverage: .suppliedRecordsOnly, suppliedRecordCount: samples.count,
                          stages: TimingStage.allCases.compactMap { stage in
                              accumulators[stage].map { $0.summary(stage: stage) }
                          })
    }

    private struct TimingAccumulator {
        var accepted = 0
        var rejected = 0
        var total: Double = 0
        var maximum: Double?
        var overflowed = false

        mutating func append(_ seconds: Double) {
            guard seconds.isFinite, seconds >= 0 else { rejected += 1; return }
            accepted += 1
            maximum = max(maximum ?? 0, seconds)
            if !overflowed {
                let next = total + seconds
                if next.isFinite { total = next } else { overflowed = true }
            }
        }

        func summary(stage: TimingStage) -> TimingAggregate {
            TimingAggregate(stage: stage, acceptedSampleCount: accepted, rejectedSampleCount: rejected,
                            totalSeconds: accepted > 0 && !overflowed ? total : nil,
                            maximumSeconds: maximum, totalOverflowed: overflowed)
        }
    }
}
