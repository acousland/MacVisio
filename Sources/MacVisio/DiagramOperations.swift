import CoreGraphics
import Foundation

enum DiagramOperations {
    static func fragment(
        _ ids: Set<UUID>, edges: Set<UUID> = [], from page: DiagramPage, binding: VisioPageBinding? = nil
    ) -> DiagramPage {
        var fragment = DiagramPage(width: page.width, height: page.height)
        fragment.layers = page.layers
        fragment.drawingScale = page.drawingScale
        fragment.nodes = page.nodes.filter { ids.contains($0.id) }
        for i in fragment.nodes.indices where fragment.nodes[i].formatting.sourceShapeID == nil {
            if let index = page.nodes.firstIndex(where: { $0.id == fragment.nodes[i].id }) {
                fragment.nodes[i].formatting.sourceShapeID =
                    binding?.nodeIDs[fragment.nodes[i].id] ?? String(index + 1)
            }
        }
        for i in fragment.nodes.indices where fragment.nodes[i].parentID.map(ids.contains) != true {
            fragment.nodes[i].parentID = nil
        }
        fragment.edges = page.edges.filter {
            $0.parentID.map(ids.contains) == true || ids.contains($0.source) && ids.contains($0.target)
                || edges.contains($0.id)
        }
        for i in fragment.edges.indices {
            if fragment.edges[i].sourceShapeID == nil,
                let index = page.edges.firstIndex(where: { $0.id == fragment.edges[i].id })
            {
                fragment.edges[i].sourceShapeID =
                    binding?.edgeIDs[fragment.edges[i].id] ?? fragment.edges[i].details?.sourceShapeID
                    ?? String(page.nodes.count + index + 1)
            }
            if var detail = fragment.edges[i].details {
                detail.sourceShapeID = fragment.edges[i].sourceShapeID
                fragment.edges[i].details = detail
            }
            if fragment.edges[i].parentID.map(ids.contains) != true { fragment.edges[i].parentID = nil }
            let route = DiagramGeometry.route(fragment.edges[i], in: page)
            if !ids.contains(fragment.edges[i].source) {
                fragment.edges[i].sourcePosition = route.first.map(DiagramPoint.init)
                fragment.edges[i].sourcePort = nil
            }
            if !ids.contains(fragment.edges[i].target) {
                fragment.edges[i].targetPosition = route.last.map(DiagramPoint.init)
                fragment.edges[i].targetPort = nil
            }
        }
        return fragment
    }
    @discardableResult static func insert(
        _ fragment: DiagramPage, into page: inout DiagramPage, at origin: CGPoint? = nil,
        reservedIDs: [String] = []
    ) throws -> Set<UUID> {
        try DiagramMemberships.validatePaste(fragment)
        let fragment = DrawingScale.convert(fragment, to: page.paperScale, targetMeasured: page.isMeasured)
        guard !fragment.nodes.isEmpty || !fragment.edges.isEmpty else { return [] }
        var check = Diagram()
        check.pages = [fragment]
        check.activePageID = fragment.id
        _ = try check.validated()
        var bounds = fragment.nodes.reduce(CGRect.null) { $0.union($1.rect) }
        if bounds.isNull, origin != nil {
            for edge in fragment.edges {
                for point in DiagramGeometry.route(edge, in: fragment) {
                    bounds = bounds.union(CGRect(origin: point, size: .zero))
                }
            }
        }
        let requested =
            origin.map {
                CGPoint(
                    x: $0.x - (bounds.isNull ? 0 : bounds.minX), y: $0.y - (bounds.isNull ? 0 : bounds.minY))
            } ?? CGPoint(x: 20, y: 20)
        let dx = bounds.isNull ? requested.x : max(-bounds.minX, min(page.width - bounds.maxX, requested.x))
        let dy = bounds.isNull ? requested.y : max(-bounds.minY, min(page.height - bounds.maxY, requested.y))
        let map = Dictionary(uniqueKeysWithValues: fragment.nodes.map { ($0.id, UUID()) })
        let used =
            reservedIDs
            + page.nodes.enumerated().map { $0.element.formatting.sourceShapeID ?? String($0.offset + 1) }
            + page.edges.enumerated().map {
                $0.element.sourceShapeID ?? String(page.nodes.count + $0.offset + 1)
            }
        var allocator = try VisioIDAllocator(reserved: used)
        var sheetMap: [String: String] = [:]
        var newIDs: [UUID: String] = [:]
        var newEdgeIDs: [UUID: String] = [:]
        for (index, n) in fragment.nodes.enumerated() {
            let id = try allocator.allocate()
            newIDs[n.id] = id
            sheetMap[n.formatting.sourceShapeID ?? String(index + 1)] = id
        }
        for (index, edge) in fragment.edges.enumerated() {
            let id = try allocator.allocate()
            newEdgeIDs[edge.id] = id
            sheetMap[edge.sourceShapeID ?? edge.details?.sourceShapeID
                ?? String(fragment.nodes.count + index + 1)] = id
        }
        for var n in fragment.nodes {
            let old = n.id
            n.id = map[old]!
            n.parentID = n.parentID.flatMap { map[$0] }
            n.x += dx
            n.y += dy
            n.locked = false
            n.formatting.sourceShapeID = newIDs[old]
            n.details = remapping(n.formatting, using: sheetMap)
            page.nodes.append(n)
        }
        func translate(_ point: DiagramPoint?) -> DiagramPoint? {
            point.map { DiagramPoint(x: $0.x + dx, y: $0.y + dy) }
        }
        for var edge in fragment.edges {
            edge.sourceShapeID = newEdgeIDs[edge.id]
            if var detail = edge.details {
                detail.sourceShapeID = edge.sourceShapeID
                edge.details = remapping(detail, using: sheetMap)
            }
            edge.id = UUID()
            edge.source = map[edge.source] ?? UUID()
            edge.target = map[edge.target] ?? UUID()
            edge.parentID = edge.parentID.flatMap { map[$0] }
            edge.sourcePosition = translate(edge.sourcePosition)
            edge.targetPosition = translate(edge.targetPosition)
            edge.points = edge.points?.compactMap { translate($0) }
            page.edges.append(edge)
        }
        for layer in fragment.layers ?? []
        where !(page.layers ?? []).contains(where: { $0.name == layer.name }) {
            if page.layers == nil { page.layers = [] }
            var copy = layer
            copy.id = UUID()
            page.layers?.append(copy)
        }
        return roots(Set(map.values), in: page)
    }
    /// Copy authored references in every retained sheet/text payload. Cached
    /// values, units, row identities and quoted strings remain source data.
    private static func remapping(_ input: ShapeDetails, using map: [String: String]) -> ShapeDetails {
        func cell(_ input: ShapeSheetCell) -> ShapeSheetCell {
            var result = input
            result.formula = VisioIDAllocator.remap(input.formula, using: map)
            return result
        }
        var result = input
        result.sheet = input.sheet.mapValues(cell)
        result.textFields = input.textFields?.map { field in
            var field = field; field.cells = field.cells.mapValues(cell); return field
        }
        result.textRuns = input.textRuns?.map { run in
            var run = run
            run.character.cells = run.character.cells.mapValues(cell)
            run.paragraph.cells = run.paragraph.cells.mapValues(cell)
            return run
        }
        result.geometry = input.geometry?.map { section in
            var section = section; section.cells = section.cells.mapValues(cell)
            section.rows = section.rows.map { row in
                var row = row; row.cells = row.cells.mapValues(cell); return row
            }
            return section
        }
        result.connectionPoints = input.connectionPoints.map { point in
            var point = point; point.x = cell(point.x); point.y = cell(point.y); return point
        }
        result.controls = input.controls.map { control in
            var control = control; control.cells = control.cells.mapValues(cell); return control
        }
        return result
    }
    static func expandedSelection(_ selected: Set<UUID>, in page: DiagramPage) -> Set<UUID> {
        selected.reduce(into: Set<UUID>()) { ids, id in ids.formUnion(page.descendants(of: id)) }
    }
    static func roots(_ selected: Set<UUID>, in page: DiagramPage) -> Set<UUID> {
        let nested = selected.reduce(into: Set<UUID>()) { ids, id in
            ids.formUnion(page.descendants(of: id).subtracting([id]))
        }
        return selected.subtracting(nested)
    }
    static func transformChildren(
        in page: inout DiagramPage, from old: DiagramNode, to new: DiagramNode,
        preparedRoutes: [UUID: [CGPoint]]? = nil
    ) {
        guard old.formatting.isGroup else { return }
        var before = page
        if let i = before.nodes.firstIndex(where: { $0.id == old.id }) { before.nodes[i] = old }
        let children = page.descendants(of: old.id).subtracting([old.id])
        let sx = new.width / old.width
        let sy = new.height / old.height
        let a = -old.rotation * .pi / 180
        let b = new.rotation * .pi / 180
        for i in page.nodes.indices where children.contains(page.nodes[i].id) {
            let center = page.nodes[i].center
            let dx = center.x - old.center.x
            let dy = center.y - old.center.y
            let flipX = new.formatting.flipX != old.formatting.flipX
            let flipY = new.formatting.flipY != old.formatting.flipY
            let x = (dx * cos(a) - dy * sin(a)) * sx * (flipX ? -1 : 1)
            let y = (dx * sin(a) + dy * cos(a)) * sy * (flipY ? -1 : 1)
            page.nodes[i].width *= sx
            page.nodes[i].height *= sy
            page.nodes[i].x = new.center.x + x * cos(b) - y * sin(b) - page.nodes[i].width / 2
            page.nodes[i].y = new.center.y + x * sin(b) + y * cos(b) - page.nodes[i].height / 2
            page.nodes[i].rotation =
                new.rotation
                + (flipX != flipY
                    ? -(page.nodes[i].rotation - old.rotation) : page.nodes[i].rotation - old.rotation)
            if flipX { page.nodes[i].formatting.flipX.toggle() }
            if flipY { page.nodes[i].formatting.flipY.toggle() }
        }
        transformGroupedEdges(in: &page, from: before, preparedRoutes: preparedRoutes)
    }
    static func transformGroupedEdges(
        in page: inout DiagramPage, from before: DiagramPage, preparedRoutes: [UUID: [CGPoint]]? = nil
    ) {
        let oldNodes = Dictionary(uniqueKeysWithValues: before.nodes.map { ($0.id, $0) })
        let newNodes = Dictionary(uniqueKeysWithValues: page.nodes.map { ($0.id, $0) })
        let oldEdges = Dictionary(uniqueKeysWithValues: before.edges.map { ($0.id, $0) })
        for i in page.edges.indices {
            guard let parentID = page.edges[i].parentID, let old = oldNodes[parentID],
                let new = newNodes[parentID], let edge = oldEdges[page.edges[i].id],
                edge.parentID == parentID,
                old.rect != new.rect || old.rotation != new.rotation
                    || old.formatting.flipX != new.formatting.flipX
                    || old.formatting.flipY != new.formatting.flipY
            else { continue }
            func point(_ p: DiagramPoint) -> DiagramPoint {
                let local = DiagramCoordinates.local(p.cgPoint, in: old)
                return DiagramPoint(
                    DiagramCoordinates.world(
                        CGPoint(x: local.x * new.width / old.width, y: local.y * new.height / old.height),
                        in: new))
            }
            // Gesture previews supply committed routes. A missing prepared
            // entry uses cached points, never the formula-bearing route path.
            let route: [CGPoint]
            if let preparedRoutes {
                route = preparedRoutes[edge.id] ?? edge.points?.map(\.cgPoint) ?? []
            } else {
                route = DiagramGeometry.route(edge, in: before)
            }
            page.edges[i].points = route.map { point(DiagramPoint($0)) }
            page.edges[i].sourcePosition = edge.sourcePosition.map(point)
            page.edges[i].targetPosition = edge.targetPosition.map(point)
        }
    }
    static func commonGroup(_ source: UUID, _ target: UUID, in page: DiagramPage) -> UUID? {
        let nodes = Dictionary(uniqueKeysWithValues: page.nodes.map { ($0.id, $0) })
        func ancestors(_ id: UUID) -> [UUID] {
            var result: [UUID] = []
            var next = nodes[id]?.parentID
            for _ in 0..<64 {
                guard let id = next, let node = nodes[id], !result.contains(id) else { break }
                result.append(id)
                next = node.parentID
            }
            return result
        }
        let targets = Set(ancestors(target))
        return ancestors(source).first { targets.contains($0) }
    }
    @discardableResult static func group(
        _ selected: Set<UUID>, in page: inout DiagramPage, binding: VisioPageBinding? = nil
    ) throws -> UUID {
        let roots = self.roots(selected, in: page)
        let nodes = page.nodes.filter { roots.contains($0.id) }
        guard nodes.count >= 2, !nodes.contains(where: { page.isLocked($0) }) else {
            throw DiagramError.invalid("Select at least two unlocked shapes to group.")
        }
        guard Set(nodes.map(\.parentID)).count == 1 else {
            throw DiagramError.invalid("Shapes must belong to the same group to be grouped together.")
        }
        for i in page.nodes.indices where page.nodes[i].formatting.sourceShapeID == nil {
            page.nodes[i].formatting.sourceShapeID = binding?.nodeIDs[page.nodes[i].id] ?? String(i + 1)
        }
        for i in page.edges.indices where page.edges[i].sourceShapeID == nil {
            page.edges[i].sourceShapeID =
                binding?.edgeIDs[page.edges[i].id] ?? String(page.nodes.count + i + 1)
        }
        let rect = nodes.reduce(CGRect.null) { $0.union($1.rect) }
        var group = DiagramNode(x: rect.minX, y: rect.minY, text: "")
        group.width = max(1, rect.width)
        group.height = max(1, rect.height)
        group.fill = "#FFFFFF00"
        group.stroke = "#FFFFFF00"
        group.formatting.isGroup = true
        group.parentID = nodes[0].parentID
        let nodeIDs: [String] = page.nodes.enumerated().map { index, node in
            node.formatting.sourceShapeID ?? String(index + 1)
        }
        let edgeIDs: [String] = page.edges.enumerated().map { index, edge in
            edge.sourceShapeID ?? String(page.nodes.count + index + 1)
        }
        let boundNodeIDs: [String] = binding.map { Array($0.nodeIDs.values) } ?? []
        let boundEdgeIDs: [String] = binding.map { Array($0.edgeIDs.values) } ?? []
        let reserved = nodeIDs + edgeIDs + boundNodeIDs + boundEdgeIDs
        var allocator = try VisioIDAllocator(reserved: reserved)
        group.formatting.sourceShapeID = try allocator.allocate()
        let insert = page.nodes.firstIndex(where: { roots.contains($0.id) }) ?? 0
        for i in page.nodes.indices where roots.contains(page.nodes[i].id) {
            page.nodes[i].parentID = group.id
        }
        let members = expandedSelection(roots, in: page)
        for i in page.edges.indices
        where page.edges[i].parentID == group.parentID && members.contains(page.edges[i].source)
            && members.contains(page.edges[i].target)
        { page.edges[i].parentID = group.id }
        page.nodes.insert(group, at: insert)
        return group.id
    }
    static func ungroup(_ selected: Set<UUID>, in page: inout DiagramPage) -> Set<UUID> {
        var result = Set<UUID>()
        let selectedRoots = roots(selected, in: page)
        for group in page.nodes
        where selectedRoots.contains(group.id) && group.formatting.isGroup && !page.isLocked(group) {
            let routes = Dictionary(
                uniqueKeysWithValues: page.edges.map { ($0.id, DiagramGeometry.route($0, in: page)) })
            for i in page.nodes.indices where page.nodes[i].parentID == group.id {
                page.nodes[i].parentID = group.parentID
                result.insert(page.nodes[i].id)
            }
            page.nodes.removeAll { $0.id == group.id }
            // A connector glued to a group cannot remain glued to a removed container.
            for i in page.edges.indices {
                if page.edges[i].parentID == group.id { page.edges[i].parentID = group.parentID }
                if page.edges[i].source == group.id {
                    page.edges[i].sourcePosition =
                        routes[page.edges[i].id]?.first.map(DiagramPoint.init) ?? DiagramPoint(group.center)
                }
                if page.edges[i].target == group.id {
                    page.edges[i].targetPosition =
                        routes[page.edges[i].id]?.last.map(DiagramPoint.init) ?? DiagramPoint(group.center)
                }
            }
        }
        return result
    }
}
