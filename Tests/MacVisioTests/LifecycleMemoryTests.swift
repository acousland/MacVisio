import MacVisioInfrastructure
import AppKit
import Darwin
import XCTest
@testable import MacVisio

final class LifecycleMemoryTests: XCTestCase {
    func testRasterCacheRetainsDecodedPixelCostWithinDeclaredBudget() throws {
        try onMain {
            _ = NSApplication.shared
            DiagramDrawing.clearImageCache()
            defer { DiagramDrawing.clearImageCache() }
            let startEvictions = DiagramDrawing.imageCacheStatistics.evictions
            for index in 1...20 {
                try autoreleasepool {
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1024,pixelsHigh:1024,
                                                               bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,
                                                               colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
                    let pixels = try XCTUnwrap(bitmap.bitmapData)
                    pixels.initialize(repeating:UInt8(index),count:bitmap.bytesPerRow*bitmap.pixelsHigh)
                    let bytes = try XCTUnwrap(bitmap.representation(using:.png,properties:[:]))
                    var page = DiagramPage(width:128,height:128)
                    var node = DiagramNode(x:0,y:0,text:"");node.width = 128;node.height = 128
                    node.formatting.image = EmbeddedImage(data:bytes,mimeType:"image/png")
                    page.nodes = [node]
                    _ = try DiagramExport.png(page,scale:1)
                    XCTAssertLessThanOrEqual(DiagramDrawing.imageCacheStatistics.cost,ResourceBudgets.decodedImages)
                    XCTAssertLessThanOrEqual(DiagramDrawing.imageCacheStatistics.count,ResourceBudgets.imageCount)
                }
            }
            let retained = DiagramDrawing.imageCacheStatistics
            XCTAssertGreaterThan(retained.evictions,startEvictions)
            XCTAssertGreaterThan(retained.cost,0)
            XCTAssertLessThan(retained.count,20,"Compressed PNG bytes must not hide decoded raster retention")
        }
    }

    func testTwentyOpenEditSaveCloseCyclesReleaseDocumentsAndRecordResidentMemory() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M1-cycles-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let input = directory.appendingPathComponent("source.vsdx")
            let opaque = Data(repeating: 0xA5, count: 2 * 1024 * 1024)
            try autoreleasepool {
                var fixture = Diagram()
                fixture.page.nodes = (0..<64).map { index in
                    DiagramNode(x: Double(index % 8) * 120, y: Double(index / 8) * 90, text: "Lifecycle shape \(index)")
                }
                try VisioFormat.write(fixture, to: input)
                var parts = try VisioPackage.read(input)
                parts["vendor/lifecycle-opaque.bin"] = opaque
                try VisioPackage.write(parts, to: input)
            }
            let baseline = residentBytes()
            var samples: [UInt64] = []
            var sourceCosts: [Int] = []
            for cycle in 0..<20 {
                weak var releasedDocument: MacVisioDocument?
                try autoreleasepool {
                    let document = try MacVisioDocument(contentsOf: input, ofType: MacVisioDocument.visioType)
                    releasedDocument = document
                    document.undoManager?.groupsByEvent = false
                    let sourceID = try XCTUnwrap(document.diagram.visioArchive?.sourceResourceID)
                    for edit in 0..<8 {
                        var next = document.diagram
                        next.page.nodes[edit].text = "Cycle \(cycle), edit \(edit)"
                        document.undoManager?.beginUndoGrouping()
                        document.replace(with: next, action: "Edit")
                        document.undoManager?.endUndoGrouping()
                        XCTAssertEqual(document.diagram.visioArchive?.sourceResourceID, sourceID)
                    }
                    let output = directory.appendingPathComponent("cycle-\(cycle).vsdx")
                    try save(document, to: output)
                    XCTAssertFalse(document.isDocumentEdited)
                    XCTAssertEqual(document.diagram.visioArchive?.pages[0].original, document.diagram.page)
                    XCTAssertEqual(document.diagram.visioArchive?.parts["vendor/lifecycle-opaque.bin"], opaque)
                    sourceCosts.append(document.diagram.visioArchive?.sourceByteCount ?? 0)
                    document.close()
                    try FileManager.default.removeItem(at: output)
                }
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
                XCTAssertNil(releasedDocument, "A closed document must not be retained by its completed save/job/undo history")
                samples.append(residentBytes())
            }
            let meanX = 9.5
            let meanY = samples.map(Double.init).reduce(0, +) / Double(samples.count)
            let numerator = samples.enumerated().reduce(0.0) { $0 + (Double($1.offset) - meanX) * (Double($1.element) - meanY) }
            let denominator = (0..<samples.count).reduce(0.0) { $0 + pow(Double($1) - meanX, 2) }
            let report: [String: Any] = [
                "host": ProcessInfo.processInfo.hostName,
                "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "cycles": samples.count,
                "shapesPerDocument": 64,
                "editsPerCycle": 8,
                "opaqueBytesPerSource": opaque.count,
                "residentBaselineBytes": baseline,
                "residentSamplesBytes": samples,
                "residentPeakBytes": samples.max() ?? 0,
                "residentFinalBytes": samples.last ?? 0,
                "residentSlopeBytesPerCycle": numerator / denominator,
                "retainedSourceBytesPerOpenDocument": sourceCosts,
                "undoCountLimit": ResourceBudgets.undoCount,
                "limitations": "RSS is process-wide allocator/OS evidence, not a leak proof or a deterministic retained-byte cap. This fixture does not create editor windows or exercise raster decoding. Undo payload byte budgeting requires separate history qualification."
            ]
            if let path = ProcessInfo.processInfo.environment["MACVISIO_LIFECYCLE_EVIDENCE_PATH"] {
                let output = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
            }
            XCTAssertEqual(samples.count, 20)
            XCTAssertTrue(samples.allSatisfy { $0 > 0 }, "Mach resident-memory readings must succeed")
        }
    }

    func testLongUndoHistoryEvictsOldestGroupsAndRetainsWorkingRedo() throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument()
            defer { document.close() }
            document.diagram.page.nodes = [DiagramNode(text: "0")]
            document.undoManager?.groupsByEvent = false
            for index in 1...120 {
                var next = document.diagram;next.page.nodes[0].text = String(index)
                document.undoManager?.beginUndoGrouping();document.replace(with: next, action: "Edit");document.undoManager?.endUndoGrouping()
            }
            var undos = 0
            while document.undoManager?.canUndo == true && undos < 121 { document.undoManager?.undo();undos += 1 }
            XCTAssertEqual(undos, ResourceBudgets.undoCount)
            XCTAssertEqual(document.diagram.page.nodes[0].text, "20")
            var redos = 0
            while document.undoManager?.canRedo == true && redos < 121 { document.undoManager?.redo();redos += 1 }
            XCTAssertEqual(redos, ResourceBudgets.undoCount)
            XCTAssertEqual(document.diagram.page.nodes[0].text, "120")
        }
    }

    func testBudgetEvictionInsideExplicitUndoGroupKeepsCurrentActionUndoable() throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument()
            defer { document.close() }
            document.diagram.page.nodes = [DiagramNode(text:"0")]
            // A valid in-memory preservation owner whose shared resources make
            // each action's conservative charge exceed half the undo budget.
            document.diagram.visioArchive = VisioDocumentArchive(parts:["opaque.bin":Data(repeating:1,count:10*1024*1024)],
                                                                  pagesPart:"visio/pages/pages.xml",pages:[],connectorHierarchyVersion:1)
            document.undoManager?.groupsByEvent = false
            for value in 1...2 {
                var next = document.diagram;next.page.nodes[0].text = String(value)
                document.undoManager?.beginUndoGrouping()
                document.replace(with:next,action:"Edit")
                XCTAssertEqual(document.undoManager?.groupingLevel,1,"Evicting old history must preserve the caller's active group")
                document.undoManager?.endUndoGrouping()
            }
            XCTAssertEqual(document.lastUndoBudgetDecision?.discardOldHistory,true)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram.page.nodes[0].text,"1")
            XCTAssertFalse(document.undoManager?.canUndo ?? true)
            document.undoManager?.redo()
            XCTAssertEqual(document.diagram.page.nodes[0].text,"2")
        }
    }

    private func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    private func save(_ document: MacVisioDocument, to url: URL) throws {
        var completed = false
        var failure: Error?
        document.save(to: url, ofType: MacVisioDocument.visioType, for: .saveAsOperation) { failure = $0;completed = true }
        let deadline = Date().addingTimeInterval(20)
        while !completed && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        guard completed else { throw DiagramError.invalid("Lifecycle save completion timed out") }
        if let failure { throw failure }
    }

    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}
