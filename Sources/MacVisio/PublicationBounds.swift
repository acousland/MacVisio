import AppKit

/// Publication paint geometry only: no handles, snapping padding, guides,
/// selection halos or screen shadow. The final viewport adds a one-pixel guard.
/// Rotated path rectangles are conservative and may include unpainted corners.
enum PublicationBounds {
    static func node(_ node: DiagramNode, prepared: PreparedNodeDrawing, paperScale: Double) throws -> CGRect {
        precondition(Thread.isMainThread)
        var shape = CGRect.null
        let stroke = node.strokeWidth / paperScale / 2
        func add(_ path: NSBezierPath, fill: Bool, line: Bool) {
            guard !path.isEmpty, fill || line else { return }
            let rect = line ? path.bounds.insetBy(dx: -stroke, dy: -stroke) : path.bounds
            shape = shape.union(rect)
        }
        let fillVisible = NSColor(hex: node.fill).alphaComponent > 0
        let lineVisible = NSColor(hex: node.stroke).alphaComponent > 0
        if let image = node.formatting.image {
            guard (try? NativeImageDecoding.decode(data: image.data, mimeType: image.mimeType)) != nil else {
                throw DiagramError.invalid("Cropped PNG bounds require a supported image. Use Page bounds to include an image preview placeholder.")
            }
            shape = node.rect
        }
        else if !node.formatting.paths.isEmpty {
            for (index, path) in prepared.vectors.enumerated() {
                let style = node.formatting.paths[index]
                add(path, fill: style.fill && fillVisible, line: style.stroke && lineVisible)
            }
        } else {
            add(prepared.outline, fill: !node.formatting.isGroup && fillVisible, line: !node.formatting.isGroup && lineVisible)
            if node.kind == .cylinder, node.formatting.geometry == nil, lineVisible {
                shape = shape.union(CGRect(x: node.x, y: node.y, width: node.width, height: node.height * 0.26)
                    .insetBy(dx: -stroke, dy: -stroke))
            }
        }
        var result = physical(transform(shape, around: node.center, rotation: node.rotation,
                                        flipX: node.formatting.flipX, flipY: node.formatting.flipY), scale: paperScale)
        if hasVisibleText(prepared.text), !DiagramDrawing.isTextHidden(for: node) {
            let text = textBounds(prepared.text, in: prepared.textRect)
            let block = transform(text, around: prepared.textCenter, rotation: prepared.textRotation)
            let center = CGPoint(x: node.center.x * paperScale, y: node.center.y * paperScale)
            result = result.union(transform(block, around: center, rotation: node.rotation))
        }
        return result
    }

    static func edge(_ edge: DiagramEdge, route: [CGPoint], label: PreparedEdgeLabel?, paperScale: Double) -> CGRect {
        precondition(Thread.isMainThread)
        guard let first = route.first, let last = route.last else { return .null }
        var result = CGRect.null
        if NSColor(hex: edge.color).alphaComponent > 0 {
            result = route.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
                .insetBy(dx: -edge.width / paperScale / 2, dy: -edge.width / paperScale / 2)
            func arrow(_ tip: CGPoint, toward previous: CGPoint) {
                let angle = atan2(tip.y - previous.y, tip.x - previous.x), size = (8 + edge.width) / paperScale
                for point in [tip, CGPoint(x: tip.x - size * cos(angle - 0.4), y: tip.y - size * sin(angle - 0.4)),
                              CGPoint(x: tip.x - size * cos(angle + 0.4), y: tip.y - size * sin(angle + 0.4))] {
                    result = result.union(CGRect(origin: point, size: .zero))
                }
            }
            if edge.arrow, let previous = route.dropLast().last(where: { hypot($0.x - last.x, $0.y - last.y) > 0.5 }) {
                arrow(last, toward: previous)
            }
            if edge.startArrow == true, let next = route.dropFirst().first(where: { hypot($0.x - first.x, $0.y - first.y) > 0.5 }) {
                arrow(first, toward: next)
            }
        }
        result = physical(result, scale: paperScale)
        if let label, !edge.label.isEmpty {
            let mid = route.count > 2 ? CGPoint(x: (route[1].x + route[2].x) / 2, y: (route[1].y + route[2].y) / 2)
                : CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2)
            let origin = CGPoint(x:mid.x*paperScale-label.size.width/2,y:mid.y*paperScale-label.size.height/2)
            result = result.union(CGRect(origin:origin,size:label.size).insetBy(dx:-5,dy:-3))
            result = result.union(label.paintBounds.offsetBy(dx:origin.x,dy:origin.y))
        }
        return result
    }

    static func offset(_ bounds: CGRect, by offset: CGPoint) -> CGRect {
        bounds.isNull ? .null : bounds.offsetBy(dx: offset.x, dy: offset.y)
    }

    private static func hasVisibleText(_ text: NSAttributedString) -> Bool {
        var visible = false
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            guard (attributes[.foregroundColor] as? NSColor)?.alphaComponent != 0 else { return }
            let value = (text.string as NSString).substring(with: range)
            if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (attributes[.underlineStyle] as? Int ?? 0) != 0
                || (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { visible = true }
        }
        return visible
    }

    static func textBounds(_ text: NSAttributedString, in rect: CGRect) -> CGRect {
        guard text.length > 0, rect.width > 0, rect.height > 0 else { return .null }
        let storage = NSTextStorage(attributedString: text), manager = NSLayoutManager()
        let container = NSTextContainer(containerSize: CGSize(width: max(1, rect.width), height: max(1, rect.height)))
        container.lineFragmentPadding = 0
        manager.usesFontLeading = true
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(for: container)
        let ink = manager.boundingRect(forGlyphRange: glyphs, in: container)
            .offsetBy(dx: rect.minX, dy: rect.minY)
        // Keep the actual draw rectangle as a conservative envelope; union glyph
        // extents for italic overhang/paragraph indents and rich-text decoration.
        var decoration: CGFloat = 0
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let font = value as? NSFont { decoration = max(decoration, font.underlineThickness) }
        }
        return rect.union(ink).insetBy(dx: -decoration, dy: -decoration)
    }

    private static func physical(_ rect: CGRect, scale: Double) -> CGRect {
        guard !rect.isNull else { return .null }
        return CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
    }

    private static func transform(_ rect: CGRect, around center: CGPoint, rotation: Double,
                                  flipX: Bool = false, flipY: Bool = false) -> CGRect {
        guard !rect.isNull else { return .null }
        let angle = rotation * .pi / 180, c = cos(angle), s = sin(angle)
        return [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.minX, y: rect.maxY),
                CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY)].reduce(CGRect.null) { result, point in
            let x = (point.x - center.x) * (flipX ? -1 : 1), y = (point.y - center.y) * (flipY ? -1 : 1)
            let p = CGPoint(x: center.x + x * c - y * s, y: center.y + x * s + y * c)
            return result.union(CGRect(origin: p, size: .zero))
        }
    }
}
