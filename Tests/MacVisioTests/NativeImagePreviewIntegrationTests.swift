import AppKit
import XCTest
@testable import MacVisio

final class NativeImagePreviewIntegrationTests: XCTestCase {
    func testNativeReadExposesPreservedVectorPreviewLimitationAndRenderingDoesNotDecodeIt() throws {
        _ = NSApplication.shared
        let document = MacVisioDocument(), other = MacVisioDocument()
        defer { document.close(); other.close() }
        var diagram = Diagram(); diagram.page.width = 200; diagram.page.height = 100
        var node = DiagramNode(x: 10, y: 10, text: "")
        let bytes = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><script>throw 1</script><image href=\"https://127.0.0.1:1/never\"/></svg>".utf8)
        node.formatting.image = EmbeddedImage(data: bytes, mimeType: "image/svg+xml")
        diagram.page.nodes = [node]
        try document.read(from: JSONEncoder().encode(diagram), ofType: MacVisioDocument.nativeType)
        let record = try XCTUnwrap(document.currentDiagnostics.first { $0.code == "image.preview-unavailable" })
        XCTAssertEqual(record.target, .shape(page: diagram.page.id, shape: node.id))
        XCTAssertEqual(record.displayState, .unavailable); XCTAssertEqual(record.inputKey, document.diagnosticInputKey)
        DiagramDrawing.clearImageCache()
        XCTAssertFalse(try DiagramExport.png(document.diagram.page, scale: 1).isEmpty)
        XCTAssertEqual(DiagramDrawing.imageCacheStatistics.count, 0)
        XCTAssertEqual(document.diagram.page.nodes[0].formatting.image?.data, bytes)
        XCTAssertTrue(other.currentDiagnostics.isEmpty)
    }

    func testInsertedRasterUsesBoundedDecoderAndHasIndependentUndo() throws {
        _ = NSApplication.shared
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 8, bitsPerPixel: 32))
        memset(try XCTUnwrap(bitmap.bitmapData), 0xFF, 16)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let document = MacVisioDocument(); defer { document.close() }
        document.undoManager?.groupsByEvent = false; document.makeWindowControllers()
        let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
        try editor.insertImage(data: png)
        XCTAssertEqual(document.diagram.page.nodes.count, 1)
        XCTAssertEqual(document.diagram.page.nodes[0].formatting.image?.mimeType, "image/png")
        XCTAssertThrowsError(try editor.insertImage(data: Data("%PDF-1.4".utf8)))
        XCTAssertEqual(document.diagram.page.nodes.count, 1)
        document.undoManager?.undo(); XCTAssertTrue(document.diagram.page.nodes.isEmpty)
    }
}
