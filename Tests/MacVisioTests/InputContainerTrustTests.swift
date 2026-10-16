import Foundation
import XCTest
@testable import MacVisio

final class InputContainerTrustTests: XCTestCase {
    func testZIPRejectsDuplicateEntriesAndSymlinksWithoutExtractingThem() throws {
        try withArchive(entries: required + [Entry("vendor/value", [1]), Entry("vendor/value", [2])]) {
            XCTAssertThrowsError(try VisioPackage.read($0))
        }
        try withArchive(entries: required + [Entry("vendor/link", Array("../../outside".utf8), mode: 0o120777)]) {
            XCTAssertThrowsError(try VisioPackage.read($0))
            XCTAssertFalse(FileManager.default.fileExists(atPath: $0.deletingLastPathComponent().appendingPathComponent("vendor").path))
        }
    }

    func testZIPRejectsUnsafeActualEntryNamesAndChecksumTampering() throws {
        for name in ["../outside", "/absolute", "vendor/../outside", "vendor\\outside", "vendor:outside"] {
            try withArchive(entries: required + [Entry(name, [1])]) {
                XCTAssertThrowsError(try VisioPackage.read($0), name)
            }
        }
        try withArchive(entries: required + [Entry("vendor/value", [1, 2, 3], checksum: 0)]) {
            XCTAssertThrowsError(try VisioPackage.read($0))
        }
    }

    func testZIPRejectsAdvertisedPartAndEntryCountBudgets() throws {
        try withArchive(entries: required + [Entry("vendor/value", [1], decodedSize: UInt32(VisioPackage.partLimit + 1))]) {
            XCTAssertThrowsError(try VisioPackage.read($0))
        }
        let many = (0..<9_999).map { Entry("vendor/value\($0)", []) }
        try withArchive(entries: required + many) {
            XCTAssertThrowsError(try VisioPackage.read($0))
        }
    }

    func testZIPPositiveControlPreservesOpaquePartBytes() throws {
        let bytes: [UInt8] = [0, 0xFF, 0x80, 0x41]
        try withArchive(entries: required + [Entry("vendor/value", bytes)]) {
            XCTAssertEqual(try VisioPackage.read($0)["vendor/value"], Data(bytes))
        }
    }

    func testCompoundRejectsFATAndDirectoryCycles() throws {
        let original = try CompoundFile(streams: ["large": Data(repeating: 7, count: 5_000)]).encoded()
        XCTAssertEqual(try CompoundFile.read(original).streams["large"]?.count, 5_000)
        let header = BinaryBytes(original)
        let directoryID = try header.u32(48), fatID = try header.u32(76)
        let directoryOffset = (Int(directoryID) + 1) * 512
        let fatOffset = (Int(fatID) + 1) * 512

        var cyclicAllocation = original
        cyclicAllocation.set(directoryID, at: fatOffset + Int(directoryID) * 4)
        XCTAssertThrowsError(try CompoundFile.read(cyclicAllocation))

        let rootChild = try header.u32(directoryOffset + 76)
        var cyclicDirectory = original
        cyclicDirectory.set(rootChild, at: directoryOffset + Int(rootChild) * 128 + 68)
        XCTAssertThrowsError(try CompoundFile.read(cyclicDirectory))

        var oversizedStream = original
        oversizedStream.set(UInt64(CompoundFile.limit) + 1, at: directoryOffset + Int(rootChild) * 128 + 120)
        XCTAssertThrowsError(try CompoundFile.read(oversizedStream))
    }

    func testCompoundRejectsMiniFATCycleAndExcessAllocation() throws {
        let original = try CompoundFile(streams: ["small": Data(repeating: 3, count: 100)]).encoded()
        XCTAssertEqual(try CompoundFile.read(original).streams["small"]?.count, 100)
        let header = BinaryBytes(original)
        let directoryOffset = (Int(try header.u32(48)) + 1) * 512
        let rootChild = try header.u32(directoryOffset + 76)
        let start = try header.u32(directoryOffset + Int(rootChild) * 128 + 116)
        let miniFATOffset = (Int(try header.u32(60)) + 1) * 512

        var cycle = original
        cycle.set(start, at: miniFATOffset + Int(start) * 4)
        XCTAssertThrowsError(try CompoundFile.read(cycle))

        let next = try header.u32(miniFATOffset + Int(start) * 4)
        var excess = original
        excess.set(start, at: miniFATOffset + Int(next) * 4)
        XCTAssertThrowsError(try CompoundFile.read(excess))
    }

    private struct Entry {
        var name: String
        var bytes: [UInt8]
        var mode: UInt16
        var checksum: UInt32?
        var decodedSize: UInt32?
        init(_ name: String, _ bytes: [UInt8], mode: UInt16 = 0o100644, checksum: UInt32? = nil, decodedSize: UInt32? = nil) {
            self.name = name; self.bytes = bytes; self.mode = mode
            self.checksum = checksum; self.decodedSize = decodedSize
        }
    }
    private var required: [Entry] { [Entry("[Content_Types].xml", []), Entry("_rels/.rels", [])] }

    /// Deliberately writes raw stored ZIP records so unsafe/duplicate names and
    /// corrupt metadata are not sanitized by the production archive writer.
    private func withArchive(entries: [Entry], body: (URL) throws -> Void) throws {
        var local = Data(), central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8), size = UInt32(entry.bytes.count)
            let decodedSize = entry.decodedSize ?? size, checksum = entry.checksum ?? crc32(entry.bytes)
            let offset = UInt32(local.count)
            local.put(UInt32(0x04034B50)); local.put(UInt16(20)); local.put(UInt16(0)); local.put(UInt16(0))
            local.put(UInt16(0)); local.put(UInt16(0)); local.put(checksum); local.put(size); local.put(decodedSize)
            local.put(UInt16(name.count)); local.put(UInt16(0)); local.append(name); local.append(contentsOf: entry.bytes)
            central.put(UInt32(0x02014B50)); central.put(UInt16(0x0314)); central.put(UInt16(20))
            central.put(UInt16(0)); central.put(UInt16(0)); central.put(UInt16(0)); central.put(UInt16(0))
            central.put(checksum); central.put(size); central.put(decodedSize); central.put(UInt16(name.count))
            central.put(UInt16(0)); central.put(UInt16(0)); central.put(UInt16(0)); central.put(UInt16(0))
            central.put(UInt32(entry.mode) << 16); central.put(offset); central.append(name)
        }
        let offset = UInt32(local.count), centralSize = UInt32(central.count)
        local.append(central); local.put(UInt32(0x06054B50)); local.put(UInt16(0)); local.put(UInt16(0))
        local.put(UInt16(entries.count)); local.put(UInt16(entries.count)); local.put(centralSize); local.put(offset); local.put(UInt16(0))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-container-trust-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.vsdx")
        try local.write(to: url)
        try body(url)
    }

    private func crc32(_ bytes: [UInt8]) -> UInt32 {
        var value = UInt32.max
        for byte in bytes {
            value ^= UInt32(byte)
            for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0xEDB88320 : 0) }
        }
        return value ^ UInt32.max
    }
}
