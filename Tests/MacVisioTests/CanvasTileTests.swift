import AppKit
import XCTest
@testable import MacVisio

final class CanvasTileTests: XCTestCase {
    func testTilesRenderOnlyInvalidatedAreasAndEvictDistantTiles() {
        let cache = CanvasTileCache(), host = CALayer()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let bounds = CGRect(x: 0, y: 0, width: 4096, height: 4096)
        var rendered: [CGRect] = []
        let visible = CGRect(x: 0, y: 0, width: 600, height: 400)
        cache.update(visible: visible, bounds: bounds, scale: 2, colorSpace: space, host: host) { rendered.append($0) }
        XCTAssertEqual(rendered.count, cache.count, "Every new tile renders once")
        XCTAssertTrue(rendered.allSatisfy { $0.width == CanvasTileCache.tileSize && $0.height == CanvasTileCache.tileSize })

        rendered.removeAll()
        cache.update(visible: visible, bounds: bounds, scale: 2, colorSpace: space, host: host) { rendered.append($0) }
        XCTAssertTrue(rendered.isEmpty, "Unchanged tiles are not redrawn")

        let damage = CGRect(x: 300, y: 100, width: 20, height: 20)
        cache.invalidate(damage)
        cache.update(visible: visible, bounds: bounds, scale: 2, colorSpace: space, host: host) { rendered.append($0) }
        XCTAssertEqual(rendered, [damage], "Only the invalidated part of the affected tile is redrawn")

        cache.update(visible: CGRect(x: 3000, y: 3000, width: 600, height: 400), bounds: bounds, scale: 2, colorSpace: space, host: host) { _ in }
        XCTAssertFalse(host.sublayers?.contains { $0.frame.minX < 1000 } ?? false, "Tiles far from the viewport are evicted")
    }

    func testSnapshotDrawingStillRendersCanvasContent() throws {
        _ = NSApplication.shared
        let document = MacVisioDocument()
        var node = DiagramNode(text: "Snapshot")
        node.x = 40; node.y = 40; node.width = 200; node.height = 120; node.fill = "#FF0000"
        document.diagram.page.nodes = [node]
        document.makeWindowControllers()
        let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
        defer { editor.close() }
        editor.window?.contentView?.layoutSubtreeIfNeeded()
        editor.canvas.fitPage()
        let canvas = editor.canvas
        let image = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: image)
        let redPixels = (0..<image.pixelsHigh).lazy.flatMap { y in (0..<image.pixelsWide).lazy.map { x in (x, y) } }
            .filter { x, y in
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                // Device RGB depends on the display profile (#FF0000 reads as about 233,51,36 on some displays).
                return color.redComponent > 0.8 && color.greenComponent < 0.35 && color.blueComponent < 0.35
            }
        XCTAssertNotNil(redPixels.first, "cacheDisplay must still draw shapes through draw(_:)")
    }
}
