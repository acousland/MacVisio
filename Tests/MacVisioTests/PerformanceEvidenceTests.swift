import AppKit
import XCTest
@testable import MacVisio

final class PerformanceEvidenceTests:XCTestCase {
    private var runID:UUID?
    override func tearDown() {
        if let runID { _ = PerformanceEvidence.endRun(runID) }
        runID = nil
        super.tearDown()
    }
    private func start(heartbeatInterval:Double? = nil) throws {
        runID = try XCTUnwrap(PerformanceEvidence.beginRun(heartbeatInterval:heartbeatInterval))
    }
    private func finish() throws -> PerformanceEvidence.Report {
        let report = try XCTUnwrap(runID.flatMap{PerformanceEvidence.endRun($0)})
        runID = nil
        return report
    }
    func testDisabledCallsRetainNothingAndRunDoesNotReplaceAnotherRun() throws {
        XCTAssertNil(PerformanceEvidence.begin(.calculation))
        PerformanceEvidence.count(.evaluatedCells,by:12)
        try start()
        XCTAssertNil(PerformanceEvidence.beginRun())
        XCTAssertNil(PerformanceEvidence.endRun(UUID()))
        let report = try finish()
        XCTAssertTrue(report.stages.isEmpty)
        XCTAssertTrue(report.workCounts.isEmpty)
        XCTAssertEqual(report.unfinishedSpans,0)
    }
    func testScopesEndOnceOnThrowAndConcurrentCountsAreExact() throws {
        enum Expected:Error { case failure }
        try start()
        XCTAssertThrowsError(try PerformanceEvidence.measure(.encoding) { throw Expected.failure })
        DispatchQueue.concurrentPerform(iterations:100) { _ in
            let span = PerformanceEvidence.begin(.route)
            PerformanceEvidence.count(.routeRequests)
            PerformanceEvidence.end(span);PerformanceEvidence.end(span)
        }
        PerformanceEvidence.count(.drawnObjects,by:0)
        let report = try finish()
        XCTAssertEqual(report.stages["encoding"]?.count,1)
        XCTAssertEqual(report.stages["route"]?.count,100)
        XCTAssertEqual(report.workCounts["routeRequests"],100)
        XCTAssertNil(report.workCounts["drawnObjects"])
        XCTAssertEqual(report.unfinishedSpans,0)
        XCTAssertTrue(report.stages.values.flatMap(\.samplesSeconds).allSatisfy{$0 >= 0})
    }
    func testUnfinishedAndStaleScopesCannotContaminateNextRun() throws {
        try start()
        let old = PerformanceEvidence.begin(.snapshot)
        XCTAssertEqual(try finish().unfinishedSpans,1)
        try start()
        PerformanceEvidence.end(old)
        XCTAssertTrue(try finish().stages.isEmpty)
    }
    func testRawSamplesAreBoundedWithoutLosingAggregateCount() throws {
        try start()
        for _ in 0..<10_001 { PerformanceEvidence.measure(.event) {} }
        let summary = try XCTUnwrap(try finish().stages["event"])
        XCTAssertEqual(summary.count,10_001)
        XCTAssertEqual(summary.samplesSeconds.count,10_000)
        XCTAssertEqual(summary.droppedSamples,1)
        XCTAssertGreaterThanOrEqual(summary.totalSeconds,summary.samplesSeconds.reduce(0,+))
    }
    func testCellCountsRecordCacheMissesWithoutContentOrIdentifiers() throws {
        var node = DiagramNode(text:"PRIVATE SYNTHETIC SENTINEL")
        node.formatting.sheet = ["Width":ShapeSheetCell(value:"2",formula:"User.Padding+2"),"User.Padding":ShapeSheetCell(value:"0.5")]
        var page = DiagramPage();page.nodes = [node]
        let context = ShapeSheetContext(page:page)
        try start()
        XCTAssertEqual(try context.number(node.id,"Width"),2.5)
        XCTAssertEqual(try context.number(node.id,"width"),2.5)
        _ = try context.number(node.id,"ThePage!PageWidth")
        _ = try context.number(node.id,"ThePage!PageWidth")
        let report = try finish()
        XCTAssertEqual(report.workCounts["evaluatedCells"],3)
        let json = String(decoding:try JSONEncoder().encode(report),as:UTF8.self)
        XCTAssertFalse(json.contains(node.text))
        XCTAssertFalse(json.contains(node.id.uuidString))
        XCTAssertFalse(json.contains("User.Padding"))
    }
    func testSmallChangeExposesVisitedAndEvaluatedCountsIndependently() throws {
        func page() -> DiagramPage {
            var page = DiagramPage()
            var node = DiagramNode(text:"");node.width = 144;node.height = 72
            node.formatting.sheet = ["Width":ShapeSheetCell(value:"2",formula:"2 in")]
            page.nodes = [node];return page
        }
        var before = Diagram();before.pages = [page(),page()];before.activePageID = before.pages[0].id
        var after = before;after.pages[0].nodes[0].text = "Changed"
        try start()
        _ = ShapeSheetEngine.recalculate(after,previous:before,skipUnchangedPagesComparedTo:before)
        let partial = try finish()
        try start()
        _ = ShapeSheetEngine.recalculate(after)
        let full = try finish()
        XCTAssertEqual(partial.workCounts["visitedObjects"],1)
        XCTAssertEqual(full.workCounts["visitedObjects"],2)
        XCTAssertEqual(partial.workCounts["evaluatedCells"],1)
        XCTAssertEqual(full.workCounts["evaluatedCells"],2)
        XCTAssertNil(partial.workCounts["drawnObjects"])
    }
    func testDrawingSeparatesPreparationRouteTextAndDrawWork() throws {
        _ = NSApplication.shared
        var page = DiagramPage(width:400,height:300)
        let first = DiagramNode(x:10,y:10,text:"One"),second = DiagramNode(x:200,y:130,text:"Two")
        page.nodes = [first,second]
        page.edges = [DiagramEdge(source:first.id,target:second.id,label:"Label",style:.straight)]
        try start()
        XCTAssertFalse(try DiagramExport.png(page,scale:1).isEmpty)
        let report = try finish()
        XCTAssertEqual(report.workCounts["drawnObjects"],3)
        XCTAssertEqual(report.workCounts["sceneObjectsPrepared"],2)
        XCTAssertEqual(report.workCounts["routeRequests"],1)
        XCTAssertEqual(report.workCounts["textMeasurements"],3)
        XCTAssertNil(report.workCounts["visitedObjects"])
        XCTAssertNil(report.workCounts["evaluatedCells"])
        for stage in ["draw","route","textLayout","scenePreparation"] {
            XCTAssertGreaterThan(report.stages[stage]?.count ?? 0,0)
        }
    }
    func testNativeSnapshotAndSuccessfulEncodingHaveSeparateCounts() throws {
        _ = NSApplication.shared
        let document = MacVisioDocument()
        let unprofiled = try document.data(ofType:MacVisioDocument.nativeType)
        try start()
        let profiled = try document.data(ofType:MacVisioDocument.nativeType)
        let report = try finish()
        XCTAssertEqual(profiled,unprofiled)
        XCTAssertEqual(report.workCounts["snapshotsCaptured"],1)
        XCTAssertEqual(report.workCounts["encodedDocuments"],1)
        XCTAssertEqual(report.stages["snapshot"]?.count,1)
        XCTAssertEqual(report.stages["encoding"]?.count,1)
        XCTAssertNil(report.stages["event"])
    }
    func testFailedEncodingDoesNotCountAsEncodedDocument() throws {
        _ = NSApplication.shared
        let document = MacVisioDocument()
        try start()
        XCTAssertThrowsError(try document.data(ofType:"invalid.synthetic.test"))
        let report = try finish()
        XCTAssertEqual(report.stages["encoding"]?.count,1)
        XCTAssertEqual(report.workCounts["snapshotsCaptured"],1)
        XCTAssertNil(report.workCounts["encodedDocuments"])
    }
    func testCommitAndUndoCountInstallationsWithoutCountingNoOpReplace() throws {
        _ = NSApplication.shared
        let document = MacVisioDocument()
        document.undoManager?.groupsByEvent = false
        var next = document.diagram;next.page.nodes = [DiagramNode(text:"Synthetic")]
        try start()
        document.undoManager?.beginUndoGrouping()
        document.replace(with:next,action:"Add")
        document.undoManager?.endUndoGrouping()
        document.replace(with:document.diagram,action:"No-op")
        document.undoManager?.undo()
        let report = try finish()
        XCTAssertEqual(report.workCounts["transactionsCommitted"],2)
        XCTAssertEqual(report.stages["commit"]?.count,2)
        XCTAssertEqual(report.stages["calculation"]?.count,1)
        XCTAssertNil(report.workCounts["drawnObjects"])
    }
    func testDirtyRectangleDrawReportsWorkWithoutRunningCalculation() throws {
        _ = NSApplication.shared
        let document = MacVisioDocument()
        document.diagram.page.nodes = [DiagramNode(x:20,y:20,text:"Near"),DiagramNode(x:400,y:400,text:"Far")]
        let editor = EditorWindowController(document:document)
        defer { editor.window?.close() }
        let canvas = editor.canvas
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1200,pixelsHigh:1200,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep:bitmap))
        func draw(_ rect:CGRect) throws -> PerformanceEvidence.Report {
            try start()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.saveGState();context.cgContext.clip(to:rect)
            canvas.draw(rect)
            context.cgContext.restoreGState()
            NSGraphicsContext.restoreGraphicsState()
            return try finish()
        }
        let full = try draw(canvas.bounds)
        let small = try draw(CGRect(x:canvas.pageFrame.minX+20,y:canvas.pageFrame.minY+20,width:20,height:20))
        XCTAssertEqual(full.workCounts["drawnObjects"],2)
        // The baseline submits both nodes even when AppKit clips one away. This
        // assertion remains useful when M1 reduces submissions: it does not make
        // the existing broad draw a performance target.
        XCTAssertLessThanOrEqual(small.workCounts["drawnObjects"] ?? 0,full.workCounts["drawnObjects"] ?? 0)
        XCTAssertGreaterThan(small.workCounts["sceneObjectsPrepared"] ?? 0,0)
        XCTAssertNil(small.workCounts["visitedObjects"])
        XCTAssertNil(small.workCounts["evaluatedCells"])
    }
    func testHeartbeatUsesMainQueueSamplesAndDoesNotInferEventDurations() throws {
        try start(heartbeatInterval:0.005)
        let sampled = expectation(description:"main queue ran")
        DispatchQueue.main.asyncAfter(deadline:.now()+0.04) { sampled.fulfill() }
        wait(for:[sampled],timeout:2)
        let report = try finish()
        XCTAssertGreaterThan(report.workCounts["heartbeatSamples"] ?? 0,0)
        XCTAssertEqual(report.stages["mainLoopGap"]?.count,report.workCounts["heartbeatSamples"])
        XCTAssertNil(report.stages["event"])
    }
}
