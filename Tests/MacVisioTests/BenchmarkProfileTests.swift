import AppKit
import XCTest
@testable import MacVisio

final class BenchmarkProfileTests:XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-benchmark-test-\(UUID())")
        try FileManager.default.createDirectory(at:url,withIntermediateDirectories:false)
        return url
    }
    private func fixture(_ directory:URL,synthetic:Bool = true,brokenCalculation:Bool = false,largePaper:Bool = false) throws -> URL {
        var diagram = Diagram();diagram.page.name = synthetic ? "Synthetic 1" : "Private page"
        var first = DiagramNode(x:20,y:20,text:synthetic ? "Synthetic shape 1" : "Private sentinel")
        first.formatting.sheet = ["Width":ShapeSheetCell(value:"2",formula:brokenCalculation ? "1/0" : "2+User.Padding"),"User.Padding":ShapeSheetCell(value:"0.25")]
        let second = DiagramNode(x:300,y:100,text:"Synthetic shape 2")
        if largePaper { diagram.page.width = 7200;diagram.page.height = 7200;first.y = 7000 }
        diagram.page.nodes = [first,second]
        diagram.page.edges = [DiagramEdge(source:first.id,target:second.id,label:"Synthetic connector 1",style:.straight)]
        let url = directory.appendingPathComponent("input.vsdx")
        try VisioFormat.write(diagram,to:url)
        return url
    }
    func testOwnedSyntheticEventSaveAndCloseProduceActualEvidenceWithoutChangingInput() throws {
        if let reason = BenchmarkProfile.nativeRoutingUnavailableReason { throw XCTSkip(reason) }
        _ = NSApplication.shared
        let folder = try directory();defer { try? FileManager.default.removeItem(at:folder) }
        let input = try fixture(folder),output = folder.appendingPathComponent("result.json")
        let original = try Data(contentsOf:input)
        let registered = NSDocumentController.shared.documents.map{ObjectIdentifier($0)}
        XCTAssertTrue(try BenchmarkProfile.sample(input,to:output))
        XCTAssertEqual(try Data(contentsOf:input),original)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:output)) as? [String:Any])
        let phases = try XCTUnwrap(report["phases"] as? [String:[String:Any]])
        for phase in BenchmarkProfile.phaseNames { XCTAssertEqual(phases[phase]?["status"] as? String,"passed",phase) }
        let counts = try XCTUnwrap(report["workCounts"] as? [String:Int])
        for counter in ["visitedObjects","evaluatedCells","drawnObjects","transactionsCommitted","snapshotsCaptured","encodedDocuments","heartbeatSamples"] {
            XCTAssertGreaterThan(counts[counter] ?? 0,0,counter)
        }
        let metrics = try XCTUnwrap(report["metrics"] as? [String:Double])
        XCTAssertEqual(metrics["routedEvents"],3)
        XCTAssertTrue((report["eventTrace"] as? String)?.contains("NSApplication queue") == true)
        XCTAssertEqual(report["inputSaved"] as? Bool,false)
        XCTAssertEqual(NSDocumentController.shared.documents.map{ObjectIdentifier($0)},registered)
    }
    func testNativeRoutingScrollsOffscreenSyntheticTargetIntoViewport() throws {
        if let reason = BenchmarkProfile.nativeRoutingUnavailableReason { throw XCTSkip(reason) }
        _ = NSApplication.shared
        let folder = try directory();defer { try? FileManager.default.removeItem(at:folder) }
        let input = try fixture(folder,largePaper:true),output = folder.appendingPathComponent("scrolled-result.json")
        XCTAssertTrue(try BenchmarkProfile.sample(input,to:output))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:output)) as? [String:Any])
        XCTAssertEqual((report["metrics"] as? [String:Double])?["routedEvents"],3)
    }
    func testNonSyntheticInputRetainsFailureAndUnobservedSave() throws {
        _ = NSApplication.shared
        let folder = try directory();defer { try? FileManager.default.removeItem(at:folder) }
        let input = try fixture(folder,synthetic:false),output = folder.appendingPathComponent("result.json")
        XCTAssertFalse(try BenchmarkProfile.sample(input,to:output))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:output)) as? [String:Any])
        let phases = try XCTUnwrap(report["phases"] as? [String:[String:Any]])
        XCTAssertEqual(phases["open"]?["status"] as? String,"failed")
        XCTAssertEqual(phases["save"]?["status"] as? String,"not_observed")
        XCTAssertEqual(phases["close"]?["status"] as? String,"passed")
        XCTAssertFalse(String(decoding:try Data(contentsOf:output),as:UTF8.self).contains("Private sentinel"))
    }
    func testExistingResultAndInputPathAreRefusedBeforeWriting() throws {
        let folder = try directory();defer { try? FileManager.default.removeItem(at:folder) }
        let input = try fixture(folder),output = folder.appendingPathComponent("result.json")
        let original = try Data(contentsOf:input),sentinel = Data("keep previous evidence".utf8)
        try sentinel.write(to:output)
        XCTAssertThrowsError(try BenchmarkProfile.sample(input,to:input))
        XCTAssertThrowsError(try BenchmarkProfile.sample(input,to:output))
        XCTAssertEqual(try Data(contentsOf:input),original)
        XCTAssertEqual(try Data(contentsOf:output),sentinel)
    }
    func testCompletedCalculationSpanWithIssuesIsStillAFailedPhase() throws {
        if let reason = BenchmarkProfile.nativeRoutingUnavailableReason { throw XCTSkip(reason) }
        _ = NSApplication.shared
        let folder = try directory();defer { try? FileManager.default.removeItem(at:folder) }
        let input = try fixture(folder,brokenCalculation:true),output = folder.appendingPathComponent("result.json")
        XCTAssertFalse(try BenchmarkProfile.sample(input,to:output))
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:output)) as? [String:Any])
        let phases = try XCTUnwrap(report["phases"] as? [String:[String:Any]])
        XCTAssertEqual(phases["calculation"]?["status"] as? String,"failed")
        XCTAssertEqual(phases["event"]?["status"] as? String,"failed")
        XCTAssertEqual(phases["save"]?["status"] as? String,"not_observed")
        XCTAssertGreaterThan(report["calculationIssueCount"] as? Int ?? 0,0)
    }
}
