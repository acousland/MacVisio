import AppKit
import MacVisioInfrastructure

struct RenderObjectID: Hashable {
    let pageID: UUID
    let nodeID: UUID
}

/// AppKit text/font work is owned by the main thread. These prepared values
/// contain no formula host and are reused by screen and publication drawing.
final class PreparedNodeDrawing {
    let input: DiagramNode
    let paperScale: Double
    let outline: NSBezierPath
    let vectors: [NSBezierPath]
    let text: NSAttributedString
    let textRect: CGRect
    let textCenter: CGPoint
    let textRotation: Double
    let cost: Int

    init(_ input: DiagramNode, paperScale: Double) {
        self.input = input
        self.paperScale = paperScale
        outline = DiagramDrawing.outline(for: input)
        vectors = input.formatting.paths.map { DiagramDrawing.vectorPath($0, in: input.rect, rounding: DiagramDrawing.roundingRadius(of: input)) }
        let paperNode = DrawingScale.paperNode(input, factor: paperScale)
        let layout = DiagramDrawing.textLayout(for: paperNode)
        textCenter = layout.center
        textRotation = layout.rotation
        let attributed = ShapeRichText.attributed(paperNode)
        text = attributed
        var rect = layout.rect
        let measured = PerformanceEvidence.measure(.textLayout) {
            PerformanceEvidence.count(.textMeasurements)
            return attributed.boundingRect(
                with: CGSize(width: max(1, rect.width), height: 10000),
                options: [.usesLineFragmentOrigin])
        }
        (rect.origin.y, rect.size.height) = DiagramDrawing.alignedText(height: ceil(measured.height), in: rect, vertical: DiagramDrawing.verticalAlignment(of: paperNode))
        textRect = rect
        // The retained input shares the drawing's storage, so only what preparation builds is charged: paths
        // and laid-out text. Charging the shape's whole encoding (and encoding it) let a large stencil page
        // overflow the cache, so panning re-prepared shapes on every frame.
        let drawingCost =
            512 + text.length * 16 + (outline.elementCount + vectors.reduce(0) { $0 + $1.elementCount }) * 64
        cost = drawingCost
    }
}

final class PreparedEdgeLabel {
    private struct Input: Codable, Equatable {
        let text: String
        let color: String
        let runs: [ShapeTextRun]?
        init(_ edge: DiagramEdge) {
            text = edge.label; color = edge.color
            let details = edge.formatting
            let styled = details.textRuns != nil || details.fontName != "System"
                || details.italic || details.underline || details.alignment != .center
                || details.sheet["Char.Size"] != nil
            runs = styled ? ShapeRichText.runs(for: edge.textNode) : nil
        }
    }
    private let input: Input
    private let richNode: DiagramNode?
    let attributed: NSAttributedString
    let attributes: [NSAttributedString.Key: Any]
    let size: CGSize
    let paintBounds: CGRect
    let cost: Int
    var text: String { input.text }
    var color: String { input.color }
    var isRich: Bool { richNode != nil }

    func matches(_ edge: DiagramEdge) -> Bool { input == Input(edge) }

    init(_ edge: DiagramEdge, previous: PreparedEdgeLabel? = nil) {
        let input = Input(edge); self.input = input
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor(hex: edge.color),
        ]
        self.attributes = attributes
        let attributed: NSAttributedString
        if let runs = input.runs {
            var node = DiagramNode(kind: .text, text: input.text)
            node.id = edge.id; node.formatting.textRuns = runs
            richNode = node; attributed = ShapeRichText.attributed(node)
        } else {
            richNode = nil; attributed = NSAttributedString(string: input.text, attributes: attributes)
        }
        self.attributed = attributed
        // A plain label's stroke color does not change its measured extent.
        if let previous, previous.input.text == input.text, previous.input.runs == input.runs {
            size = previous.size
        } else {
            size = PerformanceEvidence.measure(.textLayout) {
                PerformanceEvidence.count(.textMeasurements)
                if input.runs == nil { return (input.text as NSString).size(withAttributes: attributes) }
                let bounds = attributed.boundingRect(with: CGSize(width: 100000, height: 100000),
                    options: [.usesLineFragmentOrigin])
                // The bounding rect leaves out paragraph indents, which the label's layout still applies.
                var indent: CGFloat = 0
                attributed.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
                    guard let style = value as? NSParagraphStyle else { return }
                    indent = max(indent, max(style.headIndent, style.firstLineHeadIndent) + max(0, -style.tailIndent))
                }
                return CGSize(width: max(1, ceil(bounds.width + indent)), height: max(1, ceil(bounds.height)))
            }
        }
        paintBounds = input.runs == nil ? CGRect(origin:.zero,size:size)
            : PublicationBounds.textBounds(attributed,in:CGRect(origin:.zero,size:size))
        let encoded = (try? JSONEncoder().encode(input).count) ?? Int.max
        let payload = encoded.multipliedReportingOverflow(by: 4)
        let textCost = attributed.length.multipliedReportingOverflow(by: 32)
        let sum = payload.partialValue.addingReportingOverflow(textCost.partialValue)
        let total = sum.partialValue.addingReportingOverflow(512)
        cost = payload.overflow || textCost.overflow || sum.overflow || total.overflow ? Int.max : total.partialValue
    }

    func draw(in rect: CGRect) {
        if isRich { attributed.draw(with: rect, options: [.usesLineFragmentOrigin]) }
        else { (text as NSString).draw(at: rect.origin, withAttributes: attributes) }
    }

    func svg(in rect: CGRect) -> String {
        guard let richNode else { return "" }
        return ShapeRichText.svg(richNode, rect: rect, clipRect: paintBounds.offsetBy(dx:rect.minX,dy:rect.minY))
    }
}

struct SceneDrawWork: Equatable {
    var candidates = 0
    var nodesDrawn = 0
    var edgesDrawn = 0
    var nodePreparations = 0
    var routePreparations = 0
}

/// A revision-owned evaluated page. Routes and foreground-specific background
/// fields are prepared before painting/hit testing, never from those methods.
final class RetainedRenderPage {
    private(set) var page: DiagramPage
    let runtime: PageRuntime
    private(set) var routes: [UUID: [CGPoint]] = [:]
    private(set) var routeBounds: [UUID: CGRect] = [:]
    private(set) var routePreparations = 0
    private(set) var routeCandidateVisits = 0
    private var automaticEdges = Set<UUID>()
    private static let sharedNodes = ResourceBudgetCache<RenderObjectID, PreparedNodeDrawing>(
        maximumCount: 4096, maximumCost: ResourceBudgets.retainedPaths)
    private static let sharedLabels = ResourceBudgetCache<RenderObjectID, PreparedEdgeLabel>(
        maximumCount: 4096, maximumCost: ResourceBudgets.retainedText)
    private let nodes = RetainedRenderPage.sharedNodes
    private(set) var connectionPoints: [UUID: [String: CGPoint]] = [:]
    private struct PreviewSource {
        let layer: EvaluatedSceneSnapshot.Layer
        let nodesByID: [UUID: DiagramNode]
    }
    private var previewSource: PreviewSource?
    private var previewRoutingPage: DiagramPage?
    private(set) var previewPortProjectionCount = 0
    private(set) var lastDrawWork = SceneDrawWork()

    init(_ page: DiagramPage) {
        self.page = page
        let preparation = PerformanceEvidence.begin(.scenePreparation)
        defer { PerformanceEvidence.end(preparation) }
        PerformanceEvidence.count(.sceneObjectsPrepared, by: page.nodes.count)
        runtime = PageRuntime(page: page)
        prepareRoutes(changes: nil)
        preparePorts(page.nodes)
    }

    /// Clone evaluated values rather than entering the committed evaluator at
    /// gesture begin. The routing copy below never replaces source model cells.
    init(evaluated layer: EvaluatedSceneSnapshot.Layer) {
        let preparation = PerformanceEvidence.begin(.scenePreparation)
        defer { PerformanceEvidence.end(preparation) }
        PerformanceEvidence.count(.sceneObjectsPrepared, by: layer.page.nodes.count)
        page = layer.page
        runtime = PageRuntime(page: layer.page, preparedRoutes: layer.routes)
        routes = layer.routes
        routeBounds = layer.routeBounds
        connectionPoints = layer.connectionPoints.filter { !$0.value.isEmpty }
        previewSource = PreviewSource(layer: layer, nodesByID: runtime.nodesByID)
        automaticEdges = Set(
            layer.page.edges.filter {
                $0.style == .orthogonal && ($0.points?.count ?? 0) < 2
            }.map(\.id))
        preparePreviewRoutingPage(layer.page, changes: nil)
        runtime.installPreparedEdgeBounds(routeBounds)
        let missing = Set(layer.page.edges.lazy.filter { layer.routes[$0.id] == nil }.map(\.id))
        if !missing.isEmpty {
            prepareRoutes(changes: PageChangeSet(pageID: layer.page.id, changedEdgeIDs: missing))
        }
    }

    var cacheStatistics: ResourceBudgetCache<RenderObjectID, PreparedNodeDrawing>.Statistics {
        nodes.statistics
    }
    var retainedRouteBytes: Int { routes.values.reduce(0) { $0 + $1.count * MemoryLayout<CGPoint>.stride } }

    func update(_ next: DiagramPage) {
        if next == page {
            routePreparations = 0
            routeCandidateVisits = 0
            previewPortProjectionCount = 0
            return
        }
        let changes = PageChangeSet.between(page, next)
        let connectionInputChanges = Set(
            changes.changedNodeIDs.filter { id in
                guard !changes.requiresRuntimeRebuild, let before = runtime.nodesByID[id],
                    let index = runtime.nodeIndexByID[id], next.nodes.indices.contains(index),
                    next.nodes[index].id == id
                else { return true }
                let after = next.nodes[index]
                return changes.geometryChangedNodeIDs.contains(id)
                    || (!after.formatting.connectionPoints.isEmpty
                        && before.formatting.sheet != after.formatting.sheet)
            })
        let obstacleEligibilityChanged = changes.changedNodeIDs.contains { id in
            guard let before = runtime.nodesByID[id], let index = runtime.nodeIndexByID[id],
                next.nodes.indices.contains(index), next.nodes[index].id == id
            else { return true }
            let after = next.nodes[index]
            return before.layer != after.layer
                || before.formatting.layerNames != after.formatting.layerNames
        }
        page = next
        runtime.apply(page: next, changes: changes)
        if previewSource != nil {
            preparePreviewRoutingPage(next, changes: changes)
        } else {
            for id in changes.deletedNodeIDs { connectionPoints[id] = nil }
            preparePorts(changes.affectedNodeIDs.compactMap { runtime.nodesByID[$0] })
        }
        prepareRoutes(
            changes: changes,
            connectionInputChanges: connectionInputChanges.union(changes.insertedNodeIDs),
            obstacleEligibilityChanged: obstacleEligibilityChanged)
    }

    private func preparePorts(_ changed: [DiagramNode]) {
        for node in changed {
            guard !node.formatting.connectionPoints.isEmpty else {
                connectionPoints[node.id] = nil
                continue
            }
            connectionPoints[node.id] = Dictionary(
                uniqueKeysWithValues: node.formatting.connectionPoints.map {
                    ($0.id, ConnectionGeometry.point($0, on: node))
                })
        }
    }

    /// Only geometry is projected during a preview. A port's committed local
    /// normalized position follows the new size/flip/rotation. Arbitrary source
    /// formulas run once on committed release, not during pointer samples.
    private func projectPreviewNode(_ node: DiagramNode) -> (node: DiagramNode, points: [String: CGPoint]) {
        guard let source = previewSource, !node.formatting.connectionPoints.isEmpty else {
            return (node, [:])
        }
        let original = source.nodesByID[node.id] ?? node
        var projected: [String: CGPoint] = [:]
        var details = node.formatting
        for index in details.connectionPoints.indices {
            var port = details.connectionPoints[index]
            let baseline =
                source.layer.connectionPoints[node.id]?[port.id] ?? cachedPortPoint(port, on: original)
            let local = DiagramCoordinates.local(baseline, in: original)
            let normalized = CGPoint(
                x: local.x / max(0.000001, original.width), y: local.y / max(0.000001, original.height))
            let nextLocal = CGPoint(x: normalized.x * node.width, y: normalized.y * node.height)
            let sameTransform =
                node.rect == original.rect && node.rotation == original.rotation
                && node.formatting.flipX == original.formatting.flipX
                && node.formatting.flipY == original.formatting.flipY
            projected[port.id] = sameTransform ? baseline : DiagramCoordinates.world(nextLocal, in: node)
            // ConnectionGeometry's numeric path consumes page-local inches.
            // Clearing formulas is confined to this disposable routing value.
            port.x.value = String((nextLocal.x + node.sheetOrigin.x) / 72)
            port.y.value = String((node.height + node.sheetOrigin.y - nextLocal.y) / 72)
            port.x.formula = ""
            port.y.formula = ""
            details.connectionPoints[index] = port
            previewPortProjectionCount += 1
        }
        var routingNode = node
        routingNode.formatting = details
        return (routingNode, projected)
    }

    private func cachedPortPoint(_ port: ShapeConnectionPoint, on node: DiagramNode) -> CGPoint {
        let x = Double(port.x.value).flatMap { $0.isFinite ? $0 : nil } ?? 0
        let y = Double(port.y.value).flatMap { $0.isFinite ? $0 : nil } ?? 0
        return DiagramCoordinates.world(
            CGPoint(
                x: x * 72 - node.sheetOrigin.x,
                y: node.height - y * 72 + node.sheetOrigin.y), in: node)
    }

    private func preparePreviewRoutingPage(_ next: DiagramPage, changes: PageChangeSet?) {
        previewPortProjectionCount = 0
        if var routing = previewRoutingPage, let changes,
            !changes.requiresRuntimeRebuild, !changes.pagePropertiesChanged
        {
            for id in changes.affectedNodeIDs {
                guard let index = runtime.nodeIndexByID[id], let node = runtime.nodesByID[id] else {
                    continue
                }
                let projection = projectPreviewNode(node)
                routing.nodes[index] = projection.node
                connectionPoints[id] = projection.points.isEmpty ? nil : projection.points
            }
            if !changes.affectedEdgeIDs.isEmpty { routing.edges = next.edges }
            previewRoutingPage = routing
        } else {
            var routing = next
            connectionPoints = [:]
            for index in next.nodes.indices where !next.nodes[index].formatting.connectionPoints.isEmpty {
                let projection = projectPreviewNode(next.nodes[index])
                routing.nodes[index] = projection.node
                connectionPoints[next.nodes[index].id] = projection.points
            }
            previewRoutingPage = routing
        }
    }

    private func prepareRoutes(
        changes: PageChangeSet?, connectionInputChanges: Set<UUID> = [],
        obstacleEligibilityChanged: Bool = false
    ) {
        routePreparations = 0
        routeCandidateVisits = 0
        let all =
            changes == nil || (changes!.requiresRuntimeRebuild && runtime.lastUpdateWork.didRebuild)
            || changes!.pagePropertiesChanged
        if all {
            automaticEdges = Set(
                page.edges.filter { $0.style == .orthogonal && ($0.points?.count ?? 0) < 2 }.map(\.id))
            routeCandidateVisits += page.edges.count
        } else {
            for id in changes!.affectedEdgeIDs {
                if let edge = runtime.edgesByID[id], edge.style == .orthogonal, (edge.points?.count ?? 0) < 2
                {
                    automaticEdges.insert(id)
                } else {
                    automaticEdges.remove(id)
                }
            }
        }
        let obstacleChanged =
            all || obstacleEligibilityChanged || !(changes?.geometryChangedNodeIDs.isEmpty ?? true)
            || !(changes?.insertedNodeIDs.isEmpty ?? true) || !(changes?.deletedNodeIDs.isEmpty ?? true)
        var affected = changes?.affectedEdgeIDs ?? []
        if obstacleChanged {
            // Removing an obstacle can enable a shorter path outside the old
            // route. Automatic routes use an explicitly counted full fallback.
            affected.formUnion(automaticEdges)
            routeCandidateVisits += automaticEdges.count
        }
        for id in connectionInputChanges { affected.formUnion(runtime.edgesByEndpoint[id] ?? []) }
        for id in changes?.deletedEdgeIDs ?? [] {
            routes[id] = nil
            routeBounds[id] = nil
        }
        var bounds: [UUID: CGRect] = [:]
        let routeIDs = all ? page.edges.map(\.id) : Array(affected)
        for id in routeIDs {
            guard let edge = runtime.edgesByID[id] else { continue }
            routeCandidateVisits += 1
            let route = DiagramGeometry.route(edge, in: previewRoutingPage ?? page)
            PerformanceEvidence.count(.renderRoutesPrepared)
            routes[edge.id] = route
            routePreparations += 1
            var rect = route.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
            if !edge.label.isEmpty, let first = route.first, let last = route.last {
                let midpoint =
                    route.count > 2
                    ? CGPoint(x: (route[1].x + route[2].x) / 2, y: (route[1].y + route[2].y) / 2)
                    : CGPoint(x: (first.x + last.x) / 2, y: (first.y + last.y) / 2)
                let label = preparedLabel(edge)!,size = label.size
                let ink = label.paintBounds.offsetBy(dx:midpoint.x*page.paperScale-size.width/2,
                                                    dy:midpoint.y*page.paperScale-size.height/2)
                rect = rect.union(CGRect(x:ink.minX/page.paperScale,y:ink.minY/page.paperScale,
                                         width:ink.width/page.paperScale,height:ink.height/page.paperScale))
                rect = rect.union(
                    CGRect(
                        x: midpoint.x - (size.width / 2 + 5) / page.paperScale,
                        y: midpoint.y - (size.height / 2 + 3) / page.paperScale,
                        width: (size.width + 10) / page.paperScale,
                        height: (size.height + 6) / page.paperScale))
            }
            bounds[edge.id] = rect.insetBy(
                dx: -(edge.width + 18) / page.paperScale, dy: -(edge.width + 18) / page.paperScale)
            routeBounds[edge.id] = bounds[edge.id]
        }
        runtime.installPreparedEdgeBounds(bounds)
    }

    func preparedLabel(_ edge: DiagramEdge) -> PreparedEdgeLabel? {
        guard !edge.label.isEmpty else { return nil }
        let colored = DiagramDrawing.layerColored(edge, in: page)
        let key = RenderObjectID(pageID: page.id, nodeID: edge.id)
        let cached = Self.sharedLabels.value(for: key)
        if let cached, cached.matches(colored) { return cached }
        let prepared = PreparedEdgeLabel(colored, previous: cached)
        Self.sharedLabels.insert(prepared, for: key, cost: prepared.cost)
        return prepared
    }

    func preparedNode(_ node: DiagramNode) -> PreparedNodeDrawing {
        let colored = DiagramDrawing.layerColored(node, in: page)
        let key = RenderObjectID(pageID: page.id, nodeID: node.id)
        if let cached = nodes.value(for: key), cached.input == colored, cached.paperScale == page.paperScale {
            return cached
        }
        let prepared = PreparedNodeDrawing(colored, paperScale: page.paperScale)
        nodes.insert(prepared, for: key, cost: prepared.cost)
        lastDrawWork.nodePreparations += 1
        return prepared
    }

    func draw(in dirty: CGRect, printing: Bool, selectedEdge: UUID? = nil, shadow: Bool = false) {
        let evidence = PerformanceEvidence.begin(.draw)
        defer { PerformanceEvidence.end(evidence) }
        lastDrawWork = SceneDrawWork()
        let nodeQuery = runtime.nodes(intersecting: dirty)
        let edgeQuery = runtime.edgeCandidates(intersecting: dirty, frontToBack: false)
        lastDrawWork.candidates = nodeQuery.work.candidateVisits + edgeQuery.work.candidateVisits
        PerformanceEvidence.count(.renderCandidates, by: lastDrawWork.candidates)
        let candidates = nodeQuery.values
        func drawNode(_ node: DiagramNode, shadow: Bool) {
            guard page.isVisible(node, printing: printing) else { return }
            let prepared = preparedNode(node)
            DiagramDrawing.drawNode(
                prepared.input, shadow: shadow, paperScale: page.paperScale, prepared: prepared)
            lastDrawWork.nodesDrawn += 1
        }
        for node in candidates where node.kind == .swimlane { drawNode(node, shadow: false) }
        for edge in edgeQuery.values where page.isVisible(edge, printing: printing) {
            DiagramDrawing.drawEdge(
                DiagramDrawing.layerColored(edge, in: page), in: page,
                selected: edge.id == selectedEdge, preparedRoute: routes[edge.id] ?? [],
                preparedLabel: preparedLabel(edge))
            lastDrawWork.edgesDrawn += 1
        }
        for node in candidates where node.kind != .swimlane { drawNode(node, shadow: shadow) }
    }
}

/// Value-only semantic snapshot, safe to retain after the serial UI cache moves
/// to another revision. Jobs never receive mutable RetainedRenderPage objects.
struct EvaluatedSceneSnapshot {
    struct Layer {
        let page: DiagramPage
        let routes: [UUID: [CGPoint]]
        let connectionPoints: [UUID: [String: CGPoint]]
        let routeBounds: [UUID: CGRect]
        init(
            page: DiagramPage, routes: [UUID: [CGPoint]], connectionPoints: [UUID: [String: CGPoint]],
            routeBounds: [UUID: CGRect] = [:]
        ) {
            self.page = page
            self.routes = routes
            self.connectionPoints = connectionPoints
            self.routeBounds = routeBounds
        }
    }
    let scene: DiagramScene
    let revision: UInt64
    let layers: [Layer]
}

final class RetainedRenderScene {
    private(set) var scene: DiagramScene
    private(set) var layers: [RetainedRenderPage]
    let revision: UInt64
    let snapshot: EvaluatedSceneSnapshot
    private let isPreview: Bool
    var foreground: RetainedRenderPage { layers[layers.count - 1] }

    init(scene: DiagramScene, revision: UInt64 = 0, previous: RetainedRenderScene? = nil) {
        self.scene = scene
        self.revision = revision
        isPreview = false
        let old = Dictionary(uniqueKeysWithValues: (previous?.layers ?? []).map { ($0.page.id, $0) })
        layers = scene.layers.map { page in
            if let retained = old[page.id] {
                retained.update(page)
                return retained
            }
            return RetainedRenderPage(page)
        }
        snapshot = EvaluatedSceneSnapshot(
            scene: scene, revision: revision,
            layers: layers.map {
                EvaluatedSceneSnapshot.Layer(
                    page: $0.page, routes: $0.routes, connectionPoints: $0.connectionPoints,
                    routeBounds: $0.routeBounds)
            })
    }

    /// Caller keeps the same committed snapshot throughout one gesture. Reusing
    /// previous preview caches never mutates the committed evaluated scene.
    init(previewPage: DiagramPage, baseline: EvaluatedSceneSnapshot, previous: RetainedRenderScene? = nil) {
        let previewScene = DiagramScene(page: previewPage, backgrounds: baseline.scene.backgrounds)
        scene = previewScene
        revision = baseline.revision
        isPreview = true
        let reusable =
            previous?.isPreview == true && previous?.revision == baseline.revision
            && previous?.scene.page.id == baseline.scene.page.id
        let old = Dictionary(
            uniqueKeysWithValues: (reusable ? previous?.layers ?? [] : []).map { ($0.page.id, $0) })
        let evaluated = Dictionary(uniqueKeysWithValues: baseline.layers.map { ($0.page.id, $0) })
        layers = previewScene.layers.map { page in
            if let retained = old[page.id] {
                retained.update(page)
                return retained
            }
            let layer =
                evaluated[page.id]
                ?? EvaluatedSceneSnapshot.Layer(page: page, routes: [:], connectionPoints: [:])
            let retained = RetainedRenderPage(evaluated: layer)
            retained.update(page)
            return retained
        }
        snapshot = EvaluatedSceneSnapshot(
            scene: scene, revision: revision,
            layers: layers.map {
                EvaluatedSceneSnapshot.Layer(
                    page: $0.page, routes: $0.routes, connectionPoints: $0.connectionPoints,
                    routeBounds: $0.routeBounds)
            })
    }
}
