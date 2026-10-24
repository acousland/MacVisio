import AppKit
import QuartzCore

/// Layer-hosting backdrop that shows the canvas's rendered content as fixed-size tile layers.
/// Scrolling moves already-rendered tiles; only tiles entering the prepared area and areas the canvas
/// invalidates are rendered. It never receives events.
final class CanvasTileView: NSView {
    private let container = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        container.actions = ["sublayers": NSNull(), "bounds": NSNull(), "position": NSNull()]
        layer = container
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    var tileLayer: CALayer { container }
}

/// Fixed-size tiles of canvas content, each with its own bitmap so an invalidated part of a tile is
/// redrawn in place. Tiles cover the visible area plus a small margin; others are evicted.
final class CanvasTileCache {
    static let tileSize: CGFloat = 256
    private struct Key: Hashable { let column: Int, row: Int }
    private final class Tile {
        let layer = CALayer()
        let context: CGContext
        var dirty: CGRect?
        init(context: CGContext) { self.context = context }
    }

    private var tiles: [Key: Tile] = [:]
    private var scale: CGFloat = 0
    private var colorSpace: CGColorSpace?

    var count: Int { tiles.count }

    /// Marks the parts of existing tiles that intersect `rect` (view coordinates) for redrawing.
    func invalidate(_ rect: CGRect) {
        guard !rect.isNull, !rect.isEmpty else { return }
        for (key, tile) in tiles {
            let area = Self.rect(for: key).intersection(rect)
            guard !area.isNull, !area.isEmpty else { continue }
            tile.dirty = tile.dirty.map { $0.union(area) } ?? area
        }
    }

    /// Discards every tile, for size, zoom, scale and colour-space changes.
    func removeAll() {
        tiles.values.forEach { $0.layer.removeFromSuperlayer() }
        tiles.removeAll()
    }

    /// Creates, redraws and evicts tiles so the prepared area around `visible` is current.
    /// `render` draws canvas content for a view rect into the current graphics context.
    func update(visible: CGRect, bounds: CGRect, scale: CGFloat, colorSpace: CGColorSpace, host: CALayer,
               render: (CGRect) -> Void) {
        guard !visible.isEmpty, scale > 0 else { return }
        if scale != self.scale || colorSpace != self.colorSpace { removeAll(); self.scale = scale; self.colorSpace = colorSpace }
        let size = Self.tileSize
        let prepared = visible.insetBy(dx: -size / 2, dy: -size / 2).intersection(bounds)
        let keep = visible.insetBy(dx: -size * 2, dy: -size * 2)
        for (key, tile) in tiles where !Self.rect(for: key).intersects(keep) {
            tile.layer.removeFromSuperlayer(); tiles[key] = nil
        }
        guard !prepared.isNull, !prepared.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for column in Int(floor(prepared.minX / size))...Int(floor((prepared.maxX - 0.001) / size)) {
            for row in Int(floor(prepared.minY / size))...Int(floor((prepared.maxY - 0.001) / size)) {
                let key = Key(column: column, row: row), area = Self.rect(for: key)
                let tile: Tile
                if let existing = tiles[key] {
                    tile = existing
                } else {
                    let pixels = Int((size * scale).rounded())
                    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                                      | CGBitmapInfo.byteOrder32Little.rawValue)
                    else { continue }
                    // View coordinates are flipped: map the tile's top-left to the bitmap's top-left.
                    context.translateBy(x: 0, y: CGFloat(pixels))
                    context.scaleBy(x: scale, y: -scale)
                    context.translateBy(x: -area.minX, y: -area.minY)
                    tile = Tile(context: context)
                    tile.dirty = area
                    tile.layer.anchorPoint = .zero
                    tile.layer.contentsScale = scale
                    tile.layer.isOpaque = true
                    host.addSublayer(tile.layer)
                    tiles[key] = tile
                }
                // AppKit gives the flipped host view a geometry-flipped layer, so tiles use view coordinates.
                tile.layer.frame = area
                guard let dirty = tile.dirty else { continue }
                tile.dirty = nil
                let context = tile.context
                context.saveGState()
                context.clip(to: dirty)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                render(dirty)
                NSGraphicsContext.restoreGraphicsState()
                context.restoreGState()
                tile.layer.contents = context.makeImage()
            }
        }
    }

    private static func rect(for key: Key) -> CGRect {
        CGRect(x: CGFloat(key.column) * tileSize, y: CGFloat(key.row) * tileSize, width: tileSize, height: tileSize)
    }
}
