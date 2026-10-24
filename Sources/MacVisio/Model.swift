import Foundation
import CoreGraphics

enum ShapeKind: String, Codable, CaseIterable {
    case rectangle, roundedRectangle, ellipse, diamond, parallelogram, cylinder, document, triangle, hexagon, cloud, person, text, swimlane
    var title: String {
        switch self {
        case .rectangle: return "Process"
        case .roundedRectangle: return "Start / End"
        case .ellipse: return "Ellipse"
        case .diamond: return "Decision"
        case .parallelogram: return "Data"
        case .cylinder: return "Database"
        case .document: return "Document"
        case .triangle: return "Triangle"
        case .hexagon: return "Preparation"
        case .cloud: return "Cloud"
        case .person: return "Person"
        case .text: return "Text"
        case .swimlane: return "Swimlane"
        }
    }
    var defaultSize: CGSize {
        switch self {
        case .diamond: return CGSize(width: 150, height: 110)
        case .ellipse: return CGSize(width: 140, height: 90)
        case .cylinder: return CGSize(width: 120, height: 130)
        case .person: return CGSize(width: 70, height: 110)
        case .swimlane: return CGSize(width: 640, height: 200)
        case .text: return CGSize(width: 180, height: 50)
        default: return CGSize(width: 160, height: 80)
        }
    }
}

struct DiagramNode: Codable, Equatable, Identifiable {
    var id = UUID()
    var kind: ShapeKind = .rectangle
    var x: Double = 100
    var y: Double = 100
    var width: Double = 160
    var height: Double = 80
    var text: String = "Process" {
        didSet {
            if text != oldValue,var detail = details,let runs = detail.textRuns,runs.map(\.text).joined() == oldValue {
                detail.textRuns = runs.isEmpty && !text.isEmpty ? nil : ShapeRichText.replacingText(oldValue,with:text,runs:runs);details = detail
            }
        }
    }
    var fill: String = "#E8F0FE"
    var stroke: String = "#4375BC"
    var textColor: String = "#20334F"
    var strokeWidth: Double = 1.5
    var fontSize: Double = 14
    var bold: Bool = false
    var rotation: Double = 0
    var locked: Bool = false
    var layer: String = "Default"
    var details: ShapeDetails?
    var parentID: UUID?
    var formatting: ShapeDetails {
        get { details ?? ShapeDetails() }
        set { details = newValue }
    }
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    var center: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }
    var sheetWidth:Double { formatting.negativeWidth == true ? -width : width }
    var sheetHeight:Double { formatting.negativeHeight == true ? -height : height }
    var sheetOrigin:CGPoint { CGPoint(x:min(0,sheetWidth),y:min(0,sheetHeight)) }
    init(kind: ShapeKind = .rectangle, x: Double = 100, y: Double = 100, text: String? = nil) {
        self.kind = kind; self.x = x; self.y = y
        width = kind.defaultSize.width; height = kind.defaultSize.height
        self.text = text ?? (kind == .text ? "Double-click to edit" : kind.title)
        if kind == .text { fill = "#FFFFFF00"; stroke = "#FFFFFF00" }
        if kind == .swimlane { fill = "#F5F7FB"; stroke = "#BBC7D8" }
    }
}

enum EdgeStyle: String, Codable, CaseIterable { case orthogonal, straight }
struct DiagramEdge: Codable, Equatable, Identifiable {
    var id = UUID()
    var source: UUID
    var target: UUID
    var label: String = "" {
        didSet {
            if label != oldValue,var detail = details,let runs = detail.textRuns,runs.map(\.text).joined() == oldValue {
                detail.textRuns = runs.isEmpty && !label.isEmpty ? nil : ShapeRichText.replacingText(oldValue,with:label,runs:runs);details = detail
            }
        }
    }
    var color: String = "#697D99"
    var width: Double = 1.8
    var style: EdgeStyle = .orthogonal
    var arrow: Bool = true
    var points: [DiagramPoint]?
    var sourcePosition: DiagramPoint?
    var targetPosition: DiagramPoint?
    var dash: Int?
    var startArrow: Bool?
    var layer: String?
    var parentID: UUID?
    var sourceShapeID: String?
    var sourcePort:String?
    var targetPort:String?
    // Optional so drawings written before connector sheets remain decodable.
    var details: ShapeDetails?
    var formatting: ShapeDetails {
        get { details ?? ShapeDetails() }
        set { details = newValue }
    }
    /// Adapt the shared text serializer without changing connector identity or route.
    /// Character/paragraph source rows stay in `details`; geometry belongs to the edge.
    var textNode: DiagramNode {
        var node = DiagramNode(kind:.text,text:label)
        node.id = id;node.parentID = parentID;node.details = details
        let first = formatting.textRuns?.first
        node.fontSize = first?.character.size ?? formatting.sheet["Char.Size"].flatMap{Double($0.value).map{$0*72}} ?? 12
        node.textColor = first?.character.color ?? color;node.bold = first?.character.bold ?? false
        node.width = max(1,abs(formatting.sheet["Width"].flatMap{Double($0.value)} ?? 1)*72)
        node.height = max(1,abs(formatting.sheet["Height"].flatMap{Double($0.value)} ?? 1)*72)
        return node
    }
}

struct DiagramPage: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String = "Page 1"
    var width: Double = 1120
    var height: Double = 840
    var nodes: [DiagramNode] = []
    var edges: [DiagramEdge] = []
    var layers: [DiagramLayer]?
    var backgroundPageID: UUID?
    var isBackground: Bool?
    var drawingScale:DrawingScale?
    /// Supported PageSheet cells retained from VSDX. Keys use Visio cell names
    /// (for example `PageLeftMargin`, `User.Code`, and `Prop.Owner`).
    var sheet: [String:ShapeSheetCell]? = nil
    /// Office theme selected by this page's document package. PageSheet theme
    /// indices remain in `sheet`; this carries the selected theme part's data.
    var theme: VisioTheme? = nil
    var paperScale:Double { drawingScale?.factor ?? 1 }
    var isMeasured:Bool { paperScale != 1 || (drawingScale?.type ?? 0) != 0 }
    var paperWidth:Double { width*paperScale }
    var paperHeight:Double { height*paperScale }
    func isVisible(_ node: DiagramNode, printing: Bool = false) -> Bool {
        var current: DiagramNode? = node
        for _ in 0..<64 {
            guard let n = current else { return true }
            let names = Set(n.formatting.layerNames + [n.layer])
            if (layers ?? []).contains(where:{names.contains($0.name) && (!$0.visible || (printing && !$0.printable))}) { return false }
            current = n.parentID.flatMap { id in nodes.first(where:{$0.id == id}) }
        }; return false
    }
    func isLocked(_ node: DiagramNode) -> Bool {
        var current: DiagramNode? = node
        for _ in 0..<64 {
            guard let n = current else { return false }
            let names = Set(n.formatting.layerNames + [n.layer])
            if n.locked || (layers ?? []).contains(where:{names.contains($0.name) && $0.locked}) { return true }
            current = n.parentID.flatMap { id in nodes.first(where:{$0.id == id}) }
        }; return true
    }
    func isVisible(_ edge:DiagramEdge,printing:Bool = false) -> Bool {
        let names = Set(edge.formatting.layerNames + [edge.layer].compactMap{$0})
        if (layers ?? []).contains(where:{names.contains($0.name) && (!$0.visible || printing && !$0.printable)}) { return false }
        return edge.parentID.flatMap{id in nodes.first{$0.id == id}}.map{isVisible($0,printing:printing)} ?? true
    }
    func isLocked(_ edge:DiagramEdge) -> Bool {
        let names = Set(edge.formatting.layerNames + [edge.layer].compactMap{$0})
        if (layers ?? []).contains(where:{names.contains($0.name) && $0.locked}) { return true }
        return edge.parentID.flatMap{id in nodes.first{$0.id == id}}.map{isLocked($0)} ?? false
    }
    func descendants(of id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        for _ in 0..<64 {
            let extra = Set(nodes.filter { $0.parentID.map(result.contains) == true }.map(\.id))
            let next = result.union(extra)
            if next == result { break }; result = next
        }
        return result
    }
}

struct Diagram: Codable, Equatable {
    var version: Int = 1
    var title: String = "Untitled Diagram"
    var pages: [DiagramPage] = [DiagramPage()]
    var activePageID: UUID
    var visioArchive: VisioDocumentArchive?
    var legacySource: LegacyVisioSource?
    var definitions: DefinitionRegistry?
    init() { activePageID = pages[0].id }
    var activePageIndex: Int { pages.firstIndex { $0.id == activePageID } ?? 0 }
    var page: DiagramPage {
        get { pages[activePageIndex] }
        set { pages[activePageIndex] = newValue }
    }
    var orderedPages:[DiagramPage] { pages.filter{$0.isBackground != true}+pages.filter{$0.isBackground == true} }
    func scene(for pageID:UUID? = nil) -> DiagramScene {
        let evidence = PerformanceEvidence.begin(.scenePreparation);defer { PerformanceEvidence.end(evidence) }
        let foreground = pageID.flatMap{id in pages.first{$0.id == id}} ?? page
        let byID = pages.reduce(into:[UUID:DiagramPage]()){if $0[$1.id] == nil { $0[$1.id] = $1 }}
        var backgrounds:[DiagramPage] = [],next = foreground.backgroundPageID,seen:Set<UUID> = [foreground.id]
        while let id = next,seen.count<=pages.count,seen.insert(id).inserted,let background = byID[id] {
            backgrounds.append(background);next = background.backgroundPageID
        }
        if backgrounds.contains(where:{background in
            background.nodes.contains{$0.formatting.textFields?.isEmpty == false}
                || background.edges.contains{$0.formatting.textFields?.isEmpty == false}
        }) {
            let evaluated = TextFieldEngine.recalculate(self,foreground:foreground).diagram
            backgrounds = backgrounds.map{background in evaluated.pages.first{$0.id == background.id} ?? background}
        }
        return DiagramScene(page:foreground,backgrounds:backgrounds.reversed())
    }
    func validated() throws -> Diagram {
        guard version == 1, !pages.isEmpty, pages.count <= 1000 else { throw DiagramError.invalid("Unsupported version or invalid page count.") }
        if definitions == nil, visioArchive != nil { return try DefinitionRegistry.hydrate(self).validated() }
        try definitions?.validate()
        if let registry = definitions, let archive = visioArchive, archive.definitionRows != nil { try DefinitionSourceRow.validateArchive(archive,registry:registry) }
        if let registry = definitions, let archive = visioArchive, registry.editableSheets.contains(where: { $0.sections == nil }) {
            var hydrated = registry
            var sectionsBySheet: [UUID: [DefinitionSection]] = [:]
            _ = try DefinitionRowEditing.elements(registry, parts: archive.parts) { sheet, element, _ in
                guard sheet.sections == nil else { return }
                var sections = DefinitionRegistry.sheet(element, scope: sheet.id, publicID: sheet.publicID).sections ?? []
                for i in sections.indices { sections[i].id = DefinitionRegistry.stableID(sheet.id, "section:" + sections[i].address.key) }
                sectionsBySheet[sheet.id] = sections
            }
            hydrated.forEachEditableSheet { if let sections = sectionsBySheet[$0.id] { $0.sections = sections } }
            var indexed = self; indexed.definitions = hydrated
            if let prior = archive.definitionRows {
                let existing = Set(prior.map(\.rowID))
                indexed.visioArchive?.definitionRows = prior + DefinitionSourceRow.index(hydrated).filter { !existing.contains($0.rowID) }
            }
            return try indexed.validated()
        }
        if let definitions, let archive = visioArchive, archive.definitionRows == nil {
            var indexed = self
            indexed.visioArchive?.definitionRows = DefinitionSourceRow.index(definitions)
            return try indexed.validated()
        }
        if visioArchive != nil,pages.contains(where:{$0.drawingScale == nil}),let hydrated = try DrawingScale.hydrate(self) { return try hydrated.validated() }
        if let archive = visioArchive,archive.connectorHierarchyVersion != 1 { return try DiagramCoordinates.hydrateArchivedConnectors(self).validated() }
        if let hydrated = try VisioFormat.hydrateMissingConnectorDetails(self) { return try hydrated.validated() }
        var ids = Set<UUID>()
        let byPageID = pages.reduce(into:[UUID:DiagramPage]()){if $0[$1.id] == nil { $0[$1.id] = $1 }}
        for page in pages {
            guard ids.insert(page.id).inserted, page.width.isFinite, page.height.isFinite,
                  page.width >= 1, page.height >= 1, page.width <= 1e9, page.height <= 1e9,
                  page.drawingScale?.isValid != false,page.paperWidth <= 20000,page.paperHeight <= 20000,
                  page.nodes.count <= 50000, page.edges.count <= 100000 else { throw DiagramError.invalid("Invalid page dimensions or duplicate identifiers.") }
            let nodeIDs = Set(page.nodes.map(\.id))
            guard nodeIDs.count == page.nodes.count else { throw DiagramError.invalid("Duplicate shape identifiers.") }
            let parents = Dictionary(uniqueKeysWithValues: page.nodes.compactMap { n in n.parentID.map { (n.id, $0) } })
            for node in page.nodes {
                var seen: Set<UUID> = [node.id]; var parent = node.parentID
                while let id = parent {
                    guard nodeIDs.contains(id), seen.insert(id).inserted, seen.count <= 64 else { throw DiagramError.invalid("Invalid or circular shape groups.") }
                    parent = parents[id]
                }
            }
            guard (page.layers ?? []).count <= 1000, Set((page.layers ?? []).map(\.name)).count == (page.layers ?? []).count else { throw DiagramError.invalid("Invalid or duplicate drawing layers.") }
            for n in page.nodes {
                guard [n.x,n.y,n.width,n.height,n.fontSize,n.rotation,n.strokeWidth].allSatisfy({ $0.isFinite }),
                      n.width > 0, n.height > 0, n.width <= 1e9, n.height <= 1e9,n.width*page.paperScale <= 20000,n.height*page.paperScale <= 20000,
                      abs(n.x) < 1e9, abs(n.y) < 1e9,abs(n.x*page.paperScale) < 100000,abs(n.y*page.paperScale) < 100000, (1...500).contains(n.fontSize),
                      (0...100).contains(n.strokeWidth) else { throw DiagramError.invalid("Invalid shape geometry.") }
                if let details = n.details { try Self.validateDetails(details,on:n,paperScale:page.paperScale) }
            }
            guard Set(page.edges.map(\.id)).count == page.edges.count,nodeIDs.isDisjoint(with:page.edges.map(\.id)) else { throw DiagramError.invalid("Duplicate connector identifiers.") }
            for edge in page.edges {
                for (id,port) in [(edge.source,edge.sourcePort),(edge.target,edge.targetPort)] { if let port { guard page.nodes.first(where:{$0.id == id})?.formatting.connectionPoints.contains(where:{$0.id == port}) == true else { throw DiagramError.invalid("A connector references a missing connection point.") } } }
                if let id = edge.sourceShapeID { guard UInt32(id) != nil else { throw DiagramError.invalid("Invalid source connector identifier.") } }
                if let details = edge.details { try Self.validateDetails(details,on:edge.textNode,paperScale:page.paperScale) }
                if let parent = edge.parentID { guard page.nodes.contains(where:{$0.id == parent && $0.formatting.isGroup}) else { throw DiagramError.invalid("A connector has an invalid group parent.") } }
                let validSource = nodeIDs.contains(edge.source) || edge.sourcePosition != nil
                let validTarget = nodeIDs.contains(edge.target) || edge.targetPosition != nil
                guard validSource, validTarget, edge.width.isFinite, (0...100).contains(edge.width),
                      (edge.points ?? []).count <= 100000,
                      ((edge.points ?? []) + [edge.sourcePosition,edge.targetPosition].compactMap{$0}).allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) < 1e9 && abs($0.y) < 1e9 && abs($0.x*page.paperScale) < 100000 && abs($0.y*page.paperScale) < 100000 }) else { throw DiagramError.invalid("A connector has invalid endpoints or width.") }
            }
        }
        for page in pages {
            var next = page.backgroundPageID,seen:Set<UUID> = [page.id]
            while let id = next {
                guard seen.insert(id).inserted,let background = byPageID[id],background.isBackground == true else { throw DiagramError.invalid("Invalid or circular background pages.") }
                next = background.backgroundPageID
            }
        }
        if let source = legacySource {
            guard source.data.count<=100*1024*1024,source.data.starts(with:CompoundFile.signature) else { throw DiagramError.invalid("Invalid preserved binary Visio source.") }
            let file = try CompoundFile.read(source.data)
            guard let document = file.streams["VisioDocument"],document.starts(with:Data("Visio (TM) Drawing\r\n\0".utf8)),let version = try? BinaryBytes(document).u8(26),(1...6).contains(version) || version == 11 else { throw DiagramError.invalid("The preserved source is not a binary Visio drawing.") }
            var baseline = Diagram();baseline.pages = source.pages;baseline.activePageID = source.pages.first?.id ?? baseline.activePageID;_ = try baseline.validated()
        }
        if let archive = visioArchive {
            guard archive.pages.count <= 1000,Set(archive.pages.map(\.pageID)).count == archive.pages.count,
                  archive.parts.count <= 10000,archive.parts.values.allSatisfy({$0.count <= VisioPackage.partLimit}),archive.parts.values.reduce(0,{$0+$1.count}) <= VisioPackage.totalLimit,
                  archive.parts[archive.pagesPart] != nil,archive.parts["[Content_Types].xml"] != nil else { throw DiagramError.invalid("Invalid preserved Visio package.") }
            for path in archive.parts.keys { try VisioPackage.validatePath(path) }
            var baseline = Diagram();baseline.pages = archive.pages.map(\.original);baseline.activePageID = baseline.pages.first?.id ?? baseline.activePageID
            if !baseline.pages.isEmpty { _ = try baseline.validated() }
            let pageIDs = archive.pages.compactMap{UInt32($0.visioID)}
            guard pageIDs.count == archive.pages.count,Set(pageIDs).count == pageIDs.count else { throw DiagramError.invalid("Invalid preserved Visio page identifiers.") }
            for binding in archive.pages {
                let shapeIDs = Array(binding.nodeIDs.values)+Array(binding.edgeIDs.values)
                guard binding.original.id == binding.pageID,archive.parts[binding.part] != nil,
                      shapeIDs.allSatisfy({UInt32($0) != nil}),Set(shapeIDs.compactMap(UInt32.init)).count == shapeIDs.count,
                      Set(binding.nodeIDs.keys).isSubset(of:Set(binding.original.nodes.map(\.id))),Set(binding.edgeIDs.keys).isSubset(of:Set(binding.original.edges.map(\.id))) else { throw DiagramError.invalid("Invalid Visio shape bindings.") }
                for (id,inheritance) in binding.inheritedShapes ?? [:] {
                    guard UInt32(inheritance.masterShapeID) != nil,
                          binding.nodeIDs[id] != nil || binding.edgeIDs[id] != nil,
                          let parent = binding.original.nodes.first(where:{$0.id == inheritance.parentID}),parent.formatting.isGroup,
                          binding.original.nodes.first(where:{$0.id == id}).map({$0.parentID == parent.id}) ?? binding.original.edges.first(where:{$0.id == id}).map({$0.parentID == parent.id}) ?? false else { throw DiagramError.invalid("Invalid inherited Visio shape bindings.") }
                }
            }
        }
        return self
    }
    private static func validateDetails(_ details:ShapeDetails,on n:DiagramNode,paperScale:Double) throws {
        if let geometry = details.geometry { guard geometry.count <= 1000,Set(geometry.map(\.index)).count == geometry.count,geometry.allSatisfy(\.valid),geometry.reduce(0,{$0+$1.rows.count}) <= 100000 else { throw DiagramError.invalid("Invalid ShapeSheet geometry.") } }
        if let fields = details.textFields { guard fields.count <= 1000,Set(fields.map(\.index)).count == fields.count,fields.allSatisfy(\.valid),(details.textRuns ?? []).allSatisfy({$0.fieldIndex.map{index in fields.contains{$0.index == index}} ?? true}) else { throw DiagramError.invalid("Invalid text fields.") } }
        if let runs = details.textRuns { guard runs.count <= 100000,runs.map(\.text).joined() == n.text,runs.allSatisfy({$0.character.valid && $0.paragraph.valid}) else { throw DiagramError.invalid("Invalid rich text runs.") } }
        let ports = details.connectionPoints
        guard details.controls.count <= 1000,Set(details.controls.map{$0.name.lowercased()}).count == details.controls.count,Set(details.controls.map(\.index)).count == details.controls.count,details.controls.allSatisfy(\.valid) else { throw DiagramError.invalid("Invalid control handle definitions.") }
        guard ports.count <= 1000,Set(ports.map{$0.id.lowercased()}).count == ports.count,Set(ports.map(\.index)).count == ports.count,
              ports.allSatisfy({port in port.index <= Int32.max-100 && (port.name.map{!$0.isEmpty && $0.utf8.count<=256 && !$0.contains("!") && !$0.contains(".") && port.index<1000} ?? true) && [Double(port.x.value),Double(port.y.value)].allSatisfy{$0.map{$0.isFinite && abs($0)<100000} ?? false} && [port.directionX,port.directionY].allSatisfy{$0.isFinite && abs($0)<100000} && (0...2).contains(port.type) && port.x.formula.utf8.count <= 16384 && port.y.formula.utf8.count <= 16384}) else { throw DiagramError.invalid("Invalid connection points.") }
        if let id = details.sourceShapeID { guard UInt32(id) != nil else { throw DiagramError.invalid("Invalid source shape identifier.") } }
        guard details.paths.reduce(0, { $0 + $1.commands.count }) <= 100000,
              details.paths.flatMap(\.commands).allSatisfy({ $0.isValid(xScale:n.width*paperScale,yScale:n.height*paperScale) }),
              details.paths.allSatisfy({$0.commands.isEmpty || $0.commands.first?.kind == "M"}),
              details.sheet.count <= 10000,details.sheet.values.allSatisfy({$0.formula.utf8.count <= 16384}),
              (details.image?.data.count ?? 0) <= VisioPackage.partLimit else { throw DiagramError.invalid("Invalid custom geometry or oversized image.") }
        if let box = details.textBox {
            let physical = [box.centerX*n.width*paperScale,box.centerY*n.height*paperScale,box.width*n.width*paperScale,box.height*n.height*paperScale,box.rotation,box.left*paperScale,box.right*paperScale,box.top*paperScale,box.bottom*paperScale]
            guard physical.allSatisfy({$0.isFinite && abs($0)<100000}),box.width > 0,box.height > 0 else { throw DiagramError.invalid("Invalid text block geometry.") }
        }
    }

}

enum DiagramError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

enum DiagramGeometry {
    static func snapped(_ value: Double, grid: Double = 10) -> Double { (value / grid).rounded() * grid }
    static func boundary(of node: DiagramNode, toward point: CGPoint) -> CGPoint {
        let c = node.center
        let worldX = point.x - c.x, worldY = point.y - c.y
        guard abs(worldX) + abs(worldY) > 0.0001 else { return CGPoint(x: c.x, y: node.y) }
        let angle = -node.rotation * .pi/180
        let dx = worldX*cos(angle)-worldY*sin(angle),dy = worldX*sin(angle)+worldY*cos(angle)
        let a = node.width / 2, b = node.height / 2
        var scale: Double
        switch node.kind {
        case .ellipse, .cloud: scale = 1 / sqrt(dx * dx / (a * a) + dy * dy / (b * b))
        case .diamond: scale = 1 / (abs(dx) / a + abs(dy) / b)
        default: scale = min(abs(dx) < 0.0001 ? .infinity : a / abs(dx), abs(dy) < 0.0001 ? .infinity : b / abs(dy))
        }
        return CGPoint(x: c.x + worldX * scale, y: c.y + worldY * scale)
    }
    static func route(_ edge: DiagramEdge, in page: DiagramPage) -> [CGPoint] {
        let evidence = PerformanceEvidence.begin(.route);defer { PerformanceEvidence.end(evidence) }
        PerformanceEvidence.count(.routeRequests)
        let source = page.nodes.first(where: { $0.id == edge.source }), target = page.nodes.first(where: { $0.id == edge.target })
        let sourceFixed = ConnectionGeometry.fixed(edge.sourcePort,on:source),targetFixed = ConnectionGeometry.fixed(edge.targetPort,on:target)
        if let points = edge.points, points.count >= 2 {
            var route = points.map(\.cgPoint)
            if let p = sourceFixed { route[0] = p } else if let a = source { route[0] = boundary(of:a,toward:route[1]) }
            if let p = targetFixed { route[route.count-1] = p } else if let b = target { route[route.count-1] = boundary(of:b,toward:route[route.count-2]) }
            return route
        }
        if edge.style == .orthogonal, let route = OrthogonalRouter.route(edge,in:page) { return route }
        if sourceFixed != nil || targetFixed != nil {
            guard let p = sourceFixed ?? source?.center ?? edge.sourcePosition?.cgPoint,let q = targetFixed ?? target?.center ?? edge.targetPosition?.cgPoint else { return [] }
            let first = sourceFixed ?? source.map{boundary(of:$0,toward:q)} ?? p,last = targetFixed ?? target.map{boundary(of:$0,toward:p)} ?? q
            if edge.source == edge.target,hypot(first.x-last.x,first.y-last.y)<0.001 { return [first,CGPoint(x:first.x+40,y:first.y),CGPoint(x:first.x+40,y:first.y-40),CGPoint(x:first.x,y:first.y-40),last] }
            if edge.style == .straight { return [first,last] }
            if abs(last.x-first.x)>abs(last.y-first.y) { let mid = (first.x+last.x)/2;return [first,CGPoint(x:mid,y:first.y),CGPoint(x:mid,y:last.y),last] }
            let mid = (first.y+last.y)/2;return [first,CGPoint(x:first.x,y:mid),CGPoint(x:last.x,y:mid),last]
        }
        guard let a = source, let b = target else {
            guard let p = source?.center ?? edge.sourcePosition?.cgPoint, let q = target?.center ?? edge.targetPosition?.cgPoint else { return [] }
            let first = source.map { boundary(of:$0,toward:q) } ?? p,last = target.map { boundary(of:$0,toward:p) } ?? q
            if edge.style == .straight { return [first,last] }
            if abs(last.x-first.x)>abs(last.y-first.y) { let mid = (first.x+last.x)/2;return [first,CGPoint(x:mid,y:first.y),CGPoint(x:mid,y:last.y),last] }
            let mid = (first.y+last.y)/2;return [first,CGPoint(x:first.x,y:mid),CGPoint(x:last.x,y:mid),last]
        }
        if edge.source == edge.target {
            return [CGPoint(x:a.x+a.width,y:a.y+a.height/2),CGPoint(x:a.x+a.width+40,y:a.y+a.height/2),CGPoint(x:a.x+a.width+40,y:a.y-30),CGPoint(x:a.x+a.width/2,y:a.y-30),CGPoint(x:a.x+a.width/2,y:a.y)]
        }
        if edge.style == .straight { return [boundary(of: a, toward: b.center), boundary(of: b, toward: a.center)] }
        let dx = b.center.x - a.center.x, dy = b.center.y - a.center.y
        if abs(dx) > abs(dy) {
            let p = boundary(of:a,toward:CGPoint(x:a.center.x+(dx > 0 ? 100000 : -100000),y:a.center.y))
            let q = boundary(of:b,toward:CGPoint(x:b.center.x+(dx > 0 ? -100000 : 100000),y:b.center.y))
            let mid = (p.x + q.x) / 2
            return [p, CGPoint(x:mid,y:p.y), CGPoint(x:mid,y:q.y), q]
        }
        let p = boundary(of:a,toward:CGPoint(x:a.center.x,y:a.center.y+(dy > 0 ? 100000 : -100000)))
        let q = boundary(of:b,toward:CGPoint(x:b.center.x,y:b.center.y+(dy > 0 ? -100000 : 100000)))
        let mid = (p.y+q.y) / 2
        return [p, CGPoint(x:p.x,y:mid), CGPoint(x:q.x,y:mid), q]
    }
    static func distance(_ p: CGPoint, to a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x-a.x, dy = b.y-a.y
        let length = dx*dx+dy*dy
        guard length > 0 else { return hypot(p.x-a.x,p.y-a.y) }
        let t = max(0,min(1,((p.x-a.x)*dx+(p.y-a.y)*dy)/length))
        return hypot(p.x-a.x-t*dx,p.y-a.y-t*dy)
    }
}
