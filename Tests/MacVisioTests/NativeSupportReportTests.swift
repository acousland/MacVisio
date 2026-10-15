import Foundation
import XCTest
@testable import MacVisio

final class NativeSupportReportTests: XCTestCase {
    private let metadata = [
        "CFBundleIdentifier": "com.example.MacVisio", "CFBundleShortVersionString": "0.7.2",
        "CFBundleVersion": "42", "LSMinimumSystemVersion": "13.0", "MacVisioReleaseChannel": "development"
    ]

    func testEncodedSummaryExcludesDrawingAndDiagnosticSecretsByConstruction() throws {
        let secrets = ["SECRET_DRAWING_TEXT", "SECRET_TITLE", "SECRET_PAGE_NAME", "SECRET_SHAPE_DATA",
                       "SECRET_FORMULA", "SECRET_FONT_NAME", "SECRET_DIAGNOSTIC_MESSAGE", "SECRET_DIAGNOSTIC_CODE",
                       "SECRET_SOURCE_PART", "SECRET_SOURCE_VISIO_ID", "SECRET_SOURCE_CELL", "SECRET_SOURCE_FEATURE",
                       "SECRET_INPUT_KEY", "SECRET_RICH_TEXT", "SECRET_EMBEDDED_BYTES", "SECRET_SOURCE_SHAPE_ID",
                       "SECRET_LAYER_NAME", "https://user:SECRET_CREDENTIAL@example.invalid/SECRET_URL", "/Users/SECRET_PATH/file.vsdx"]
        var node = DiagramNode(text: secrets[0])
        var details = ShapeDetails()
        details.data = [ShapeDataProperty(key: secrets[3], label: secrets[3], value: secrets[3])]
        details.sheet = [secrets[4]: ShapeSheetCell(value: secrets[4], formula: secrets[4])]
        details.fontName = secrets[5]
        var character = ShapeCharacterStyle(node: node); character.fontName = secrets[5]
        details.textRuns = [ShapeTextRun(text: secrets[13], character: character, paragraph: ShapeParagraphStyle())]
        details.image = EmbeddedImage(data: Data(secrets[14].utf8), mimeType: secrets[14])
        details.sourceShapeID = secrets[15]
        details.hyperlinks = [ShapeHyperlink(address: secrets[17], subAddress: secrets[18], description: secrets[17])]
        details.layerNames = [secrets[16]]
        node.details = details; node.layer = secrets[16]
        var snapshot = Diagram(); snapshot.title = secrets[1]; snapshot.page.name = secrets[2]
        snapshot.page.nodes = [node]
        let edge = DiagramEdge(source: node.id, target: node.id, label: secrets[0])
        snapshot.page.edges = [edge]
        snapshot.page.sheet = [secrets[4]: ShapeSheetCell(value: secrets[3], formula: secrets[4])]
        let diagnostic = DocumentDiagnostic(code: secrets[7], origin: .calculation, severity: .warning,
                                            dimension: .behavior, target: .shape(page: snapshot.page.id, shape: node.id),
                                            source: .init(part: secrets[8], visioID: secrets[9], cell: secrets[10], feature: secrets[11]),
                                            displayState: .cached, message: secrets[6], inputKey: secrets[12])
        var bundle = metadata
        bundle["RecentFile"] = secrets[18]; bundle["SUFeedURL"] = secrets[17]
        bundle["SUPublicEDKey"] = secrets[12]; bundle["credential"] = secrets[17]
        let report = NativeSupportReport(snapshot: snapshot, diagnostics: [diagnostic], bundleMetadata: bundle)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let encoded = try encoder.encode(report)
        let json = String(decoding: encoded, as: UTF8.self)
        for secret in secrets + [snapshot.activePageID.uuidString, node.id.uuidString, edge.id.uuidString,
                                 Data(secrets[14].utf8).base64EncodedString()] {
            XCTAssertFalse(json.contains(secret), "Report leaked \(secret)")
        }
        XCTAssertEqual(report.application.bundleMetadata, metadata)
        XCTAssertEqual(report.counts.shapes, 1); XCTAssertEqual(report.counts.connectors, 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let diagnostics = try XCTUnwrap(object["diagnostics"] as? [String: Any])
        let buckets = try XCTUnwrap(diagnostics["buckets"] as? [[String: Any]])
        let bucket = try XCTUnwrap(buckets.first?["bucket"] as? [String: Any])
        XCTAssertEqual(Set(bucket.keys), ["origin", "dimension", "severity", "displayState"])
    }

    func testCountsIncludeStoredBackgroundHiddenAndGroupedObjectsExactlyOnce() {
        var snapshot = Diagram(); snapshot.version = 7
        var parent = DiagramNode(); parent.formatting.isGroup = true
        var child = DiagramNode(); child.parentID = parent.id; child.locked = true
        snapshot.page.nodes = [parent, child]
        snapshot.page.edges = [DiagramEdge(source: parent.id, target: child.id)]
        snapshot.page.layers = [DiagramLayer(name: "Default", visible: false)]
        var background = DiagramPage(); background.isBackground = true
        background.nodes = [DiagramNode(), DiagramNode(), DiagramNode()]
        background.edges = [DiagramEdge(source: background.nodes[0].id, target: background.nodes[1].id),
                            DiagramEdge(source: background.nodes[1].id, target: background.nodes[2].id)]
        snapshot.page.backgroundPageID = background.id
        var other = DiagramPage(); other.backgroundPageID = background.id
        snapshot.pages += [background, other]
        let report = NativeSupportReport(snapshot: snapshot, diagnostics: [], bundleMetadata: metadata)
        XCTAssertEqual(report.counts.pages, 3); XCTAssertEqual(report.counts.shapes, 5)
        XCTAssertEqual(report.counts.connectors, 3)
        XCTAssertEqual(report.format.nativeModelVersion, 7, "Report the supplied model version without inferring a file version.")
        XCTAssertEqual(report.application.bundleMetadata["CFBundleShortVersionString"], "0.7.2")
        XCTAssertEqual(report.application.bundleMetadata["CFBundleVersion"], "42")
    }

    func testDiagnosticsAggregateOnlyTypedDimensionsAndReportSuppliedCoverage() throws {
        let original = DocumentDiagnostic(code: "one", origin: .calculation, severity: .warning,
                                          dimension: .behavior, target: .document,
                                          displayState: .cached, message: "First")
        var otherProvenance = original; otherProvenance.code = "two"; otherProvenance.message = "Second"
        otherProvenance.inputKey = "different"; otherProvenance.target = .page(UUID())
        var otherOrigin = original; otherOrigin.origin = .font
        var otherDimension = original; otherDimension.dimension = .rendering
        var otherSeverity = original; otherSeverity.severity = .error
        var otherState = original; otherState.displayState = .stale
        let records = [original, original, otherProvenance, otherOrigin, otherDimension, otherSeverity, otherState]
        let report = NativeSupportReport(snapshot: Diagram(), diagnostics: records, bundleMetadata: [:])
        XCTAssertEqual(report.diagnostics.coverage, .suppliedRecordsOnly)
        XCTAssertEqual(report.diagnostics.suppliedRecordCount, 7)
        XCTAssertEqual(report.diagnostics.buckets.count, 5)
        XCTAssertEqual(report.diagnostics.buckets.first { $0.bucket == .init(original) }?.count, 3)
        XCTAssertEqual(report.diagnostics.buckets.map(\.count).reduce(0, +), 7)
        XCTAssertEqual(report, NativeSupportReport(snapshot: Diagram(), diagnostics: Array(records.reversed()), bundleMetadata: [:]))
        let empty = NativeSupportReport(snapshot: Diagram(), diagnostics: [], bundleMetadata: [:])
        XCTAssertEqual(empty.diagnostics.coverage, .suppliedRecordsOnly)
        XCTAssertEqual(empty.diagnostics.suppliedRecordCount, 0); XCTAssertTrue(empty.diagnostics.buckets.isEmpty)
        XCTAssertTrue(empty.application.bundleMetadata.isEmpty, "Missing app metadata is not fabricated.")
        let json = String(decoding: try JSONEncoder().encode(empty), as: UTF8.self)
        XCTAssertTrue(json.contains("suppliedRecordsOnly")); XCTAssertFalse(json.contains("complete"))
    }

    func testTimingAggregatesRejectInvalidSamplesAndKeepMissingStagesMissing() throws {
        let samples: [NativeSupportReport.TimingSample] = [
            .init(stage: .open, seconds: 0.25), .init(stage: .open, seconds: 0.5), .init(stage: .open, seconds: 0),
            .init(stage: .open, seconds: -1), .init(stage: .open, seconds: .nan),
            .init(stage: .open, seconds: .infinity), .init(stage: .open, seconds: -.infinity),
            .init(stage: .validation, seconds: 0),
            .init(stage: .save, seconds: -0.1)
        ]
        let report = NativeSupportReport(snapshot: Diagram(), diagnostics: [], bundleMetadata: [:], timings: samples)
        XCTAssertEqual(report.timings.coverage, .suppliedRecordsOnly)
        XCTAssertEqual(report.timings.suppliedRecordCount, 9)
        XCTAssertEqual(report.timings.stages.map(\.stage), [.open, .validation, .save])
        let open = try XCTUnwrap(report.timings.stages.first)
        XCTAssertEqual(open.acceptedSampleCount, 3); XCTAssertEqual(open.rejectedSampleCount, 4)
        XCTAssertEqual(open.totalSeconds, 0.75); XCTAssertEqual(open.maximumSeconds, 0.5)
        XCTAssertFalse(open.totalOverflowed)
        let validation = try XCTUnwrap(report.timings.stages.first { $0.stage == .validation })
        XCTAssertEqual(validation.acceptedSampleCount, 1); XCTAssertEqual(validation.rejectedSampleCount, 0)
        XCTAssertEqual(validation.totalSeconds, 0); XCTAssertEqual(validation.maximumSeconds, 0)
        let save = try XCTUnwrap(report.timings.stages.last)
        XCTAssertEqual(save.acceptedSampleCount, 0); XCTAssertEqual(save.rejectedSampleCount, 1)
        XCTAssertNil(save.totalSeconds); XCTAssertNil(save.maximumSeconds)
        XCTAssertFalse(save.totalOverflowed)
        _ = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report))
        let empty = NativeSupportReport(snapshot: Diagram(), diagnostics: [], bundleMetadata: [:])
        XCTAssertTrue(empty.timings.stages.isEmpty); XCTAssertEqual(empty.timings.suppliedRecordCount, 0)
    }

    func testTimingSumOverflowIsExplicitWithoutNonfiniteSerializedValues() throws {
        let report = NativeSupportReport(snapshot: Diagram(), diagnostics: [], bundleMetadata: [:], timings: [
            .init(stage: .draw, seconds: .greatestFiniteMagnitude),
            .init(stage: .draw, seconds: .greatestFiniteMagnitude), .init(stage: .draw, seconds: 0)
        ])
        let draw = try XCTUnwrap(report.timings.stages.first)
        XCTAssertEqual(draw.acceptedSampleCount, 3); XCTAssertEqual(draw.rejectedSampleCount, 0)
        XCTAssertTrue(draw.totalOverflowed); XCTAssertNil(draw.totalSeconds)
        XCTAssertEqual(draw.maximumSeconds, .greatestFiniteMagnitude)
        _ = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report))
    }

    func testIndependentSnapshotsDoNotShareMetadataDiagnosticsOrTimings() throws {
        var first = Diagram(); first.page.nodes = [DiagramNode()]
        var second = Diagram(); second.version = 2; second.pages += [DiagramPage()]
        let issue = DocumentDiagnostic.legacyImportNote("Private", code: "private")
        let a = NativeSupportReport(snapshot: first, diagnostics: [issue], bundleMetadata: metadata,
                                    timings: [.init(stage: .open, seconds: 1)])
        let encodedA = try JSONEncoder().encode(a)
        let b = NativeSupportReport(snapshot: second, diagnostics: [], bundleMetadata: ["CFBundleVersion": "99"],
                                    timings: [.init(stage: .save, seconds: 2)])
        first.page.nodes = []; second.pages = []
        XCTAssertEqual(a.counts.pages, 1); XCTAssertEqual(a.counts.shapes, 1)
        XCTAssertEqual(b.counts.pages, 2); XCTAssertEqual(b.counts.shapes, 0)
        XCTAssertEqual(a.diagnostics.suppliedRecordCount, 1); XCTAssertEqual(b.diagnostics.suppliedRecordCount, 0)
        XCTAssertEqual(a.timings.stages.map(\.stage), [.open]); XCTAssertEqual(b.timings.stages.map(\.stage), [.save])
        XCTAssertEqual(a.application.bundleMetadata["CFBundleVersion"], "42")
        XCTAssertEqual(b.application.bundleMetadata["CFBundleVersion"], "99")
        XCTAssertEqual(a.format.nativeModelVersion, 1); XCTAssertEqual(b.format.nativeModelVersion, 2)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: encodedA) as? NSDictionary,
                       try JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as? NSDictionary)
    }
}
