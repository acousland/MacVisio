import AppKit

/// Page scope is essential: composed background and foreground objects can have
/// the same UUID. Array positions are never accessibility identities.
struct CanvasObjectKey: Hashable {
    var pageID: UUID
    var element: PageElementID
    var identifier: String {
        switch element {
        case .node(let id): return "canvas.\(pageID.uuidString).shape.\(id.uuidString)"
        case .edge(let id): return "canvas.\(pageID.uuidString).connector.\(id.uuidString)"
        }
    }
}

/// AppKit objects refer back to the current prepared scene. They own no model,
/// calculation session or source archive, and stale objects cannot perform edits.
final class CanvasAccessibility {
    weak var canvas: CanvasView?
    private var cache: [CanvasObjectKey: CanvasObjectAccessibilityElement] = [:]
    init(canvas: CanvasView) { self.canvas = canvas }

    var keys: [CanvasObjectKey] {
        guard let canvas, canvas.editor != nil else { return [] }
        return canvas.renderScene.layers.flatMap { layer in
            layer.runtime.paintOrder.compactMap { item in
                let visible: Bool
                switch item {
                case .node(let id): visible = layer.runtime.isVisible(nodeID: id)
                case .edge(let id): visible = layer.runtime.isVisible(edgeID: id)
                }
                return visible ? CanvasObjectKey(pageID: layer.page.id, element: item) : nil
            }
        }
    }
    var foregroundKeys: [CanvasObjectKey] {
        guard let canvas, canvas.editor != nil else { return [] }
        return keys.filter { $0.pageID == canvas.page.id }
    }
    func elements() -> [CanvasObjectAccessibilityElement] {
        let current = keys
        let live = Set(current)
        cache = cache.filter { live.contains($0.key) }
        return current.map(element)
    }
    func element(_ key: CanvasObjectKey) -> CanvasObjectAccessibilityElement {
        if let value = cache[key] { return value }
        let value = CanvasObjectAccessibilityElement(graph: self, key: key)
        cache[key] = value
        return value
    }
    func layer(_ key: CanvasObjectKey) -> RetainedRenderPage? {
        guard let canvas, canvas.editor != nil else { return nil }
        return canvas.renderScene.layers.first { $0.page.id == key.pageID }
    }
    func isPresent(_ key: CanvasObjectKey) -> Bool {
        guard let layer = layer(key) else { return false }
        switch key.element {
        case .node(let id): return layer.runtime.isVisible(nodeID: id)
        case .edge(let id): return layer.runtime.isVisible(edgeID: id)
        }
    }
    func drawingBounds(_ key: CanvasObjectKey) -> CGRect? {
        guard isPresent(key), let layer = layer(key) else { return nil }
        switch key.element {
        case .node(let id): return layer.runtime.nodeBoundsByID[id]
        case .edge(let id): return layer.runtime.edgeBoundsByID[id]
        }
    }
    func canvasBounds(_ key: CanvasObjectKey) -> CGRect? {
        guard let canvas, let layer = layer(key), let bounds = drawingBounds(key) else { return nil }
        let offset = canvas.renderScene.scene.offset(for: layer.page)
        return CGRect(
            x: canvas.pageOrigin.x + (bounds.minX * layer.page.paperScale + offset.x) * canvas.zoom,
            y: canvas.pageOrigin.y + (bounds.minY * layer.page.paperScale + offset.y) * canvas.zoom,
            width: bounds.width * layer.page.paperScale * canvas.zoom,
            height: bounds.height * layer.page.paperScale * canvas.zoom)
    }
    func label(_ key: CanvasObjectKey) -> String {
        guard let layer = layer(key) else { return "Unavailable drawing object" }
        let prefix = key.pageID == canvas?.page.id ? "" : "Background \(layer.page.name), "
        switch key.element {
        case .node(let id):
            guard let node = layer.runtime.nodesByID[id] else { return "Unavailable shape" }
            let text = Self.alternativeDescription(node) ?? node.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let kind = node.formatting.isGroup ? "Group" : node.kind.title
            return prefix + (text.isEmpty ? kind : "\(text), \(kind)")
        case .edge(let id):
            guard let edge = layer.runtime.edgesByID[id] else { return "Unavailable connector" }
            func endpoint(_ id: UUID) -> String {
                guard let node = layer.runtime.nodesByID[id] else { return "free endpoint" }
                let name = Self.alternativeDescription(node) ?? node.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return name.isEmpty ? node.kind.title : name
            }
            let name = edge.label.isEmpty ? "Connector" : "\(edge.label), Connector"
            return prefix + "\(name), from \(endpoint(edge.source)) to \(endpoint(edge.target))"
        }
    }
    private static func alternativeDescription(_ node: DiagramNode) -> String? {
        for name in ["AltText", "AccessibilityDescription"] {
            for property in node.formatting.data where property.key.caseInsensitiveCompare(name) == .orderedSame {
                let text = property.value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }
    func relations(_ key: CanvasObjectKey) -> [CanvasObjectAccessibilityElement] {
        guard let layer = layer(key) else { return [] }
        var related: [PageElementID] = []
        switch key.element {
        case .node(let id):
            if let parent = layer.runtime.parentByID[id] { related.append(.node(parent)) }
            // Keep group members and incident connections in the same prepared order.
            let children = layer.runtime.childrenByParent[id] ?? []
            let edges = layer.runtime.edgesByEndpoint[id] ?? []
            related += layer.runtime.paintOrder.filter {
                switch $0 {
                case .node(let node): return children.contains(node)
                case .edge(let edge): return edges.contains(edge) || layer.runtime.edgeParentByID[edge] == id
                }
            }
        case .edge(let id):
            if let edge = layer.runtime.edgesByID[id] {
                related = [.node(edge.source), .node(edge.target)]
                if let parent = edge.parentID { related.append(.node(parent)) }
            }
        }
        var seen = Set<CanvasObjectKey>()
        return related.compactMap {
            let relatedKey = CanvasObjectKey(pageID: key.pageID, element: $0)
            return isPresent(relatedKey) && seen.insert(relatedKey).inserted ? element(relatedKey) : nil
        }
    }
    func help(_ key: CanvasObjectKey) -> String {
        guard let layer = layer(key), isPresent(key) else { return "This object is no longer visible." }
        guard key.pageID == canvas?.page.id else { return "Background content. Open its page to edit it." }
        switch key.element {
        case .node(let id):
            var parts = ["Option-Tab moves through drawing objects. Tab leaves the canvas."]
            if let parent = layer.runtime.parentByID[id] {
                parts.append("Member of \(label(CanvasObjectKey(pageID: key.pageID, element: .node(parent)))).")
            }
            if layer.runtime.isLocked(nodeID: id) { parts.append("Shape, group or layer is locked. Selection and inspection remain available.") }
            else { parts.append("Arrows move; Option-arrows resize; Shift increases the step. Return edits text. C starts a connection, then traverse to a target and press Return. Escape cancels.") }
            return parts.joined(separator: " ")
        case .edge:
            return "Connector endpoints and group are linked objects. Press to select and inspect. Option-Tab moves through drawing objects; Tab leaves the canvas."
        }
    }
}

final class CanvasObjectAccessibilityElement: NSAccessibilityElement {
    weak var graph: CanvasAccessibility?
    let key: CanvasObjectKey
    init(graph: CanvasAccessibility, key: CanvasObjectKey) {
        self.graph = graph
        self.key = key
        super.init()
        setAccessibilityIdentifier(key.identifier)
        setAccessibilityRole(.layoutItem)
        setAccessibilityElement(true)
    }
    override func accessibilityParent() -> Any? { graph?.canvas }
    override func accessibilityLabel() -> String? { graph?.label(key) }
    override func accessibilityHelp() -> String? { graph?.help(key) }
    override func accessibilityFrame() -> NSRect {
        guard let canvas = graph?.canvas, let window = canvas.window,
              let bounds = graph?.canvasBounds(key) else { return .zero }
        return window.convertToScreen(canvas.convert(bounds, to: nil))
    }
    override func accessibilityLinkedUIElements() -> [Any]? { graph?.relations(key) }
    override func isAccessibilitySelected() -> Bool {
        guard let canvas = graph?.canvas, canvas.editor != nil, key.pageID == canvas.page.id else { return false }
        switch key.element {
        case .node(let id): return canvas.selectedNodes.contains(id)
        case .edge(let id): return canvas.selectedEdge == id
        }
    }
    override func isAccessibilityFocused() -> Bool {
        guard let graph, graph.isPresent(key), let canvas = graph.canvas else { return false }
        return canvas.window?.firstResponder === canvas && canvas.keyboardFocusedObject == key
    }
    override func setAccessibilityFocused(_ value: Bool) {
        if value { _ = graph?.canvas?.focusCanvasObject(key) }
    }
    override func accessibilityPerformPress() -> Bool { graph?.canvas?.focusCanvasObject(key) ?? false }
    override func accessibilityPerformPick() -> Bool { accessibilityPerformPress() }
    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard let graph, let canvas = graph.canvas, canvas.editor != nil,
              key.pageID == canvas.page.id, graph.isPresent(key) else { return [] }
        var actions = [NSAccessibilityCustomAction(name: "Select and inspect") { [weak self] in self?.accessibilityPerformPress() ?? false }]
        if case .node(let id) = key.element {
            actions.append(NSAccessibilityCustomAction(name: "Edit text") { [weak canvas] in
                guard let canvas, canvas.focusCanvasObject(self.key) else { return false }
                return canvas.editCanvasObjectText(id)
            })
            for (name, dx, dy) in [("Move left", -1.0, 0.0), ("Move right", 1, 0), ("Move up", 0, -1), ("Move down", 0, 1)] {
                actions.append(NSAccessibilityCustomAction(name: name) { [weak canvas] in
                    guard let canvas, canvas.focusCanvasObject(self.key) else { return false }
                    return canvas.transformKeyboardSelection(dx: dx, dy: dy, resize: false)
                })
            }
            actions.append(NSAccessibilityCustomAction(name: "Start connection") { [weak canvas] in
                guard let canvas, canvas.focusCanvasObject(self.key) else { return false }
                return canvas.startKeyboardConnection()
            })
            if canvas.pendingSource != nil {
                actions.append(NSAccessibilityCustomAction(name: "Connect to this shape") { [weak canvas] in
                    guard let canvas, canvas.focusCanvasObject(self.key) else { return false }
                    return canvas.confirmKeyboardConnection()
                })
            }
        }
        return actions
    }
}

extension CanvasView {
    @discardableResult func focusCanvasObject(_ key: CanvasObjectKey) -> Bool {
        guard editor != nil, key.pageID == page.id, accessibilityGraph.isPresent(key) else { return false }
        finishEditing(commit: true)
        keyboardFocusedObject = key
        switch key.element {
        case .node(let id): select([id])
        case .edge(let id): select([], edge: id)
        }
        window?.makeFirstResponder(self)
        if let bounds = accessibilityGraph.canvasBounds(key) { scrollToVisible(bounds.insetBy(dx: -20, dy: -20)) }
        NSAccessibility.post(element: accessibilityGraph.element(key), notification: .focusedUIElementChanged)
        needsDisplay = true
        return true
    }
    func traverseCanvasObjects(backward: Bool) {
        let keys = accessibilityGraph.foregroundKeys
        guard !keys.isEmpty else { leaveCanvas(backward: backward); return }
        let current = keyboardFocusedObject ?? keys.first(where: {
            switch $0.element {
            case .node(let id): return selectedNodes.contains(id)
            case .edge(let id): return selectedEdge == id
            }
        })
        if let current, let index = keys.firstIndex(of: current) {
            let next = index + (backward ? -1 : 1)
            guard keys.indices.contains(next) else { leaveCanvas(backward: backward); return }
            _ = focusCanvasObject(keys[next])
        } else { _ = focusCanvasObject(backward ? keys[keys.count - 1] : keys[0]) }
    }
    func leaveCanvas(backward: Bool) {
        keyboardFocusedObject = nil
        if pendingSource != nil {
            pendingSource = nil
            pendingSourcePort = nil
            editor?.setTool(.pointer)
            explainCanvasAction("Connection cancelled.")
        }
        if backward { window?.selectPreviousKeyView(self) } else { window?.selectNextKeyView(self) }
        // AppKit may find only this view when all surrounding controls are
        // disabled/hidden or the system's keyboard-access policy excludes them.
        // Hand response to the window rather than wrapping back into the graph.
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        needsDisplay = true
    }
    func explainCanvasAction(_ message: String) {
        editor?.root.showMessage(message)
        NSAccessibility.post(element: NSApp, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
    @discardableResult func editCanvasObjectText(_ id: UUID) -> Bool {
        guard editor != nil else { return false }
        guard let node = document.diagram.page.nodes.first(where: { $0.id == id }) else { return false }
        if let reason = NativeEditProtection.blockReason(for: "Text", node: node, in: document.diagram.page) {
            explainCanvasAction(reason); return false
        }
        beginEditing(id)
        return isEditingText
    }
    @discardableResult func transformKeyboardSelection(dx: Double, dy: Double, resize: Bool) -> Bool {
        guard let editor, !selectedNodes.isEmpty else { return false }
        guard !document.isCalculating, interactionPreview == nil else {
            explainCanvasAction("Finish the current gesture or calculation before editing shapes."); return false
        }
        let runtime = renderScene.foreground.runtime
        let roots = DiagramOperations.roots(selectedNodes, in: page)
        for id in roots {
            for affected in runtime.descendants(of: id) {
                if (runtime.edgesByParent[affected] ?? []).contains(where: { runtime.isLocked(edgeID: $0) }) {
                    explainCanvasAction("A connector in the selected group is on a locked layer."); return false
                }
                guard let node = runtime.nodesByID[affected] else { return false }
                let keys = [dx == 0 ? nil : resize ? "Width" : "X",
                            dy == 0 ? nil : resize ? "Height" : "Y"].compactMap { $0 }
                    + (resize && affected != id ? [dx == 0 ? nil : "X", dy == 0 ? nil : "Y"].compactMap { $0 } : [])
                for key in keys {
                    if let reason = NativeEditProtection.blockReason(for: key, node: node, in: document.diagram.page) {
                        explainCanvasAction(reason); return false
                    }
                }
            }
        }
        let group = roots.compactMap { runtime.nodesByID[$0]?.rect }.reduce(CGRect.null) { $0.union($1) }
        let moveX = resize ? dx : max(-group.minX, min(page.width - group.maxX, dx))
        let moveY = resize ? dy : max(-group.minY, min(page.height - group.maxY, dy))
        editor.modifySelection(resize ? "Resize Shapes" : "Nudge Shapes") { node in
            if resize {
                node.width = max(1, min(self.page.width - node.x, node.width + dx))
                node.height = max(1, min(self.page.height - node.y, node.height + dy))
            } else { node.x += moveX; node.y += moveY }
        }
        return true
    }
    @discardableResult func startKeyboardConnection() -> Bool {
        guard let editor, selectedNodes.count == 1, let source = selectedNodes.first,
              let node = renderScene.foreground.runtime.nodesByID[source], node.kind != .swimlane,
              !renderScene.foreground.runtime.isLocked(nodeID: source), page.permitsGlue(to: node) else {
            explainCanvasAction("Select an unlocked shape on a layer that permits glue to start a connection.")
            return false
        }
        guard !document.isCalculating, interactionPreview == nil else {
            explainCanvasAction("Finish the current gesture or calculation before connecting shapes."); return false
        }
        if let reason = NativeEditProtection.blockReason(for: "Connection", node: node, in: document.diagram.page) {
            explainCanvasAction(reason); return false
        }
        editor.setTool(.connector)
        pendingSource = source
        keyboardFocusedObject = CanvasObjectKey(pageID: page.id, element: .node(source))
        explainCanvasAction("Connection started. Option-Tab to a destination, Return to connect, Escape to cancel.")
        needsDisplay = true
        return true
    }
    @discardableResult func confirmKeyboardConnection() -> Bool {
        guard let editor, let source = pendingSource, selectedNodes.count == 1,
              let target = selectedNodes.first, source != target,
              let sourceNode = renderScene.foreground.runtime.nodesByID[source],
              let targetNode = renderScene.foreground.runtime.nodesByID[target],
              !renderScene.foreground.runtime.isLocked(nodeID: source),
              !renderScene.foreground.runtime.isLocked(nodeID: target), targetNode.kind != .swimlane,
              page.permitsGlue(to: sourceNode), page.permitsGlue(to: targetNode) else {
            explainCanvasAction("Choose a different unlocked destination shape on a layer that permits glue.")
            return false
        }
        guard !document.isCalculating, interactionPreview == nil else {
            explainCanvasAction("Finish the current gesture or calculation before connecting shapes."); return false
        }
        for node in [sourceNode, targetNode] {
            if let reason = NativeEditProtection.blockReason(for: "Connection", node: node, in: document.diagram.page) {
                explainCanvasAction(reason); return false
            }
        }
        editor.connect(source, to: target)
        pendingSource = nil
        pendingSourcePort = nil
        editor.setTool(.pointer)
        if let id = selectedEdge { keyboardFocusedObject = CanvasObjectKey(pageID: page.id, element: .edge(id)) }
        return true
    }
}
