import Foundation

/// Visio's container behaviour for shapes the user drags, measured with real drags in Visio 2019
/// (scripts/windows/Probe-VisioContainers.ps1, Tests/.../Reference/visio-containers.vsdx):
/// - a dragged shape belongs to every container its centre lands in, except a container that holds
///   another of those containers (nested containers keep the shape in the innermost);
/// - it leaves a container once its centre is outside, even while it still overlaps the edge;
/// - a container whose resize policy expands as needed (the masters' default) grows to keep its
///   members inside its margin, outside its heading.
enum ContainerDrops {
    /// `dragged` are the shapes the user picked up; `moving` adds the members carried by dragged containers.
    static func apply(to diagram: Diagram, pageID: UUID, dragged: Set<UUID>, moving: Set<UUID>) -> Diagram {
        guard let pageIndex = diagram.pages.firstIndex(where: { $0.id == pageID }) else { return diagram }
        let page = diagram.pages[pageIndex]
        let containers = page.nodes.filter { isContainer($0) && !moving.contains($0.id) }
        let roots = page.nodes.filter { dragged.contains($0.id) && $0.parentID == nil }
        guard !containers.isEmpty, !roots.isEmpty,
              let index = try? DiagramMemberships.index(in: diagram, pageID: pageID) else { return diagram }
        var result = diagram
        var grown: [UUID] = []
        for node in roots {
            let centre = CGPoint(x: node.rect.midX, y: node.rect.midY)
            let landed = containers.filter { $0.id != node.id && $0.rect.contains(centre) }.map(\.id)
            let targets = landed.filter { outer in !landed.contains { $0 != outer && holds(outer, $0, index) } }
            let current = index.containers.map(\.id).filter { index.contains(member: node.id, container: $0) }
            for (id, included) in current.filter({ !targets.contains($0) }).map({ ($0, false) }) + targets.filter({ !current.contains($0) }).map({ ($0, true) }) {
                // Locked memberships and category policies refuse, as Visio's do; the move itself stands.
                if let next = try? DiagramMemberships.settingMembership(in: result, pageID: pageID, memberID: node.id, containerID: id, included: included) {
                    result = next
                }
            }
            grown += targets
        }
        // Expanding a container can push it past the edge of a container that holds it.
        var pending = grown, visited = 0
        while let id = pending.popLast(), visited < 64 {
            visited += 1
            guard expand(id, in: &result, pageIndex: pageIndex) else { continue }
            if let index = try? DiagramMemberships.index(in: result, pageID: pageID) {
                pending += index.containers.map(\.id).filter { index.contains(member: id, container: $0) }
            }
        }
        return result
    }

    static func isContainer(_ node: DiagramNode) -> Bool {
        DiagramMemberships.literalRole(node.formatting.sheet["User.msvStructureType"]) == .container
    }

    /// Whether `inner` is (transitively) a member of `outer`.
    private static func holds(_ outer: UUID, _ inner: UUID, _ index: DiagramMemberships.Index) -> Bool {
        var pending = [inner], seen = Set<UUID>()
        while let next = pending.popLast(), seen.insert(next).inserted {
            for relation in index.outgoing[next, default: []] where relation.kind == .containers {
                if relation.target == outer { return true }
                pending.append(relation.target)
            }
        }
        return false
    }

    /// Grows the container to contain its members plus margin. Returns whether it changed.
    @discardableResult static func expand(_ id: UUID, in diagram: inout Diagram, pageIndex: Int) -> Bool {
        let page = diagram.pages[pageIndex]
        guard let offset = page.nodes.firstIndex(where: { $0.id == id }) else { return false }
        let container = page.nodes[offset]
        let policy = container.formatting.sheet["User.msvSDContainerResize"]
        // Absent, the container master's policy applies; Visio's masters expand as needed (1).
        guard (policy.map { DiagramMemberships.literalNumber($0) } ?? 1) ?? 0 != 0, container.rotation == 0,
              NativeEditProtection.blockReason(for: "Width", node: container, in: page) == nil,
              NativeEditProtection.blockReason(for: "Height", node: container, in: page) == nil else { return false }
        let memberIDs = DiagramMemberships.movingMembers(of: [id], in: diagram, pageID: page.id)
        let members = page.nodes.filter { $0.parentID == nil && memberIDs.contains($0.id) }
        guard !members.isEmpty else { return false }
        let margin = container.formatting.sheet["User.msvSDContainerMargin"].flatMap { Double($0.value) }.map { $0 * 72 } ?? 3 / 25.4 * 72
        let inset = headingInsets(container, in: page)
        var rect = container.rect
        for member in members {
            let needed = member.rect.insetBy(dx: -margin, dy: -margin)
            let minX = min(rect.minX, needed.minX - inset.left), maxX = max(rect.maxX, needed.maxX + inset.right)
            let minY = min(rect.minY, needed.minY - inset.top), maxY = max(rect.maxY, needed.maxY + inset.bottom)
            rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        guard rect.insetBy(dx: 1e-6, dy: 1e-6) != container.rect.insetBy(dx: 1e-6, dy: 1e-6),
              !container.rect.contains(rect) else { return false }
        var grown = container
        grown.x = rect.minX; grown.y = rect.minY; grown.width = rect.width; grown.height = rect.height
        diagram.pages[pageIndex].nodes[offset] = grown
        DiagramOperations.transformChildren(in: &diagram.pages[pageIndex], from: container, to: grown)
        return true
    }

    /// A heading is a sub-shape spanning one whole side of the container; members stay clear of it.
    static func headingInsets(_ container: DiagramNode, in page: DiagramPage) -> (left: Double, right: Double, top: Double, bottom: Double) {
        var inset = (left: 0.0, right: 0.0, top: 0.0, bottom: 0.0)
        let r = container.rect, tolerance = 0.5
        for child in page.nodes where child.parentID == container.id {
            let c = child.rect
            if c.width >= r.width * 0.9, c.height < r.height * 0.5 {
                if abs(c.minY - r.minY) < tolerance { inset.top = max(inset.top, c.height) }
                else if abs(c.maxY - r.maxY) < tolerance { inset.bottom = max(inset.bottom, c.height) }
            } else if c.height >= r.height * 0.9, c.width < r.width * 0.5 {
                if abs(c.minX - r.minX) < tolerance { inset.left = max(inset.left, c.width) }
                else if abs(c.maxX - r.maxX) < tolerance { inset.right = max(inset.right, c.width) }
            }
        }
        return inset
    }
}
