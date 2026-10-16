import MacVisioInfrastructure
import AppKit
import ImageIO
import XCTest
@testable import MacVisio

final class OwnedExportJobTests: XCTestCase {
    func testSVGUsesFrozenSnapshotAndPrintingPolicyWithBatchedMainPreparation() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = try temporaryDirectory()
            let output = directory.appendingPathComponent("snapshot.svg")
            let owner = LifecycleJobOwner()
            var diagram = fixture(count:80)
            diagram.page.nodes[0].text = "Captured export text"
            diagram.page.nodes[0].width = 300
            var hidden = DiagramNode(x:0,y:0,text:"Hidden print text");hidden.layer = "Screen only"
            diagram.page.nodes.append(hidden)
            diagram.page.layers = [DiagramLayer(name:"Screen only",visible:true,printable:false)]
            let input = LifecycleJobInput(ownerID:owner.id,snapshotID:UUID(),revision:17)
            var finished = false
            var outcome:Result<OwnedExportResult,Error>?
            try OwnedExportJobs.submit(snapshot:diagram,input:input,sourceURL:nil,destination:output,format:.svg,owner:owner) {
                outcome = $0;finished = true
            }
            diagram.page.nodes[0].text = "Newer live text"
            try pump(until:{finished})
            let result = try XCTUnwrap(outcome).get()
            XCTAssertEqual(result.input,input)
            XCTAssertEqual(result.preparation.preparedObjects,80)
            XCTAssertGreaterThan(result.preparation.mainBatches,2)
            XCTAssertGreaterThan(result.preparation.maximumMainStepSeconds,0)
            let svg = try String(contentsOf:output)
            XCTAssertTrue(svg.contains("Captured export text"))
            XCTAssertFalse(svg.contains("Newer live text"))
            XCTAssertFalse(svg.contains("Hidden print text"))
            _ = try VisioXML.document(Data(svg.utf8))
        }
    }

    func testPDFAndPNGAssemblyProducesPublicArtifactsAndRetainsAllForegroundPages() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = try temporaryDirectory()
            let owner = LifecycleJobOwner()
            var diagram = fixture(count:3)
            var second = DiagramPage(name:"Second page",width:300,height:200)
            second.nodes = [DiagramNode(x:10,y:10,text:"Second foreground")]
            var background = DiagramPage(name:"Background",width:300,height:200)
            background.isBackground = true
            background.nodes = [DiagramNode(x:0,y:0,text:"Background content")]
            second.backgroundPageID = background.id
            diagram.pages += [second,background]
            let pdf = directory.appendingPathComponent("all.pdf")
            let pdfResult = try export(diagram,to:pdf,format:.pdf,allPages:true,owner:owner)
            let publicPDF = try XCTUnwrap(CGPDFDocument(pdf as CFURL))
            XCTAssertEqual(publicPDF.numberOfPages,2)
            XCTAssertEqual(publicPDF.page(at:2)?.getBoxRect(.mediaBox).width,300)
            XCTAssertEqual(pdfResult.preparation.preparedObjects,5)
            let png = directory.appendingPathComponent("page.png")
            _ = try export(diagram,to:png,format:.png,owner:owner)
            let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL,nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource,0,nil))
            XCTAssertEqual(image.width,Int(diagram.page.paperWidth*2))
            XCTAssertEqual(image.height,Int(diagram.page.paperHeight*2))
        }
    }

    func testCancellationDuringPreparationAndInputAliasKeepExistingDestination() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = try temporaryDirectory()
            let output = directory.appendingPathComponent("existing.svg")
            let valid = Data("existing valid destination".utf8)
            try valid.write(to:output)
            let owner = LifecycleJobOwner()
            let input = LifecycleJobInput(ownerID:owner.id,snapshotID:UUID(),revision:1)
            var handle:LifecycleJobHandle?
            var finished = false
            var error:Error?
            handle = try OwnedExportJobs.submit(snapshot:fixture(count:300),input:input,sourceURL:nil,destination:output,
                                               format:.svg,owner:owner,progress:{ _ in handle?.cancel() }) { result in
                if case .failure(let failure) = result { error = failure }
                else { XCTFail("Cancelled preparation cannot publish output") }
                finished = true
            }
            try pump(until:{finished})
            XCTAssertEqual(error as? LifecycleJobError,.cancelled)
            XCTAssertEqual(try Data(contentsOf:output),valid)
            XCTAssertThrowsError(try export(fixture(count:1),to:output,format:.svg,owner:owner,source:output)) {
                XCTAssertEqual($0 as? LifecycleJobError,.inputIsDestination)
            }
            XCTAssertEqual(try Data(contentsOf:output),valid)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:directory.path),["existing.svg"])
        }
    }

    func testPackageExportUsesOwnedSnapshotAndPublicWriter() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = try temporaryDirectory()
            let diagram = fixture(count:2)
            let output = directory.appendingPathComponent("drawing.vsdx")
            _ = try export(diagram,to:output,format:.vsdx,owner:LifecycleJobOwner())
            let imported = try VisioFormat.read(from:output)
            XCTAssertEqual(imported.diagram.pages.map(\.id),diagram.pages.map(\.id))
            XCTAssertEqual(imported.diagram.page.nodes.map(\.text),diagram.page.nodes.map(\.text))
            let parts = try VisioPackage.read(output)
            XCTAssertNotNil(parts["visio/pages/page1.xml"])
        }
    }

    func testSelectionStencilJobWritesCapturedPublicMasterWithoutMutatingFragment() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = try temporaryDirectory()
            let output = directory.appendingPathComponent("selection.vssx")
            let owner = LifecycleJobOwner()
            var fragment = DiagramPage();fragment.nodes = [DiagramNode(text:"Captured master")]
            let originalID = fragment.nodes[0].id
            let definition = StencilDefinition(name:"Selected master",family:"Source",fragment:fragment)
            let input = LifecycleJobInput(ownerID:owner.id,snapshotID:UUID(),revision:4)
            var finished = false
            var outcome:Result<OwnedExportResult,Error>?
            try OwnedExportJobs.submitStencil(definitions:[definition],input:input,sourceURL:nil,destination:output,owner:owner) {
                outcome = $0;finished = true
            }
            fragment.nodes[0].text = "Newer selection"
            try pump(until:{finished})
            XCTAssertEqual(try XCTUnwrap(outcome).get().input,input)
            XCTAssertEqual(definition.fragment.nodes[0].id,originalID)
            XCTAssertEqual(definition.fragment.nodes[0].text,"Captured master")
            let imported = try VisioStencil.read(from:output)
            XCTAssertEqual(imported.items.first?.name,"Selected master")
            XCTAssertEqual(imported.items.first?.fragment.nodes.first?.text,"Captured master")
            XCTAssertNil(try VisioPackage.read(output)["macvisio/document.json"])
        }
    }

    private func fixture(count:Int) -> Diagram {
        var diagram = Diagram();diagram.page.width = 600;diagram.page.height = 400
        diagram.page.nodes = (0..<count).map { index in
            var node = DiagramNode(x:Double(index%10)*50,y:Double(index/10)*35,text:"Export shape \(index)")
            node.width = 45;node.height = 30
            return node
        }
        return diagram
    }

    private func export(_ diagram:Diagram,to url:URL,format:OwnedExportFormat,allPages:Bool = false,
                        owner:LifecycleJobOwner,source:URL? = nil) throws -> OwnedExportResult {
        let input = LifecycleJobInput(ownerID:owner.id,snapshotID:UUID(),revision:1)
        var finished = false
        var outcome:Result<OwnedExportResult,Error>?
        try OwnedExportJobs.submit(snapshot:diagram,input:input,sourceURL:source,destination:url,format:format,allPages:allPages,owner:owner) {
            outcome = $0;finished = true
        }
        try pump(until:{finished})
        return try XCTUnwrap(outcome).get()
    }

    private func pump(until complete:()->Bool) throws {
        let deadline = Date().addingTimeInterval(30)
        while !complete() && Date() < deadline { _ = RunLoop.main.run(mode:.default,before:Date().addingTimeInterval(0.01)) }
        guard complete() else { throw DiagramError.invalid("Owned export completion timed out") }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M1-export-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        addTeardownBlock { try? FileManager.default.removeItem(at:directory) }
        return directory
    }

    private func onMain<T>(_ body:() throws ->T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute:body)
    }
}
