import XCTest
@testable import MacVisio

final class NativeMetadataStorageTests: XCTestCase {
    func testSmallPayloadPassesThroughWithoutChangingParts() throws {
        let payload = Data(#"{"format":2,"diagram":{}}"#.utf8)
        var parts = ["vendor/opaque.bin": Data([0x10, 0x20])]
        let before = parts

        let stored = try NativeMetadataStorage.store(payload, in: &parts)
        let loaded = try NativeMetadataStorage.load(stored, parts: parts)

        XCTAssertEqual(stored, payload)
        XCTAssertEqual(loaded.data, payload)
        XCTAssertTrue(loaded.storageParts.isEmpty)
        XCTAssertEqual(parts, before)
    }

    func testLargePayloadSplitsAndReassemblesWithHashesAndContentType() throws {
        let payload = Data(repeating: 0xA7, count: VisioPackage.partLimit + 137)
        var parts = [
            "[Content_Types].xml": contentTypesXML(),
            "vendor/opaque.bin": Data([0x00, 0x44, 0xFE])
        ]

        try NativeMetadataStorage.registerContentType(in: &parts)
        let metadata = try NativeMetadataStorage.store(payload, in: &parts)
        let loaded = try NativeMetadataStorage.load(metadata, parts: parts)
        let manifest = try manifestObject(metadata)

        XCTAssertEqual(loaded.data, payload)
        XCTAssertEqual(loaded.storageParts.count, 1)
        XCTAssertEqual(manifest["encoding"] as? String, "zlib")
        XCTAssertEqual(manifest["decodedBytes"] as? Int, payload.count)
        XCTAssertEqual(manifest["totalBytes"] as? Int, parts[loaded.storageParts.first!]?.count)
        XCTAssertLessThanOrEqual(parts[loaded.storageParts.first!]!.count, VisioPackage.partLimit)
        XCTAssertEqual(parts["vendor/opaque.bin"], Data([0x00, 0x44, 0xFE]))

        let types = try VisioXML.document(try XCTUnwrap(parts["[Content_Types].xml"]))
        let metadataTypes = types.rootElement()?.elementsLocal("Default").filter {
            $0.attr("Extension") == "mvmeta"
        }
        XCTAssertEqual(metadataTypes?.count, 1)
        XCTAssertEqual(metadataTypes?.first?.attr("ContentType"), "application/octet-stream")
    }

    func testFormatOneAndTwoMetadataAreReturnedUnchanged() throws {
        for format in [1, 2] {
            let legacyPayload = Data(#"{"format":FORMAT,"publicHashes":{},"diagram":{}}"#.replacingOccurrences(of: "FORMAT", with: String(format)).utf8)
            let loaded = try NativeMetadataStorage.load(legacyPayload, parts: ["vendor/opaque.bin": Data([1])])

            XCTAssertEqual(loaded.data, legacyPayload)
            XCTAssertTrue(loaded.storageParts.isEmpty)
        }
    }

    func testOldUncompressedFormatThreeSegmentsStillLoad() throws {
        let payload = Data(repeating: 0x7D, count: VisioPackage.partLimit + 3)
        let (metadata, parts) = try legacyRawManifest(payload)

        let loaded = try NativeMetadataStorage.load(metadata, parts: parts)

        XCTAssertEqual(loaded.data, payload)
        XCTAssertEqual(loaded.storageParts.count, 2)
    }

    func testLoadRejectsCorruptMissingDuplicateEscapedAndBadSizeSegments() throws {
        let payload = Data(repeating: 0x5C, count: VisioPackage.partLimit + 3)
        let (metadata, parts) = try legacyRawManifest(payload)
        let segmentName = "macvisio/metadata/segment1.mvmeta"

        var corruptedParts = parts
        var corruptedSegment = try XCTUnwrap(corruptedParts[segmentName])
        corruptedSegment[corruptedSegment.startIndex] ^= 0x01
        corruptedParts[segmentName] = corruptedSegment
        assertRejected(metadata, parts: corruptedParts)

        var missingParts = parts
        missingParts.removeValue(forKey: segmentName)
        assertRejected(metadata, parts: missingParts)

        var duplicate = try manifestObject(metadata)
        var duplicateSegments = try segments(in: duplicate)
        duplicateSegments[1]["name"] = "macvisio/metadata/segment0.mvmeta"
        duplicate["segments"] = duplicateSegments
        assertRejected(try encode(duplicate), parts: parts)

        var escaped = try manifestObject(metadata)
        var escapedSegments = try segments(in: escaped)
        escapedSegments[0]["name"] = "macvisio/metadata/../../vendor/payload.mvmeta"
        escaped["segments"] = escapedSegments
        assertRejected(try encode(escaped), parts: parts)

        var badSize = try manifestObject(metadata)
        var badSizeSegments = try segments(in: badSize)
        badSizeSegments[1]["bytes"] = 4
        badSize["segments"] = badSizeSegments
        assertRejected(try encode(badSize), parts: parts)
    }

    func testCompressedPayloadRejectsWrongLengthBombBudgetAndCorruptZlib() throws {
        let payload = Data(repeating: 0x63, count: VisioPackage.partLimit + 19)
        var parts: [String: Data] = [:]
        let metadata = try NativeMetadataStorage.store(payload, in: &parts)
        let originalObject = try manifestObject(metadata)
        let segmentName = try XCTUnwrap(segments(in: originalObject).first?["name"] as? String)

        var wrongLength = originalObject
        wrongLength["decodedBytes"] = payload.count + 1
        assertRejected(try encode(wrongLength), parts: parts)

        var decodedBomb = originalObject
        decodedBomb["decodedBytes"] = NativeMetadataStorage.maximumDecodedBytes + 1
        assertRejected(try encode(decodedBomb), parts: parts)

        var corruptParts = parts
        let corruptBytes = Data(repeating: 0xFF, count: try XCTUnwrap(corruptParts[segmentName]?.count))
        corruptParts[segmentName] = corruptBytes
        var corruptManifest = originalObject
        var corruptDescriptors = try segments(in: corruptManifest)
        corruptDescriptors[0]["sha256"] = VisioFormat.hash(corruptBytes)
        corruptManifest["segments"] = corruptDescriptors
        assertRejected(try encode(corruptManifest), parts: corruptParts)
    }

    func testRemoveSegmentsPreservesUnrelatedAndNoncanonicalPaths() {
        var parts: [String: Data] = [
            "macvisio/metadata/segment0.mvmeta": Data([0]),
            "macvisio/metadata/segment12.mvmeta": Data([12]),
            "macvisio/metadata/segment00.mvmeta": Data([0, 0]),
            "macvisio/metadata/segment-x.mvmeta": Data([0xFF]),
            "macvisio/metadata/sub/segment1.mvmeta": Data([1]),
            "vendor/opaque.bin": Data([2])
        ]

        NativeMetadataStorage.removeSegments(from: &parts)

        XCTAssertNil(parts["macvisio/metadata/segment0.mvmeta"])
        XCTAssertNil(parts["macvisio/metadata/segment12.mvmeta"])
        XCTAssertEqual(parts["macvisio/metadata/segment00.mvmeta"], Data([0, 0]))
        XCTAssertEqual(parts["macvisio/metadata/segment-x.mvmeta"], Data([0xFF]))
        XCTAssertEqual(parts["macvisio/metadata/sub/segment1.mvmeta"], Data([1]))
        XCTAssertEqual(parts["vendor/opaque.bin"], Data([2]))
    }

    func testContentTypeRegistrationIsIdempotentAndRefusesConflicts() throws {
        var parts = ["[Content_Types].xml": contentTypesXML()]
        try NativeMetadataStorage.registerContentType(in: &parts)
        let first = try XCTUnwrap(parts["[Content_Types].xml"])
        try NativeMetadataStorage.registerContentType(in: &parts)
        XCTAssertEqual(parts["[Content_Types].xml"], first)

        var conflicting = ["[Content_Types].xml": Data(#"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="mvmeta" ContentType="application/json"/></Types>"#.utf8)]
        XCTAssertThrowsError(try NativeMetadataStorage.registerContentType(in: &conflicting))
        XCTAssertEqual(conflicting["[Content_Types].xml"], Data(#"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="mvmeta" ContentType="application/json"/></Types>"#.utf8))
    }

    func testLoadAndStoreEnforceMaximumSegmentAndPayloadLimits() throws {
        var tooManySegments: [String: Any] = [
            "format": 3,
            "totalBytes": NativeMetadataStorage.maximumSegments * VisioPackage.partLimit,
            "segments": (0...NativeMetadataStorage.maximumSegments).map { index in
                ["name": "macvisio/metadata/segment\(index).mvmeta", "bytes": VisioPackage.partLimit, "sha256": String(repeating: "0", count: 64)] as [String: Any]
            }
        ]
        assertRejected(try encode(tooManySegments), parts: [:])

        tooManySegments["segments"] = [
            ["name": "macvisio/metadata/segment0.mvmeta", "bytes": VisioPackage.partLimit, "sha256": String(repeating: "0", count: 64)],
            ["name": "macvisio/metadata/segment1.mvmeta", "bytes": VisioPackage.partLimit, "sha256": String(repeating: "0", count: 64)]
        ]
        tooManySegments["totalBytes"] = NativeMetadataStorage.maximumCompressedBytes + 1
        assertRejected(try encode(tooManySegments), parts: [:])

        var decodedBomb: [String: Any] = [
            "format": 3,
            "totalBytes": 1,
            "encoding": "zlib",
            "decodedBytes": NativeMetadataStorage.maximumDecodedBytes + 1,
            "segments": [["name": "macvisio/metadata/segment0.mvmeta", "bytes": 1, "sha256": String(repeating: "0", count: 64)]]
        ]
        assertRejected(try encode(decodedBomb), parts: ["macvisio/metadata/segment0.mvmeta": Data([0])])
        decodedBomb["decodedBytes"] = VisioPackage.partLimit + 1
        decodedBomb["totalBytes"] = NativeMetadataStorage.maximumCompressedBytes + 1
        assertRejected(try encode(decodedBomb), parts: ["macvisio/metadata/segment0.mvmeta": Data([0])])
    }

    private func assertRejected(
        _ metadata: Data,
        parts: [String: Data],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try NativeMetadataStorage.load(metadata, parts: parts), file: file, line: line)
    }

    private func manifestObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func segments(in object: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(object["segments"] as? [[String: Any]])
    }

    private func encode(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func legacyRawManifest(_ payload: Data) throws -> (Data, [String: Data]) {
        let count = (payload.count + VisioPackage.partLimit - 1) / VisioPackage.partLimit
        var parts: [String: Data] = [:]
        var descriptors: [[String: Any]] = []
        for index in 0..<count {
            let start = index * VisioPackage.partLimit
            let end = min(payload.count, start + VisioPackage.partLimit)
            let name = "macvisio/metadata/segment\(index).mvmeta"
            let data = payload.subdata(in: start..<end)
            parts[name] = data
            descriptors.append(["name": name, "bytes": data.count, "sha256": VisioFormat.hash(data)])
        }
        let manifest: [String: Any] = ["format": 3, "totalBytes": payload.count, "segments": descriptors]
        return (try encode(manifest), parts)
    }

    private func contentTypesXML() -> Data {
        Data(#"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/></Types>"#.utf8)
    }
}
