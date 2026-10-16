import XCTest
@testable import MacVisio

final class MetadataProbeEvidenceTests: XCTestCase {
    func testEnvelopeProbeRecordsDuplicateMaterializationComparison() throws {
        let nodes: [[String:Any]] = (0..<5000).map { index in
            ["id":index,"text":"Shape \(index)","sheet":["User.Payload":["value":String(repeating:"metadata",count:200),"formula":""]]]
        }
        let metadata = try JSONSerialization.data(withJSONObject:["format":4,"diagram":["pages":[["nodes":nodes]]]],options:[.sortedKeys])
        XCTAssertLessThan(metadata.count,VisioPackage.partLimit)
        var materialized: [Double] = [], header: [Double] = []
        for sample in 0..<6 {
            let old = try autoreleasepool { () throws -> Double in
                let start = ProcessInfo.processInfo.systemUptime
                let dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with:metadata) as? [String:Any])
                XCTAssertEqual(dictionary["format"] as? Int,4)
                return ProcessInfo.processInfo.systemUptime-start
            }
            let new = try autoreleasepool { () throws -> Double in
                let start = ProcessInfo.processInfo.systemUptime
                XCTAssertEqual(try NativeMetadataStorage.load(metadata,parts:[:]).data.count,metadata.count)
                return ProcessInfo.processInfo.systemUptime-start
            }
            if sample > 0 { materialized.append(old);header.append(new) }
        }
        let report: [String:Any] = [
            "host":ProcessInfo.processInfo.hostName,
            "os":ProcessInfo.processInfo.operatingSystemVersionString,
            "metadataBytes":metadata.count,
            "syntheticNodes":5000,
            "warmupSamples":1,
            "measuredSamples":5,
            "fullObjectDiscriminatorSeconds":materialized,
            "headerDiscriminatorSeconds":header,
            "fullObjectMedianSeconds":materialized.sorted()[2],
            "headerMedianSeconds":header.sorted()[2],
            "scope":"Envelope-discriminator comparison only. The synthetic model body is not imported or validated; these numbers do not measure total document decoding or guarantee a speedup for every input."
        ]
        if let path = ProcessInfo.processInfo.environment["MACVISIO_METADATA_EVIDENCE_PATH"] {
            let output = URL(fileURLWithPath:path)
            try FileManager.default.createDirectory(at:output.deletingLastPathComponent(),withIntermediateDirectories:true)
            try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.atomic)
        }
        XCTAssertEqual(materialized.count,5)
        XCTAssertTrue(materialized.allSatisfy{$0 > 0})
        XCTAssertTrue(header.allSatisfy{$0 > 0})
    }
}
