import AppKit
import PDFKit
import XCTest
@testable import MacVisio

final class EditorTests: XCTestCase {
    func testInsertShapeSnapsToGridAndSelectsTheNewShape() throws {
        try withEditor { document, editor in
            edit(document) { editor.insertShape(.diamond, at: CGPoint(x: 237, y: 183)) }
            let node = try XCTUnwrap(document.diagram.page.nodes.first)
            XCTAssertEqual(node.kind, .diamond)
            XCTAssertEqual(node.x, 240)
            XCTAssertEqual(node.y, 180)
            XCTAssertEqual(node.width, ShapeKind.diamond.defaultSize.width)
            XCTAssertEqual(node.height, ShapeKind.diamond.defaultSize.height)
            XCTAssertEqual(editor.canvas.selectedNodes, Set([node.id]))
            XCTAssertEqual(editor.selection, [node])
            XCTAssertEqual(editor.canvas.tool, .pointer)
            XCTAssertEqual(try document.diagram.validated(), document.diagram)
        }
    }

    func testMovementAndFormattingUndoAndRedoRestoreCompleteState() throws {
        try withEditor { document, editor in
            edit(document) { editor.insertShape(.rectangle, at: CGPoint(x: 100, y: 100)) }
            document.undoManager?.removeAllActions()
            let original = document.diagram
            edit(document) {
                editor.modifySelection("Move Shape") { $0.x = 340; $0.y = 290 }
            }
            let moved = document.diagram
            edit(document) {
                editor.modifySelection("Format Shape") {
                    $0.fill = "#FCEBED"; $0.stroke = "#BE6977"; $0.textColor = "#743744"
                    $0.fontSize = 21; $0.bold = true; $0.rotation = 15; $0.text = "Review & approve"
                }
            }
            let formatted = document.diagram
            XCTAssertEqual(formatted.page.nodes[0].x, 340)
            XCTAssertEqual(formatted.page.nodes[0].fill, "#FCEBED")
            XCTAssertTrue(document.undoManager?.canUndo == true)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram, moved)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram, original)
            document.undoManager?.redo()
            XCTAssertEqual(document.diagram, moved)
            document.undoManager?.redo()
            XCTAssertEqual(document.diagram, formatted)
        }
    }

    func testDuplicatingConnectedSelectionCreatesIndependentIdentifiers() throws {
        try withEditor(connectedDiagram()) { document, editor in
            let original = document.diagram.page
            let originalIDs = Set(original.nodes.map(\.id))
            editor.canvas.select(originalIDs)
            edit(document) { editor.duplicateSelection(nil) }
            let page = document.diagram.page
            let duplicates = page.nodes.filter { !originalIDs.contains($0.id) }
            let duplicateIDs = Set(duplicates.map(\.id))
            XCTAssertEqual(page.nodes.count, 4)
            XCTAssertEqual(duplicates.count, 2)
            XCTAssertEqual(page.edges.count, 2)
            XCTAssertEqual(editor.canvas.selectedNodes, duplicateIDs)
            XCTAssertTrue(originalIDs.isDisjoint(with: duplicateIDs))
            let copiedEdge = try XCTUnwrap(page.edges.first { $0.id != original.edges[0].id })
            XCTAssertTrue(duplicateIDs.contains(copiedEdge.source))
            XCTAssertTrue(duplicateIDs.contains(copiedEdge.target))
            XCTAssertEqual(copiedEdge.label, original.edges[0].label)
            for duplicate in duplicates {
                let source = try XCTUnwrap(original.nodes.first { $0.text == duplicate.text })
                XCTAssertEqual(duplicate.x, source.x + 20)
                XCTAssertEqual(duplicate.y, source.y + 20)
            }
            XCTAssertEqual(try document.diagram.validated(), document.diagram)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram.page, original)
            document.undoManager?.redo()
            XCTAssertEqual(document.diagram.page, page)
        }
    }

    func testDeletingShapeRemovesItsConnectorsAndUndoRestoresThem() throws {
        try withEditor(connectedDiagram()) { document, editor in
            let original = document.diagram
            editor.canvas.select(Set([original.page.nodes[0].id]))
            edit(document) { editor.deleteSelection(nil) }
            XCTAssertEqual(document.diagram.page.nodes.count, 1)
            XCTAssertTrue(document.diagram.page.edges.isEmpty)
            XCTAssertTrue(editor.canvas.selectedNodes.isEmpty)
            XCTAssertEqual(try document.diagram.validated(), document.diagram)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram, original)
            document.undoManager?.redo()
            XCTAssertEqual(document.diagram.page.nodes.count, 1)
            XCTAssertTrue(document.diagram.page.edges.isEmpty)
        }
    }

    func testLockedShapeResistsModificationAndDeletionUntilUnlocked() throws {
        var diagram = connectedDiagram()
        diagram.page.nodes[0].locked = true
        try withEditor(diagram) { document, editor in
            let locked = document.diagram.page.nodes[0]
            editor.canvas.select(Set([locked.id]))
            edit(document) {
                editor.modifySelection("Move Locked Shape") { $0.x = 999; $0.fill = "#000000" }
            }
            XCTAssertEqual(document.diagram, diagram)
            edit(document) { editor.deleteSelection(nil) }
            XCTAssertEqual(document.diagram, diagram)
            document.undoManager?.removeAllActions()
            editor.canvas.select(Set([locked.id]))
            edit(document) { editor.toggleLock(nil) }
            XCTAssertFalse(document.diagram.page.nodes[0].locked)
            edit(document) { editor.deleteSelection(nil) }
            XCTAssertEqual(document.diagram.page.nodes.count, 1)
            XCTAssertTrue(document.diagram.page.edges.isEmpty)
        }
    }

    func testPageAdditionDuplicationUndoAndSwitchingPreserveContents() throws {
        try withEditor(connectedDiagram()) { document, editor in
            let original = document.diagram
            edit(document) { editor.addPage(nil) }
            let added = document.diagram
            XCTAssertEqual(added.pages.count, 2)
            XCTAssertEqual(added.activePageIndex, 1)
            XCTAssertTrue(added.page.nodes.isEmpty)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram, original)
            document.undoManager?.redo()
            XCTAssertEqual(document.diagram, added)

            editor.switchPage(original.page.id)
            XCTAssertEqual(document.diagram.page, original.page)
            editor.canvas.select(Set(original.page.nodes.map(\.id)))
            edit(document) { editor.duplicatePage(nil) }
            let duplicated = document.diagram
            XCTAssertEqual(duplicated.pages.count, 3)
            XCTAssertNotEqual(duplicated.page.id, original.page.id)
            XCTAssertEqual(duplicated.page.name, original.page.name + " Copy")
            XCTAssertEqual(duplicated.page.nodes, original.page.nodes)
            XCTAssertEqual(duplicated.page.edges, original.page.edges)
            XCTAssertTrue(editor.canvas.selectedNodes.isEmpty)
            XCTAssertEqual(try duplicated.validated(), duplicated)
            document.undoManager?.undo()
            XCTAssertEqual(document.diagram.pages.count, 2)
            XCTAssertEqual(document.diagram.page, original.page)
            document.undoManager?.redo()
            XCTAssertEqual(document.diagram, duplicated)
            editor.switchPage(added.page.id)
            XCTAssertEqual(document.diagram.page.id, added.page.id)
            XCTAssertTrue(document.diagram.page.nodes.isEmpty)
            editor.switchPage(original.page.id)
            XCTAssertEqual(document.diagram.page, original.page)
        }
    }

    func testNativeDocumentWritesAndReloadsActualFile() throws {
        try withEditor(DiagramTemplate.flowchart.makeDiagram()) { document, editor in
            let saveTarget = editor.supplementalTarget(forAction: #selector(NSDocument.save(_:)), sender: nil) as? MacVisioDocument
            XCTAssertTrue(saveTarget === document, "The editor must route Save to its own document")
            let id = try XCTUnwrap(document.diagram.page.nodes.first?.id)
            editor.canvas.select(Set([id]))
            edit(document) {
                editor.modifySelection("Edit Text") { $0.text = "Approval: café → 東京"; $0.bold = true }
            }
            edit(document) { editor.addPage(nil) }
            edit(document) { editor.insertShape(.cylinder, at: CGPoint(x: 300, y: 250)) }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisioEditorTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("Native document.macvisio")
            try document.write(to: url, ofType: MacVisioDocument.nativeType)
            let data = try Data(contentsOf: url)
            XCTAssertFalse(data.isEmpty)
            XCTAssertEqual(try JSONDecoder().decode(Diagram.self, from: data), document.diagram)
            let reopened = MacVisioDocument()
            try reopened.read(from: url, ofType: MacVisioDocument.nativeType)
            XCTAssertEqual(reopened.diagram, document.diagram)
            XCTAssertEqual(reopened.diagram.activePageID, document.diagram.activePageID)
            XCTAssertEqual(reopened.diagram.pages.count, 2)
        }
    }

    func testPDFExportContainsOnePageAtDocumentDimensions() throws {
        try onMain {
            _ = NSApplication.shared
            let page = asymmetricPage()
            let data = DiagramExport.pdf(page)
            XCTAssertGreaterThan(data.count, 500)
            XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "%PDF")
            let pdf = try XCTUnwrap(PDFDocument(data: data))
            XCTAssertEqual(pdf.pageCount, 1)
            let bounds = try XCTUnwrap(pdf.page(at: 0)).bounds(for: .mediaBox)
            XCTAssertEqual(bounds.width, page.width, accuracy: 0.01)
            XCTAssertEqual(bounds.height, page.height, accuracy: 0.01)
        }
    }

    func testPNGExportKeepsTopLeftOriginAndAsymmetricShapeOrientation() throws {
        try onMain {
            _ = NSApplication.shared
            let page = asymmetricPage()
            let data = try DiagramExport.png(page, scale: 2)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertEqual(bitmap.pixelsWide, 640)
            XCTAssertEqual(bitmap.pixelsHigh, 480)
            let inside = try XCTUnwrap(bitmap.colorAt(x: 180, y: 160)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(inside.redComponent, 0.9)
            XCTAssertLessThan(inside.greenComponent, 0.15)
            XCTAssertLessThan(inside.blueComponent, 0.15)
            // The triangle widens toward its bottom in page coordinates.
            assertWhite(bitmap, x: 80, y: 60)
            let lowerWing = try XCTUnwrap(bitmap.colorAt(x: 80, y: 220)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(lowerWing.redComponent, 0.9)
            XCTAssertLessThan(lowerWing.greenComponent, 0.15)
            // A vertical flip would put the red triangle at this lower sample.
            assertWhite(bitmap, x: 180, y: 320)
        }
    }

    func testSVGExportParsesAndEscapesShapeTextConnectorLabelAndPageName() {
        onMain {
            _ = NSApplication.shared
            var page = connectedDiagram().page
            page.name = "Design & Review <v2>"
            page.nodes[0].text = "A & B < C > D \"quoted\""
            page.nodes[0].width = 300
            page.edges[0].label = "Yes & <ready> \"now\""
            let svg = DiagramDrawing.svg(page)
            XCTAssertTrue(svg.contains("&amp;"))
            XCTAssertTrue(svg.contains("&lt;ready&gt;"))
            XCTAssertTrue(svg.contains("&quot;now&quot;"))
            let collector = SVGCollector()
            let parser = XMLParser(data: Data(svg.utf8))
            parser.delegate = collector
            XCTAssertTrue(parser.parse(), parser.parserError?.localizedDescription ?? "Invalid SVG XML")
            XCTAssertEqual(collector.rootName, "svg")
            XCTAssertEqual(Double(collector.rootAttributes["width"] ?? ""), page.width)
            XCTAssertEqual(Double(collector.rootAttributes["height"] ?? ""), page.height)
            XCTAssertGreaterThanOrEqual(collector.pathCount, 3)
            XCTAssertTrue(collector.text.contains(page.name))
            XCTAssertTrue(collector.text.contains("A & B < C > D \"quoted\""))
            XCTAssertTrue(collector.text.contains(page.edges[0].label))
        }
    }

    private func connectedDiagram() -> Diagram {
        var diagram = Diagram()
        diagram.title = "Editor test diagram"
        let source = DiagramNode(x: 100, y: 100, text: "Source")
        let target = DiagramNode(x: 500, y: 320, text: "Target")
        diagram.page.nodes = [source, target]
        diagram.page.edges = [DiagramEdge(source: source.id, target: target.id, label: "Continue")]
        return diagram
    }

    private func asymmetricPage() -> DiagramPage {
        var triangle = DiagramNode(kind: .triangle, x: 30, y: 20, text: "")
        triangle.width = 120; triangle.height = 100
        triangle.fill = "#FF0000"; triangle.stroke = "#FF0000"; triangle.strokeWidth = 0
        return DiagramPage(name: "Asymmetric", width: 320, height: 240, nodes: [triangle])
    }

    private func assertWhite(_ bitmap: NSBitmapImageRep, x: Int, y: Int, file: StaticString = #filePath, line: UInt = #line) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
            XCTFail("Could not sample PNG pixel", file: file, line: line)
            return
        }
        XCTAssertGreaterThan(color.redComponent, 0.95, file: file, line: line)
        XCTAssertGreaterThan(color.greenComponent, 0.95, file: file, line: line)
        XCTAssertGreaterThan(color.blueComponent, 0.95, file: file, line: line)
    }

    private func edit(_ document: MacVisioDocument, _ body: () -> Void) {
        document.undoManager?.beginUndoGrouping()
        body()
        document.undoManager?.endUndoGrouping()
    }

    private func withEditor(_ diagram: Diagram = Diagram(), _ body: (MacVisioDocument, EditorWindowController) throws -> Void) throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument()
            document.diagram = diagram
            document.makeWindowControllers()
            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController, "Controllers: \(document.windowControllers.map { NSStringFromClass(type(of: $0)) })")
            document.undoManager?.groupsByEvent = false
            document.undoManager?.removeAllActions()
            defer {
                editor.window?.orderOut(nil)
                editor.window?.delegate = nil
                document.removeWindowController(editor)
                editor.close()
            }
            try body(document, editor)
        }
    }

    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}

private final class SVGCollector: NSObject, XMLParserDelegate {
    var rootName: String?
    var rootAttributes: [String: String] = [:]
    var pathCount = 0
    var text = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if rootName == nil { rootName = elementName; rootAttributes = attributeDict }
        if elementName == "path" { pathCount += 1 }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
}
