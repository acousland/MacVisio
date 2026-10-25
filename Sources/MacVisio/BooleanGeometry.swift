import AppKit
import MacVisioInfrastructure

/// A deliberately bounded surface operation. Authored behavior is never
/// converted into a cached outline merely to make an operation possible.
enum BooleanGeometry {
    enum Operation: Equatable {
        case union, intersect, subtract(baseID: UUID)
        var title: String { switch self { case .union: return "Union"; case .intersect: return "Intersect"; case .subtract: return "Subtract" } }
    }
    static let maximumShapes = 32
    static let maximumInputCommands = 2048
    static let maximumOutputCommands = 8192

    private static let sheetCells: Set<String> = [
        "PinX", "PinY", "Width", "Height", "LocPinX", "LocPinY", "Angle",
        "LineWeight", "LineColor", "LinePattern", "LineColorTrans", "FillForegnd",
        "FillForegndTrans", "FillPattern", "VerticalAlign", "LockMoveX", "LockMoveY",
        "LockDelete", "LockVtxEdit", "LockFormat", "LockGroup", "LockWidth", "LockHeight",
        "LockAspect", "LockRotate", "LockTextEdit", "LockGlue", "FlipX", "FlipY", "LayerMember",
        "TxtPinX", "TxtPinY", "TxtWidth", "TxtHeight", "TxtLocPinX", "TxtLocPinY", "TxtAngle",
        "LeftMargin", "RightMargin", "TopMargin", "BottomMargin", "Char.Size",
        "EnableLineProps", "EnableFillProps", "EnableTextProps"
    ]
    private static let styleEnableCells = ["EnableLineProps", "EnableFillProps", "EnableTextProps"]
    private static let rowTypes: Set<String> = [
        "MoveTo", "LineTo", "RelMoveTo", "RelLineTo", "CubBezTo", "RelCubBezTo",
        "QuadBezTo", "RelQuadBezTo", "Ellipse", "ArcTo", "EllipticalArcTo", "RelEllipticalArcTo"
    ]

    /// Cheap model checks for native command availability. Public source and
    /// dependency checks run on the owned worker before any replacement.
    static func unavailableReason(_ ids: Set<UUID>, in diagram: Diagram) -> String? {
        guard (2...maximumShapes).contains(ids.count) else {
            return "Select between 2 and \(maximumShapes) filled shapes to unite."
        }
        guard diagram.legacySource == nil else { return "Union cannot consume shapes with unqualified legacy source behavior." }
        let page = diagram.page, nodes = page.nodes.filter { ids.contains($0.id) }
        guard nodes.count == ids.count else { return "The Union selection is no longer current." }
        let parentIDs = Set(page.nodes.compactMap(\.parentID))
        let inherited = Set((diagram.definitions?.uses ?? []).filter { $0.masterID != nil || $0.masterShapeID != nil }.map(\.objectID))
        let binding = diagram.visioArchive?.pages.first { $0.pageID == page.id }
        guard Set(nodes.map(\.parentID)).count == 1 else { return "Union requires shapes in the same group." }
        guard !page.edges.contains(where: { ids.contains($0.source) || ids.contains($0.target) || $0.parentID.map(ids.contains) == true }) else {
            return "Detach connectors before uniting their shapes."
        }
        for node in nodes {
            if let reason = NativeEditProtection.blockReason(for: "Geometry", node: node, in: page) { return reason }
            var ancestor: DiagramNode? = node, seen = Set<UUID>()
            while let value = ancestor {
                guard seen.insert(value.id).inserted else { return "The group hierarchy needs repair before Union." }
                for key in ["LockDelete", "LockVtxEdit", "LockGroup"] {
                    if let cell = value.formatting.sheet.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value {
                        guard Double(cell.value) == 0,
                              cell.formula.isEmpty || (try? ShapeSheet.evaluate(cell.formula, resolve: { _ in throw DiagramError.invalid("Unresolved protection") })) == 0 else {
                            return "\(key) protects a selected shape or its group."
                        }
                    }
                }
                ancestor = value.parentID.flatMap { id in page.nodes.first { $0.id == id } }
            }
            let detail = node.formatting
            guard !detail.isGroup, !parentIDs.contains(node.id) else { return "Select individual filled shapes for Union." }
            guard node.text.isEmpty, detail.data.isEmpty, detail.hyperlinks.isEmpty,
                  detail.image == nil, detail.controls.isEmpty, detail.connectionPoints.isEmpty,
                  (detail.textFields ?? []).isEmpty, (detail.textRuns ?? []).isEmpty else {
                return "Union currently requires shapes without text, fields, data, images, controls or connection points."
            }
            guard !inherited.contains(node.id), binding?.inheritedShapes?[node.id] == nil else {
                return "Union cannot consume an inherited master shape."
            }
            guard detail.sheet.keys.allSatisfy(sheetCells.contains) else { return "A selected shape has behavior cells that Union must preserve." }
            // Public import projects the writer's No Style0 enable flags into
            // each shape. Only their ordinary literal defaults are inert here.
            for key in styleEnableCells {
                if let cell = detail.sheet[key], cell.value != "1" || !cell.formula.isEmpty || !cell.unit.isEmpty {
                    return "A selected shape has an authored style-enable setting that Union must preserve."
                }
            }
            for (key, cell) in detail.sheet where !cell.formula.isEmpty {
                let ordinaryPin = key == "LocPinX" && cell.formula == "Width*0.5" || key == "LocPinY" && cell.formula == "Height*0.5"
                guard ordinaryPin else { return "Remove authored shape formulas before Union." }
            }
            if let value = detail.sheet["FillPattern"].flatMap({ Double($0.value) }), value != 1 {
                return "Union requires a solid filled shape."
            }
            guard !(node.fill.count == 9 && node.fill.hasSuffix("00")), node.kind != .text else { return "Union requires a solid filled shape." }
            if detail.paths.isEmpty {
                guard detail.geometry == nil, ![ShapeKind.person, .swimlane, .cylinder].contains(node.kind) else {
                    return "This shape has no complete closed filled outline for Union."
                }
            } else if detail.paths.contains(where: { !$0.fill }) || Set(detail.paths.map(\.stroke)).count > 1 { return "Union requires closed filled paths with one consistent stroke policy." }
            for section in detail.geometry ?? [] {
                guard Set(section.cells.keys).isSubset(of: ["NoFill", "NoLine", "NoShow"]),
                      section.cells.values.allSatisfy({ $0.formula.isEmpty }),
                      section.rows.allSatisfy({ rowTypes.contains($0.type) && Set($0.cells.keys).isSubset(of: ["X", "Y", "A", "B", "C", "D", "E"]) && $0.cells.values.allSatisfy { $0.formula.isEmpty } }) else {
                    return "Union cannot flatten authored or unsupported geometry definitions."
                }
            }
        }
        return nil
    }

    static func union(_ ids: Set<UUID>, in input: Diagram, resultID: UUID = UUID(),
                      cancellation: LifecycleJobCancellation = LifecycleJobCancellation()) throws -> Diagram {
        try applying(.union, ids: ids, in: input, resultID: resultID, cancellation: cancellation)
    }

    static func intersect(_ ids: Set<UUID>, in input: Diagram, resultID: UUID = UUID(),
                          cancellation: LifecycleJobCancellation = LifecycleJobCancellation()) throws -> Diagram {
        try applying(.intersect, ids: ids, in: input, resultID: resultID, cancellation: cancellation)
    }

    static func subtract(_ ids: Set<UUID>, in input: Diagram, baseID: UUID, resultID: UUID = UUID(),
                         cancellation: LifecycleJobCancellation = LifecycleJobCancellation()) throws -> Diagram {
        try applying(.subtract(baseID: baseID), ids: ids, in: input, resultID: resultID, cancellation: cancellation)
    }

    static func unavailableReason(_ ids: Set<UUID>, in input: Diagram, operation: Operation) -> String? {
        if operation != .union, ids.count != 2 { return "Select exactly two filled sibling shapes for \(operation.title)." }
        if case .subtract(let baseID) = operation, !ids.contains(baseID) { return "Choose one of the two selected shapes to subtract from." }
        return unavailableReason(ids, in: input).map { describing($0, for: operation) }
    }

    private static func describing(_ reason: String, for operation: Operation) -> String {
        guard operation != .union else { return reason }
        return reason.replacingOccurrences(of: "Union", with: operation.title)
            .replacingOccurrences(of: "unite", with: operation == .intersect ? "intersect" : "subtract")
            .replacingOccurrences(of: "uniting", with: operation == .intersect ? "intersecting" : "subtracting")
    }

    private static func applying(_ operation: Operation, ids: Set<UUID>, in input: Diagram, resultID: UUID,
                                 cancellation: LifecycleJobCancellation) throws -> Diagram {
        do { return try build(operation, ids: ids, in: input, resultID: resultID, cancellation: cancellation) }
        catch DiagramError.invalid(let reason) { throw DiagramError.invalid(describing(reason, for: operation)) }
    }

    private static func build(_ operation: Operation, ids: Set<UUID>, in input: Diagram, resultID: UUID,
                              cancellation: LifecycleJobCancellation) throws -> Diagram {
        try cancellation.check()
        _ = try input.validated()
        if let reason = unavailableReason(ids, in: input, operation: operation) { throw DiagramError.invalid(reason) }
        let page = input.page, nodes = page.nodes.filter { ids.contains($0.id) }
        guard !input.pages.contains(where: { $0.nodes.contains { $0.id == resultID } || $0.edges.contains { $0.id == resultID } }) else {
            throw DiagramError.invalid("The Union result needs a new object identity.")
        }
        if let archive = input.visioArchive {
            let known = try privateParts(in: archive)
            guard !archive.parts.keys.contains(where: { $0.hasPrefix("macvisio/") && !known.contains($0) }) else {
                throw DiagramError.invalid("Union cannot prove that an unregistered private-prefix source part is independent of selected shapes.")
            }
        }
        let prepared = try input.visioArchive.map { _ in try VisioPreservation.prepared(input) }
        let binding = prepared?.pages.first { $0.pageID == page.id }
        let consumed = Set(nodes.compactMap { node in
            (binding?.nodeIDs[node.id] ?? node.formatting.sourceShapeID ?? page.nodes.firstIndex(where: { $0.id == node.id }).map { String($0 + 1) }).flatMap(UInt32.init)
        })
        guard consumed.count == ids.count else { throw DiagramError.invalid("The selected public shape identities are ambiguous.") }
        try checkDependencies(input, consumed: consumed, selected: ids, cancellation: cancellation)
        let rawSourceIDs = try prepared.map { try checkPublicSource($0, selected: ids, consumed: consumed, pageID: page.id, cancellation: cancellation) } ?? []

        var operands: [(DiagramNode, VectorPath)] = [], inputCount = 0
        for node in nodes {
            try cancellation.check()
            let paths = try paths(for: node)
            for path in paths {
                inputCount += path.commands.count
                guard inputCount <= maximumInputCommands else { throw DiagramError.invalid("Union exceeds the \(maximumInputCommands)-command input limit.") }
                operands.append((node, path))
            }
        }
        var result: CGPath?, surfaces: [UUID: CGPath] = [:]
        for (node, path) in operands {
            try cancellation.check()
            let source = try cgPath(path, on: node)
            // Each source section owns its fill rule. Once normalized,
            // combining sections under nonzero winding preserves holes.
            let normalized = source.normalized(using: path.evenOdd == true ? .evenOdd : .winding)
            try cancellation.check()
            let box = normalized.boundingBoxOfPath
            guard !normalized.isEmpty, !box.isNull, !box.isInfinite, box.width > 1e-8, box.height > 1e-8,
                  abs(area(try commands(normalized, bounds: box, cancellation: cancellation))) > 1e-12 else {
                throw DiagramError.invalid("Union contains an empty, singular or degenerate filled surface.")
            }
            if operation == .union {
                // Preserve the existing Union fold and its regression coverage.
                result = result.map { $0.union(normalized, using: .winding) } ?? normalized
                _ = try commands(try unwrap(result), bounds: nil, cancellation: cancellation)
            } else {
                // Geometry sections within one shape are one operand surface.
                // Intersecting individual sections would erase disjoint pieces.
                surfaces[node.id] = surfaces[node.id].map { $0.union(normalized, using: .winding) } ?? normalized
                _ = try commands(try unwrap(surfaces[node.id]), bounds: nil, cancellation: cancellation)
            }
        }
        if operation != .union {
            var preparedCommands = 0
            for node in nodes {
                preparedCommands += try commands(try unwrap(surfaces[node.id]), bounds: nil, cancellation: cancellation).count
                guard preparedCommands <= maximumOutputCommands else { throw DiagramError.invalid("Prepared operand surfaces exceed the \(maximumOutputCommands)-command limit.") }
            }
            try cancellation.check()
            switch operation {
            case .intersect: result = try unwrap(surfaces[nodes[0].id]).intersection(unwrap(surfaces[nodes[1].id]), using: .winding)
            case .subtract(let baseID):
                guard let cutter = nodes.first(where: { $0.id != baseID }) else { throw DiagramError.invalid("Choose a distinct subtraction cutter.") }
                result = try unwrap(surfaces[baseID]).subtracting(unwrap(surfaces[cutter.id]), using: .winding)
            case .union: break
            }
            try cancellation.check()
            guard result?.isEmpty == false else { throw DiagramError.invalid("The operation produces no filled area. The original shapes were kept.") }
        }
        let output = try unwrap(result), bounds = output.boundingBoxOfPath
        guard !bounds.isNull, !bounds.isInfinite, [bounds.minX, bounds.minY, bounds.width, bounds.height].allSatisfy(\.isFinite),
              bounds.width > 1e-8, bounds.height > 1e-8 else { throw DiagramError.invalid("Union produced an empty or degenerate surface.") }
        let vector = VectorPath(commands: try commands(output, bounds: bounds, cancellation: cancellation), fill: true, stroke: nodes[0].formatting.paths.first?.stroke ?? true, evenOdd: false)
        if operation != .union, abs(area(vector.commands)) <= 1e-12 {
            throw DiagramError.invalid("The operation produces no filled area. The original shapes were kept.")
        }
        var node = DiagramNode(x: bounds.minX, y: bounds.minY, text: "")
        node.id = resultID; node.width = bounds.width; node.height = bounds.height; node.parentID = nodes[0].parentID
        node.fill = nodes[0].fill; node.stroke = nodes[0].stroke; node.strokeWidth = nodes[0].strokeWidth; node.layer = nodes[0].layer
        node.formatting.linePattern = nodes[0].formatting.linePattern
        node.formatting.layerNames = nodes[0].formatting.layerNames
        node.formatting.paths = [vector]
        node.formatting.geometry = [geometry(vector)]
        let reserved = page.nodes.enumerated().map { binding?.nodeIDs[$0.element.id] ?? $0.element.formatting.sourceShapeID ?? String($0.offset + 1) }
            + page.edges.enumerated().map { binding?.edgeIDs[$0.element.id] ?? $0.element.sourceShapeID ?? String(page.nodes.count + $0.offset + 1) }
            + (binding.map { Array($0.nodeIDs.values) + Array($0.edgeIDs.values) } ?? [])
            + rawSourceIDs
        var allocator = try VisioIDAllocator(reserved: reserved)
        node.formatting.sourceShapeID = try allocator.allocate()
        var next = input
        // Freeze implicit addresses before removing objects, so an unrelated
        // surviving Sheet.N reference never shifts to a different object.
        for index in next.page.nodes.indices where next.page.nodes[index].formatting.sourceShapeID == nil {
            next.page.nodes[index].formatting.sourceShapeID = binding?.nodeIDs[next.page.nodes[index].id] ?? String(index + 1)
        }
        for index in next.page.edges.indices where next.page.edges[index].sourceShapeID == nil {
            next.page.edges[index].sourceShapeID = binding?.edgeIDs[next.page.edges[index].id] ?? String(page.nodes.count + index + 1)
        }
        next.page.nodes.removeAll { ids.contains($0.id) }
        // A new Boolean shape is topmost. Public preservation appends it to its
        // containing Shapes element, so native and public paint order agree.
        next.page.nodes.append(node)
        try cancellation.check()
        return try next.validated()
    }

    private static func unwrap(_ path: CGPath?) throws -> CGPath {
        guard let path else { throw DiagramError.invalid("Union has no filled input.") }; return path
    }

    private static func paths(for node: DiagramNode) throws -> [VectorPath] {
        if !node.formatting.paths.isEmpty { return node.formatting.paths }
        let bezier = DiagramDrawing.path(for: node.kind, in: CGRect(x: 0, y: 0, width: node.width, height: node.height))
        var values: [VectorCommand] = [], points = [CGPoint](repeating: .zero, count: 3)
        func p(_ index: Int) -> [Double] { [points[index].x / node.width, points[index].y / node.height] }
        for index in 0..<bezier.elementCount {
            switch bezier.element(at: index, associatedPoints: &points) {
            case .moveTo: values.append(VectorCommand(kind: "M", values: p(0)))
            case .lineTo: values.append(VectorCommand(kind: "L", values: p(0)))
            case .curveTo: values.append(VectorCommand(kind: "C", values: p(0) + p(1) + p(2)))
            case .closePath: values.append(VectorCommand("Z"))
            @unknown default: throw DiagramError.invalid("Unsupported native path element.")
            }
        }
        return [VectorPath(commands: values)]
    }

    private static func cgPath(_ vector: VectorPath, on node: DiagramNode) throws -> CGPath {
        let path = CGMutablePath(); var start: CGPoint?, current: CGPoint?, closed = true, hasSegment = false
        func point(_ x: Double, _ y: Double) -> CGPoint { DiagramCoordinates.world(CGPoint(x: x * node.width, y: y * node.height), in: node) }
        func closePrevious() throws {
            guard let start else { return }
            guard closed || current.map({ hypot($0.x - start.x, $0.y - start.y) < 1e-8 }) == true else {
                throw DiagramError.invalid("Union requires explicitly closed filled paths.")
            }
            if !closed { path.closeSubpath() }; closed = true
        }
        for command in vector.commands {
            guard command.isValid(xScale: node.width, yScale: node.height) else { throw DiagramError.invalid("Union contains invalid vector coordinates.") }
            let v = command.values
            switch command.kind {
            case "M": try closePrevious(); let p = point(v[0], v[1]); path.move(to: p); start = p; current = p; closed = false
            case "L": guard start != nil, !closed else { throw DiagramError.invalid("Union has an invalid open path sequence.") }; let p = point(v[0], v[1]); path.addLine(to: p); current = p; hasSegment = true
            case "Q": guard start != nil, !closed else { throw DiagramError.invalid("Union has an invalid curve sequence.") }; let p = point(v[2], v[3]); path.addQuadCurve(to: p, control: point(v[0], v[1])); current = p; hasSegment = true
            case "C": guard start != nil, !closed else { throw DiagramError.invalid("Union has an invalid curve sequence.") }; let p = point(v[4], v[5]); path.addCurve(to: p, control1: point(v[0], v[1]), control2: point(v[2], v[3])); current = p; hasSegment = true
            case "Z": guard start != nil, !closed else { throw DiagramError.invalid("Union has an invalid closed path sequence.") }; path.closeSubpath(); current = start; closed = true
            default: throw DiagramError.invalid("Union has unsupported vector commands.")
            }
        }
        try closePrevious()
        guard hasSegment else { throw DiagramError.invalid("Union contains an empty path.") }
        return path
    }

    private static func commands(_ path: CGPath, bounds: CGRect?, cancellation: LifecycleJobCancellation) throws -> [VectorCommand] {
        var result: [VectorCommand] = [], failure: Error?
        func point(_ p: CGPoint) -> [Double] {
            guard let bounds else { return [p.x, p.y] }
            return [(p.x - bounds.minX) / bounds.width, (p.y - bounds.minY) / bounds.height]
        }
        path.applyWithBlock { pointer in
            guard failure == nil else { return }
            do {
                if result.count.isMultiple(of: 128) { try cancellation.check() }
                guard result.count < maximumOutputCommands else { throw DiagramError.invalid("Union exceeds the \(maximumOutputCommands)-command result limit.") }
                let element = pointer.pointee, p = element.points
                switch element.type {
                case .moveToPoint: result.append(VectorCommand(kind: "M", values: point(p[0])))
                case .addLineToPoint: result.append(VectorCommand(kind: "L", values: point(p[0])))
                case .addQuadCurveToPoint: result.append(VectorCommand(kind: "Q", values: point(p[0]) + point(p[1])))
                case .addCurveToPoint: result.append(VectorCommand(kind: "C", values: point(p[0]) + point(p[1]) + point(p[2])))
                case .closeSubpath: result.append(VectorCommand("Z"))
                @unknown default: throw DiagramError.invalid("Union returned an unsupported path element.")
                }
                guard result.last!.values.allSatisfy(\.isFinite) else { throw DiagramError.invalid("Union produced non-finite geometry.") }
            } catch { failure = error }
        }
        if let failure { throw failure }; return result
    }

    private static func geometry(_ path: VectorPath) -> ShapeGeometrySection {
        var rows: [ShapeGeometryRow] = [], first: [Double] = [], current = CGPoint.zero
        func append(_ type: String, _ values: [String: Double]) {
            rows.append(ShapeGeometryRow(index: rows.count + 1, type: type, cells: values.mapValues { ShapeSheetCell(value: CompositeGeometry.number($0)) }))
        }
        for command in path.commands {
            let v = command.values
            switch command.kind {
            case "M": first = v; current = CGPoint(x: v[0], y: v[1]); append("RelMoveTo", ["X": v[0], "Y": 1 - v[1]])
            case "L": current = CGPoint(x: v[0], y: v[1]); append("RelLineTo", ["X": v[0], "Y": 1 - v[1]])
            case "C": current = CGPoint(x: v[4], y: v[5]); append("RelCubBezTo", ["X": v[4], "Y": 1 - v[5], "A": v[0], "B": 1 - v[1], "C": v[2], "D": 1 - v[3]])
            case "Q":
                let end = CGPoint(x: v[2], y: v[3]), a = CGPoint(x: current.x + 2 * (v[0] - current.x) / 3, y: current.y + 2 * (v[1] - current.y) / 3)
                let b = CGPoint(x: end.x + 2 * (v[0] - end.x) / 3, y: end.y + 2 * (v[1] - end.y) / 3)
                append("RelCubBezTo", ["X": end.x, "Y": 1 - end.y, "A": a.x, "B": 1 - a.y, "C": b.x, "D": 1 - b.y]); current = end
            case "Z": append("RelLineTo", ["X": first[0], "Y": 1 - first[1]]); current = CGPoint(x: first[0], y: first[1])
            default: break
            }
        }
        return ShapeGeometrySection(index: 0, cells: ["NoFill": ShapeSheetCell(value: "0"), "NoLine": ShapeSheetCell(value: path.stroke ? "0" : "1"), "NoShow": ShapeSheetCell(value: "0")], rows: rows)
    }

    /// Green's theorem integrated over line/quadratic/cubic power bases.
    /// Coordinates are normalized to each path's bounds before this check,
    /// avoiding cancellation from a large world-coordinate translation.
    private static func area(_ commands: [VectorCommand]) -> Double {
        var current = CGPoint.zero, first = CGPoint.zero, result = 0.0
        func integrate(_ x: [Double], _ y: [Double]) -> Double {
            var sum = 0.0
            for i in x.indices { for j in 1..<x.count { sum += Double(j) * (x[i] * y[j] - y[i] * x[j]) / Double(i + j) } }
            return sum / 2
        }
        func line(_ end: CGPoint) { result += integrate([current.x, end.x - current.x], [current.y, end.y - current.y]); current = end }
        for command in commands {
            let v = command.values
            switch command.kind {
            case "M": current = CGPoint(x: v[0], y: v[1]); first = current
            case "L": line(CGPoint(x: v[0], y: v[1]))
            case "Q":
                let end = CGPoint(x: v[2], y: v[3])
                result += integrate([current.x, 2 * (v[0] - current.x), current.x - 2 * v[0] + end.x], [current.y, 2 * (v[1] - current.y), current.y - 2 * v[1] + end.y]); current = end
            case "C":
                let end = CGPoint(x: v[4], y: v[5])
                result += integrate([current.x, 3 * (v[0] - current.x), 3 * (current.x - 2 * v[0] + v[2]), -current.x + 3 * v[0] - 3 * v[2] + end.x], [current.y, 3 * (v[1] - current.y), 3 * (current.y - 2 * v[1] + v[3]), -current.y + 3 * v[1] - 3 * v[3] + end.y]); current = end
            case "Z": line(first)
            default: break
            }
        }
        return result
    }

    private static func checkDependencies(_ input: Diagram, consumed: Set<UInt32>, selected: Set<UUID>, cancellation: LifecycleJobCancellation) throws {
        var work = 0
        func check(_ cells: [String: ShapeSheetCell]) throws {
            work += 1; if work.isMultiple(of: 128) { try cancellation.check() }
            for cell in cells.values where !cell.formula.isEmpty { try checkFormula(cell.formula, consumed: consumed) }
        }
        func detail(_ detail: ShapeDetails) throws {
            guard detail.hyperlinks.isEmpty else { throw DiagramError.invalid("A surviving hyperlink target needs review before Union can remove shape identities.") }
            try check(detail.sheet)
            for section in detail.geometry ?? [] { try check(section.cells); for row in section.rows { try check(row.cells) } }
            for field in detail.textFields ?? [] { try check(field.cells) }
            for run in detail.textRuns ?? [] { try check(run.character.cells); try check(run.paragraph.cells) }
            for point in detail.connectionPoints { try check(["X": point.x, "Y": point.y]) }
            for control in detail.controls { try check(control.cells) }
        }
        for page in input.pages {
            try cancellation.check()
            try check(page.sheet ?? [:])
            for node in page.nodes where !selected.contains(node.id) { try detail(node.formatting) }
            for edge in page.edges { try detail(edge.formatting) }
            for layer in page.layers ?? [] { try check(layer.sheet) }
        }
        for sheet in input.definitions?.editableSheets ?? [] { for cell in sheet.cells { try check(["value": cell.value]) } }
        for use in input.definitions?.uses ?? [] where !selected.contains(use.objectID) { for cell in use.localSheet.cells { try check(["value": cell.value]) } }
    }

    private static let pureFunctions: Set<String> = [
        "GUARD", "THEMEGUARD", "SETATREFEXPR", "IF", "IFERROR", "AND", "OR", "NOT", "TRUE", "FALSE",
        "ABS", "MIN", "MAX", "SUM", "SQRT", "SIN", "COS", "TAN", "ASIN", "ACOS", "ATAN", "ATAN2", "PI",
        "ROUND", "INT", "MOD", "SIGN", "LN", "LOG", "EXP", "POW", "RGB", "HSL", "FONT", "THEMEVAL",
        "THEME", "THEMETINT", "THEMESHADE", "THEMESEC", "THEMERESTORE", "NURBS", "POLYLINE", "STRSAME", "STRSAMEEX"
    ]
    private static func checkFormula(_ formula: String, consumed: Set<UInt32>) throws {
        guard let expression = try? ShapeSheet.parse(formula, characterLimit: 16384) else { throw DiagramError.invalid("A surviving formula needs review before Union can remove shape identities.") }
        var pending = [expression]
        while let expression = pending.popLast() {
            switch expression {
            case .reference(let reference):
                let pieces = reference.lowercased().components(separatedBy: "sheet.")
                for suffix in pieces.dropFirst() {
                    let digits = suffix.prefix { $0.isNumber }
                    guard let id = UInt32(digits), suffix.dropFirst(digits.count).first == "!" else { throw DiagramError.invalid("A surviving shape reference needs review before Union.") }
                    if consumed.contains(id) { throw DiagramError.invalid("A surviving formula references a selected Sheet.\(id). Remove that reference before Union.") }
                }
            case .call(let name, let arguments):
                guard pureFunctions.contains(name.uppercased()) else { throw DiagramError.invalid("The surviving \(name) formula cannot be proven independent of selected shapes.") }
                pending += arguments
            case .unary(_, let value): pending.append(value)
            case .binary(_, let left, let right): pending += [left, right]
            default: break
            }
        }
    }

    private static func checkPublicSource(_ archive: VisioDocumentArchive, selected: Set<UUID>, consumed: Set<UInt32>, pageID: UUID,
                                          cancellation: LifecycleJobCancellation) throws -> [String] {
        guard let binding = archive.pages.first(where: { $0.pageID == pageID }) else { throw DiagramError.invalid("Union has no public page binding.") }
        let documentPart = try VisioReusableFormat.documentPart(archive.parts)
        // Every Visio 2019 drawing carries a windows part (window sizes and view state), which never refers to shapes.
        let windowsType = VisioReusableFormat.relationship + "windows"
        let windowsParts = try archive.parts[VisioXML.relationshipPart(documentPart)].map(VisioXML.document)?.rootElement()?.elementsLocal("Relationship")
            .filter { $0.attr("Type") == windowsType && $0.attr("TargetMode") == nil }
            .compactMap { $0.attr("Target") }.map { try VisioFormat.resolve($0, relativeTo: documentPart) } ?? []
        let knownXML = Set(archive.pages.map(\.part) + [documentPart, archive.pagesPart, "[Content_Types].xml", "docProps/core.xml"] + windowsParts)
        var relationshipSources = Dictionary(([documentPart, archive.pagesPart] + archive.pages.map(\.part)).map { (VisioXML.relationshipPart($0), $0) }, uniquingKeysWith: { first, _ in first })
        relationshipSources["_rels/.rels"] = ""
        let coreParts = Set(archive.pages.map(\.part) + [documentPart, archive.pagesPart])
        let coreElements: Set<String> = ["VisioDocument", "DocumentSettings", "GlueSettings", "SnapSettings", "Colors", "ColorEntry", "FaceNames", "FaceName", "StyleSheets", "StyleSheet", "DocumentSheet", "Pages", "Page", "PageSheet", "PageContents", "Shapes", "Shape", "Cell", "Section", "Row", "Text", "Connects", "Connect", "Rel", "cp", "pp", "tp", "fld", "ForeignData"]
        let coreAttributes: Set<String> = ["ID", "Name", "NameU", "Type", "LineStyle", "FillStyle", "TextStyle", "IX", "N", "V", "U", "F", "T", "Del", "RGB", "Background", "BackPage", "ViewScale", "ViewCenterX", "ViewCenterY", "ReviewerID", "FromSheet", "FromCell", "FromPart", "ToSheet", "ToCell", "ToPart", "r:id", "xml:space", "ForeignType", "ObjectType", "CompressionType", "ExtentX", "ExtentY"]
        let excludedParts = try privateParts(in: archive)
        var found = Set<UInt32>(), sourceIDs = Set<String>()
        for (part, bytes) in archive.parts.sorted(by: { $0.key < $1.key }) {
            try cancellation.check()
            if excludedParts.contains(part) { continue }
            if part.hasPrefix("visio/media/"), ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff"].contains((part as NSString).pathExtension.lowercased()) { continue }
            guard knownXML.contains(part) || relationshipSources[part] != nil else {
                throw DiagramError.invalid("Union cannot prove that the retained part \(part) is independent of selected shapes.")
            }
            let document = try VisioXML.document(bytes)
            guard let root = document.rootElement() else { throw DiagramError.invalid("Union encountered an incomplete public source part.") }
            if let source = relationshipSources[part] {
                let namespace = "http://schemas.openxmlformats.org/package/2006/relationships"
                guard root.localName == "Relationships", root.uri == namespace, (root.attributes ?? []).isEmpty,
                      (root.children ?? []).compactMap({ $0 as? XMLElement }).allSatisfy({ $0.localName == "Relationship" && $0.uri == namespace }) else {
                    throw DiagramError.invalid("Union encountered an unqualified relationship source extension.")
                }
                var relationIDs = Set<String>()
                for relation in root.elementsLocal("Relationship") {
                    guard let id = relation.attr("Id"), !id.isEmpty, relationIDs.insert(id).inserted,
                          let type = relation.attr("Type"), let rawTarget = relation.attr("Target"), relation.attr("TargetMode") == nil,
                          (relation.attributes ?? []).allSatisfy({ ["Id", "Type", "Target"].contains($0.name ?? "") }),
                          !(relation.children ?? []).contains(where: { $0 is XMLElement }) else {
                        throw DiagramError.invalid("Union encountered an unqualified public relationship.")
                    }
                    if relation.attr("Type") == "urn:macvisio:relationships:diagram",
                       ["macvisio/document.json", "/macvisio/document.json"].contains(relation.attr("Target") ?? "") {
                        guard part == "_rels/.rels" else {
                            throw DiagramError.invalid("Union encountered an unqualified native metadata relationship.")
                        }
                        continue
                    }
                    let target = try VisioFormat.resolve(rawTarget, relativeTo: source)
                    let valid: Bool
                    if source.isEmpty, type == VisioReusableFormat.relationship + "document" { valid = target == documentPart }
                    else if source.isEmpty, type == "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" { valid = target == "docProps/core.xml" }
                    else if source == documentPart, type == VisioReusableFormat.relationship + "pages" { valid = target == archive.pagesPart }
                    else if source == documentPart, type == windowsType { valid = windowsParts.contains(target) }
                    else if source == archive.pagesPart, type == VisioReusableFormat.relationship + "page" { valid = archive.pages.contains { $0.part == target } }
                    else {
                        valid = archive.pages.contains { $0.part == source }
                            && type == "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
                            && target.hasPrefix("visio/media/") && ["png", "jpg", "jpeg", "gif", "bmp", "tif", "tiff"].contains((target as NSString).pathExtension.lowercased())
                    }
                    guard valid, archive.parts[target] != nil else {
                        throw DiagramError.invalid("Union cannot consume shapes in a drawing with an unqualified public relationship.")
                    }
                }
            }
            if part == "docProps/core.xml" { try checkCoreProperties(root) }
            if part == "[Content_Types].xml" { try checkContentTypes(root) }
            var pending = [root], work = 0
            while let element = pending.popLast() {
                work += 1; if work.isMultiple(of: 128) { try cancellation.check() }
                if coreParts.contains(part) {
                    guard coreElements.contains(element.localName ?? ""),
                          (element.attributes ?? []).allSatisfy({ coreAttributes.contains($0.name ?? "") }),
                          element.uri == nil || element.uri == "http://schemas.microsoft.com/office/visio/2012/main" else {
                        throw DiagramError.invalid("A retained public source extension cannot be proven independent of selected shapes.")
                    }
                    if element.localName == "Section", ["Hyperlink", "Actions"].contains(element.attr("N") ?? "") {
                        throw DiagramError.invalid("A retained public action or hyperlink target needs review before Union.")
                    }
                    if element.localName == "Section", !["Geometry", "Character", "Paragraph", "User", "Property", "Layer", "Field", "Connection", "Control"].contains(element.attr("N") ?? "") {
                        throw DiagramError.invalid("A retained public behavior section cannot be qualified before Union.")
                    }
                    if element.localName == "Row", let section = element.parent as? XMLElement,
                       section.localName == "Section", section.attr("N") == "Geometry", !rowTypes.contains(element.attr("T") ?? "") {
                        throw DiagramError.invalid("A retained geometry row cannot be qualified before Union.")
                    }
                }
                if part == binding.part, element.localName == "Shape" {
                    guard let raw = element.attr("ID"), let id = UInt32(raw) else { throw DiagramError.invalid("A retained public shape has an invalid identity.") }
                    // Tombstones and suppressed source shapes may have no
                    // native/binding entry, but still reserve their numeric ID.
                    sourceIDs.insert(raw)
                    if consumed.contains(id) { try checkBareShape(element); found.insert(id); continue }
                }
                if element.localName == "Cell", let formula = element.attr("F"), !formula.isEmpty { try checkFormula(formula, consumed: consumed) }
                if element.localName == "Connect" {
                    for key in ["FromSheet", "ToSheet"] where element.attr(key).flatMap(UInt32.init).map(consumed.contains) == true {
                        throw DiagramError.invalid("A public connector still references a selected shape.")
                    }
                }
                // Unknown attributes that identify sheets are not silently
                // treated as harmless merely because no native model uses them.
                for attribute in element.attributes ?? [] where !["ID", "IX", "V", "F", "N", "T"].contains(attribute.name ?? "") {
                    let name = (attribute.localName ?? attribute.name ?? "").lowercased()
                    if (name.contains("shape") || name.contains("sheet")), let raw = attribute.stringValue, let id = UInt32(raw), consumed.contains(id) {
                        throw DiagramError.invalid("A retained public attribute references a selected shape.")
                    }
                }
                pending += (element.children ?? []).compactMap { $0 as? XMLElement }
            }
        }
        let bound = Set(selected.compactMap { binding.nodeIDs[$0].flatMap(UInt32.init) })
        guard found == bound, found == consumed else { throw DiagramError.invalid("Union cannot prove complete public source coverage for selected shapes.") }
        return sourceIDs.sorted()
    }

    private static func checkBareShape(_ shape: XMLElement) throws {
        func attributes(_ element: XMLElement, allowed: Set<String>) throws {
            guard (element.attributes ?? []).allSatisfy({ allowed.contains($0.name ?? "") }) else { throw DiagramError.invalid("A selected shape retains opaque source attributes.") }
        }
        try attributes(shape, allowed: ["ID", "Name", "NameU", "Type", "LineStyle", "FillStyle", "TextStyle"])
        guard shape.attr("Type") == nil || shape.attr("Type") == "Shape",
              ["LineStyle", "FillStyle", "TextStyle"].allSatisfy({ shape.attr($0) == nil || shape.attr($0) == "0" }) else {
            throw DiagramError.invalid("A selected shape depends on a source definition or style.")
        }
        func cell(_ element: XMLElement, allowed: Set<String>, font: Bool = false) throws {
            try attributes(element, allowed: ["N", "V", "U", "F"])
            guard let name = element.attr("N"), allowed.contains(name), (element.children ?? []).allSatisfy({ !($0 is XMLElement) }) else { throw DiagramError.invalid("A selected shape retains opaque source cells.") }
            if styleEnableCells.contains(name), element.attr("V") != "1" || !(element.attr("F") ?? "").isEmpty || !(element.attr("U") ?? "").isEmpty {
                throw DiagramError.invalid("A selected source cell has an authored style-enable setting that Union must preserve.")
            }
            if let formula = element.attr("F"), !formula.isEmpty {
                let ordinaryPin = name == "LocPinX" && formula == "Width*0.5" || name == "LocPinY" && formula == "Height*0.5"
                let ordinaryFont: Bool
                if font, name == "Font", let expression = try? ShapeSheet.parse(formula), case .call(let function, let arguments) = expression,
                   function.uppercased() == "FONT", arguments.count == 1, case .string = arguments[0] { ordinaryFont = true }
                else { ordinaryFont = false }
                guard ordinaryPin || ordinaryFont else { throw DiagramError.invalid("A selected source cell has authored behavior that Union must preserve.") }
            }
        }
        for element in (shape.children ?? []).compactMap({ $0 as? XMLElement }) {
            switch element.localName {
            case "Cell": try cell(element, allowed: sheetCells)
            case "Text":
                try attributes(element, allowed: [])
                guard (element.stringValue ?? "").isEmpty, !(element.children ?? []).contains(where: { $0 is XMLElement }) else { throw DiagramError.invalid("A selected shape retains source text or text behavior.") }
            case "Section":
                try attributes(element, allowed: ["N", "IX"])
                guard let name = element.attr("N"), ["Geometry", "Character", "Paragraph"].contains(name) else { throw DiagramError.invalid("A selected shape retains source behavior sections.") }
                for child in (element.children ?? []).compactMap({ $0 as? XMLElement }) {
                    if child.localName == "Cell", name == "Geometry" { try cell(child, allowed: ["NoFill", "NoLine", "NoShow"]); continue }
                    guard child.localName == "Row" else { throw DiagramError.invalid("A selected shape retains opaque section content.") }
                    try attributes(child, allowed: name == "Geometry" ? ["IX", "T"] : ["IX"])
                    if name == "Geometry", !rowTypes.contains(child.attr("T") ?? "") { throw DiagramError.invalid("A selected shape retains unsupported geometry rows.") }
                    let allowed: Set<String> = name == "Geometry" ? ["X", "Y", "A", "B", "C", "D", "E"] : name == "Character" ? ["Font", "Color", "Size", "Style"] : ["HorzAlign"]
                    for value in (child.children ?? []).compactMap({ $0 as? XMLElement }) {
                        guard value.localName == "Cell" else { throw DiagramError.invalid("A selected shape retains opaque row content.") }
                        try cell(value, allowed: allowed, font: name == "Character")
                    }
                }
            default: throw DiagramError.invalid("A selected shape retains opaque or behavioral source content.")
            }
        }
    }

    private static func privateParts(in archive: VisioDocumentArchive) throws -> Set<String> {
        guard let metadata = archive.parts["macvisio/document.json"] else { return [] }
        let stored = try NativeMetadataStorage.load(metadata, parts: archive.parts)
        return stored.storageParts.union(["macvisio/document.json"])
    }

    private static func checkCoreProperties(_ root: XMLElement) throws {
        let core = "http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
        let names: [String: Set<String>] = [
            core: ["category", "contentStatus", "contentType", "keywords", "lastModifiedBy", "lastPrinted", "revision", "version"],
            "http://purl.org/dc/elements/1.1/": ["creator", "description", "identifier", "language", "subject", "title"],
            "http://purl.org/dc/terms/": ["created", "modified"]
        ]
        guard root.localName == "coreProperties", root.uri == core, (root.attributes ?? []).isEmpty else {
            throw DiagramError.invalid("Union cannot qualify the retained core-property source.")
        }
        for child in (root.children ?? []).compactMap({ $0 as? XMLElement }) {
            guard let namespace = child.uri, names[namespace]?.contains(child.localName ?? "") == true,
                  (child.attributes ?? []).allSatisfy({ ["xsi:type", "xml:lang"].contains($0.name ?? "") }),
                  !(child.children ?? []).contains(where: { $0 is XMLElement }) else {
                throw DiagramError.invalid("A retained metadata extension cannot be proven independent of selected shapes.")
            }
        }
    }

    private static func checkContentTypes(_ root: XMLElement) throws {
        let namespace = "http://schemas.openxmlformats.org/package/2006/content-types"
        guard root.localName == "Types", root.uri == namespace, (root.attributes ?? []).isEmpty else {
            throw DiagramError.invalid("Union cannot qualify the retained content-type source.")
        }
        for child in (root.children ?? []).compactMap({ $0 as? XMLElement }) {
            let allowed: Set<String> = child.localName == "Default" ? ["Extension", "ContentType"] : ["PartName", "ContentType"]
            guard ["Default", "Override"].contains(child.localName ?? ""), child.uri == namespace,
                  (child.attributes ?? []).allSatisfy({ allowed.contains($0.name ?? "") }),
                  !(child.children ?? []).contains(where: { $0 is XMLElement }) else {
                throw DiagramError.invalid("A retained content-type extension cannot be proven independent of selected shapes.")
            }
        }
    }
}
