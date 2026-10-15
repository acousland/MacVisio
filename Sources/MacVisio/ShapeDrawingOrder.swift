import Foundation

/// Flattens a page's shape hierarchy into the order in which its shapes should
/// be drawn. Sibling order follows the source array and every group's
/// descendants remain together as one drawing block.
enum ShapeDrawingOrder {
    static func ordered<Node>(
        _ nodes: [Node],
        id: KeyPath<Node, UUID>,
        parentID: KeyPath<Node, UUID?>,
        isGroup: (Node) -> Bool,
        displayMode: (Node) -> Int?
    ) -> [Node] {
        guard !nodes.isEmpty else { return [] }

        // The first occurrence gives malformed duplicate IDs a stable parent
        // target without trapping while building the lookup.
        var indexByID: [UUID: Int] = [:]
        for (index, node) in nodes.enumerated() where indexByID[node[keyPath: id]] == nil {
            indexByID[node[keyPath: id]] = index
        }

        var children = Array(repeating: [Int](), count: nodes.count)
        var roots: [Int] = []
        for (index, node) in nodes.enumerated() {
            if let parent = node[keyPath: parentID],
               let parentIndex = indexByID[parent],
               parentIndex != index,
               isGroup(nodes[parentIndex]) {
                children[parentIndex].append(index)
            } else {
                roots.append(index)
            }
        }

        var result: [Node] = []
        var visited = Set<Int>()

        func appendSubtree(_ index: Int) {
            guard visited.insert(index).inserted else { return }
            let node = nodes[index]
            guard isGroup(node) else {
                result.append(node)
                return
            }

            let mode = displayMode(node) ?? 2
            if mode == 1 { result.append(node) }
            for child in children[index] { appendSubtree(child) }
            if mode == 2 || (mode != 0 && mode != 1) { result.append(node) }
        }

        for index in roots { appendSubtree(index) }

        // A malformed parent cycle has no root. Start any still-unvisited
        // component at its earliest source node; `visited` prevents recursion
        // from repeating a node and each shape is emitted at most once.
        for index in nodes.indices where !visited.contains(index) { appendSubtree(index) }
        return result
    }
}
