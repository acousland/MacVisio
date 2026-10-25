import AppKit

/// The own geometry of a one-dimensional shape that is not a plain polyline (arcs, callouts, braces),
/// drawn as Visio draws it. Its paths are kept, normalized like a shape's, in the frame its imported
/// Pin, LocPin, Width, Height and Angle cells describe. When the endpoints are moved, the frame
/// follows them: it is carried with the begin point and stretched along the begin-end axis, as
/// Width formulas tied to the shape's length do in Visio.
enum OneDimensionalGeometry {
    struct Frame {
        let width: Double, height: Double, pinX: Double, pinY: Double, locPinX: Double, locPinY: Double
        let angle: Double, flipX: Bool, flipY: Bool, pageHeight: Double
        let begin: CGPoint, end: CGPoint
        let currentBegin: CGPoint, currentEnd: CGPoint

        /// A point in the shape's local coordinates (inches, y up) on the page (points, y down).
        func point(local x: Double, _ y: Double) -> CGPoint {
            let dx = (x - locPinX) * (flipX ? -1 : 1), dy = (y - locPinY) * (flipY ? -1 : 1)
            let imported = CGPoint(x: (pinX + dx * cos(angle) - dy * sin(angle)) * 72,
                                   y: pageHeight - (pinY + dx * sin(angle) + dy * cos(angle)) * 72)
            return follow(imported)
        }

        /// A point of a normalized path (0...1, y down) on the page.
        func point(normalized u: Double, _ v: Double) -> CGPoint { point(local: u * width, (1 - v) * height) }

        private func follow(_ p: CGPoint) -> CGPoint {
            let moved = hypot(currentBegin.x - begin.x, currentBegin.y - begin.y) > 1e-6 || hypot(currentEnd.x - end.x, currentEnd.y - end.y) > 1e-6
            guard moved else { return p }
            let before = hypot(end.x - begin.x, end.y - begin.y), after = hypot(currentEnd.x - currentBegin.x, currentEnd.y - currentBegin.y)
            guard before > 1e-6, after > 1e-6 else { return CGPoint(x: p.x + currentBegin.x - begin.x, y: p.y + currentBegin.y - begin.y) }
            let d0 = CGPoint(x: (end.x - begin.x) / before, y: (end.y - begin.y) / before), n0 = CGPoint(x: d0.y, y: -d0.x)
            let d1 = CGPoint(x: (currentEnd.x - currentBegin.x) / after, y: (currentEnd.y - currentBegin.y) / after), n1 = CGPoint(x: d1.y, y: -d1.x)
            let r = CGPoint(x: p.x - begin.x, y: p.y - begin.y)
            let s = (r.x * d0.x + r.y * d0.y) * after / before, t = r.x * n0.x + r.y * n0.y
            return CGPoint(x: currentBegin.x + s * d1.x + t * n1.x, y: currentBegin.y + s * d1.y + t * n1.y)
        }
    }

    /// Whether imported geometry needs this path rather than a polyline route.
    static func needsOwnGeometry(_ paths: [VectorPath]) -> Bool {
        paths.count > 1 || paths.contains { path in path.commands.contains { !["M", "L", "Z"].contains($0.kind) } }
    }

    static func frame(_ edge: DiagramEdge, route: [CGPoint], pageHeight: Double) -> Frame? {
        let sheet = edge.formatting.sheet
        guard edge.parentID == nil, !edge.formatting.paths.isEmpty, let first = route.first, let last = route.last else { return nil }
        func value(_ name: String) -> Double? { sheet[name].flatMap { Double($0.value) }.flatMap { $0.isFinite ? $0 : nil } }
        guard let beginX = value("BeginX"), let beginY = value("BeginY"), let endX = value("EndX"), let endY = value("EndY") else { return nil }
        let width = abs(value("Width") ?? 1), height = abs(value("Height") ?? 0)
        return Frame(width: width, height: height, pinX: value("PinX") ?? (beginX + endX) / 2, pinY: value("PinY") ?? (beginY + endY) / 2,
                     locPinX: value("LocPinX") ?? width / 2, locPinY: value("LocPinY") ?? height / 2, angle: value("Angle") ?? 0,
                     flipX: value("FlipX") == 1, flipY: value("FlipY") == 1, pageHeight: pageHeight,
                     begin: CGPoint(x: beginX * 72, y: pageHeight - beginY * 72), end: CGPoint(x: endX * 72, y: pageHeight - endY * 72),
                     currentBegin: first, currentEnd: last)
    }

    static func bezierPaths(_ edge: DiagramEdge, frame: Frame) -> [(path: NSBezierPath, vector: VectorPath)] {
        edge.formatting.paths.map { vector in
            let path = NSBezierPath()
            for command in vector.commands {
                let v = command.values
                switch command.kind {
                case "M": path.move(to: frame.point(normalized: v[0], v[1]))
                case "L": path.line(to: frame.point(normalized: v[0], v[1]))
                case "C": path.curve(to: frame.point(normalized: v[4], v[5]), controlPoint1: frame.point(normalized: v[0], v[1]), controlPoint2: frame.point(normalized: v[2], v[3]))
                case "Z": path.close()
                default: break
                }
            }
            return (path, vector)
        }
    }

    /// Where the shape's text block is centered: its text pin, as Visio places it.
    static func textCenter(_ edge: DiagramEdge, frame: Frame) -> CGPoint? {
        let sheet = edge.formatting.sheet
        guard let x = sheet["TxtPinX"].flatMap({ Double($0.value) }), let y = sheet["TxtPinY"].flatMap({ Double($0.value) }) else { return nil }
        let width = sheet["TxtWidth"].flatMap { Double($0.value) } ?? frame.width, height = sheet["TxtHeight"].flatMap { Double($0.value) } ?? frame.height
        let locX = sheet["TxtLocPinX"].flatMap { Double($0.value) } ?? width / 2, locY = sheet["TxtLocPinY"].flatMap { Double($0.value) } ?? height / 2
        let angle = sheet["TxtAngle"].flatMap { Double($0.value) } ?? 0, dx = width / 2 - locX, dy = height / 2 - locY
        return frame.point(local: x + dx * cos(angle) - dy * sin(angle), y + dx * sin(angle) + dy * cos(angle))
    }

    static func fillColor(_ edge: DiagramEdge) -> NSColor {
        guard let value = edge.formatting.sheet["FillForegnd"]?.value, value.hasPrefix("#") else { return .white }
        return NSColor(hex: value)
    }
}
