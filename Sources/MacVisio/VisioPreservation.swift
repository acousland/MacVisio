import Foundation

/// Patch supported edits into the original OPC package. Opaque parts and unedited
/// page XML retain their original bytes; editing a shape does not rebuild its master.
enum VisioPreservation {
    private static let relNS = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let visioRel = "http://schemas.microsoft.com/visio/2010/relationships/"
    private static let nativePart = "macvisio/document.json"

    static func write(_ diagram:Diagram,to url:URL) throws {
        guard let source = diagram.visioArchive else { throw DiagramError.invalid("The original Visio package is unavailable.") }
        var parts = source.parts
        var pageIDs = Dictionary(uniqueKeysWithValues:source.pages.map{($0.pageID,$0.visioID)})
        var used = Set(source.pages.compactMap{UInt32($0.visioID)}),nextID = (source.pages.compactMap{UInt64($0.visioID)}.max() ?? 0)+1
        for page in diagram.pages where pageIDs[page.id] == nil {
            if nextID>UInt32.max { nextID = 0 }
            while used.contains(UInt32(nextID)) { nextID += 1;if nextID>UInt32.max { nextID = 0 } }
            pageIDs[page.id] = String(nextID);used.insert(UInt32(nextID));nextID += 1
        }
        var backgroundSync = false
        if diagram.pages.contains(where:{$0.isBackground == true || $0.backgroundPageID != nil}),let data = parts[source.pagesPart] {
            let index = try VisioXML.document(data)
            for page in diagram.pages {
                let entry = index.rootElement()?.elementsLocal("Page").first{$0.attr("ID") == pageIDs[page.id]}
                let flag = ["1","true"].contains(entry?.attr("Background") ?? "")
                let target = page.backgroundPageID.flatMap{pageIDs[$0]}.flatMap(UInt32.init),actual = entry?.attr("BackPage").flatMap(UInt32.init)
                if flag != (page.isBackground == true) || target != nil && target != actual { backgroundSync = true }
            }
        }
        if source.pages.map(\.original) == diagram.pages && !backgroundSync {
            if parts[nativePart] != nil { parts[nativePart] = try VisioFormat.nativeMetadata(diagram,parts:&parts,bindings:source.pages) }
            try VisioPackage.write(parts,to:url); return
        }
        guard let indexData = parts[source.pagesPart] else { throw DiagramError.invalid("The original Visio page index is missing.") }
        let index = try VisioXML.document(indexData)
        guard let indexRoot = index.rootElement() else { throw DiagramError.invalid("Invalid page index.") }
        let relPart = VisioXML.relationshipPart(source.pagesPart)
        let pageRels = try VisioXML.document(parts[relPart] ?? Data("<Relationships xmlns=\"\(relNS)\"/>".utf8))
        guard let contentTypes = parts["[Content_Types].xml"] else { throw DiagramError.invalid("The original content types are missing.") }
        let types = try VisioXML.document(contentTypes)
        guard let relationships = pageRels.rootElement(),let typeRoot = types.rootElement() else { throw DiagramError.invalid("The package metadata is incomplete.") }
        let oldBindings = Dictionary(uniqueKeysWithValues:source.pages.map{($0.pageID,$0)})
        var bindings: [VisioPageBinding] = [], entries: [XMLElement] = []
        var indexChanged = source.pages.map(\.pageID) != diagram.pages.map(\.id)
        let originalRelationships = relationships.xmlString
        let oldPageElements = indexRoot.elementsLocal("Page")
        for page in diagram.pages {
            if let binding = oldBindings[page.id],let oldEntry = oldPageElements.first(where:{$0.attr("ID") == binding.visioID}) {
                let entry = oldEntry.copy() as! XMLElement
                let originalEntry = entry.xmlString
                if backgroundSync || page.isBackground != binding.original.isBackground { entry.setAttr("Background",page.isBackground == true ? "1" : nil) }
                if backgroundSync || page.backgroundPageID != binding.original.backgroundPageID { entry.setAttr("BackPage",page.backgroundPageID.flatMap{pageIDs[$0]}) }
                if page.name != binding.original.name { entry.setAttr("Name",page.name); entry.setAttr("NameU",page.name) }
                let sheet = entry.firstLocal("PageSheet") ?? XMLElement(name:"PageSheet")
                let createdSheet = sheet.parent == nil
                if createdSheet { entry.insertChild(sheet,at:0) }
                if page.width != binding.original.width { VisioXML.set(sheet,"PageWidth",page.width/72) }
                if page.height != binding.original.height { VisioXML.set(sheet,"PageHeight",page.height/72) }
                if page.drawingScale != binding.original.drawingScale { DrawingScale.write(page,to:sheet) }
                if page.sheet != binding.original.sheet { patchPageSheetCells(page.sheet ?? [:],from:binding.original.sheet ?? [:],sheet:sheet) }
                if page.layers != binding.original.layers { patchLayers(page,sheet:sheet,originalLayers:binding.original.layers ?? []) }
                var updated = binding
                if contentsChanged(page,from:binding.original) {
                    guard let pageData = parts[binding.part] else { throw DiagramError.invalid("A Visio page is missing.") }
                    let document = try VisioXML.document(pageData)
                    guard let root = document.rootElement() else { throw DiagramError.invalid("Invalid Visio page.") }
                    try patchPage(page,old:binding.original,binding:&updated,root:root,part:binding.part,parts:&parts,types:typeRoot,layerSheet:sheet)
                    parts[binding.part] = document.xmlData(options:.nodePreserveAll)
                }
                if createdSheet,(sheet.children ?? []).isEmpty,(sheet.attributes ?? []).isEmpty { sheet.detach() }
                if entry.xmlString != originalEntry { indexChanged = true }
                updated.original = page; bindings.append(updated); entries.append(entry)
            } else {
                indexChanged = true
                let pageID = pageIDs[page.id]!
                var number = Int(pageID)!+1
                var part = "\((source.pagesPart as NSString).deletingLastPathComponent)/page\(number).xml"
                while parts[part] != nil { number += 1; part = "\((source.pagesPart as NSString).deletingLastPathComponent)/page\(number).xml" }
                let rid = uniqueRelationshipID(relationships)
                let relation = XMLElement(name:"Relationship"); relation.setAttr("Id",rid); relation.setAttr("Type",visioRel+"page"); relation.setAttr("Target",(part as NSString).lastPathComponent); relationships.addChild(relation)
                let entry = XMLElement(name:"Page"); entry.setAttr("ID",pageID); entry.setAttr("Name",page.name); entry.setAttr("NameU",page.name)
                if page.isBackground == true { entry.setAttr("Background","1") };entry.setAttr("BackPage",page.backgroundPageID.flatMap{pageIDs[$0]})
                let sheet = XMLElement(name:"PageSheet"); VisioXML.set(sheet,"PageWidth",page.width/72); VisioXML.set(sheet,"PageHeight",page.height/72); DrawingScale.write(page,to:sheet);patchPageSheetCells(page.sheet ?? [:],from:[:],sheet:sheet);patchLayers(page,sheet:sheet); entry.addChild(sheet)
                let rel = XMLElement(name:"Rel"); rel.setAttr("r:id",rid); entry.addChild(rel)
                let root = try VisioXML.element("<PageContents xmlns=\"http://schemas.microsoft.com/office/visio/2012/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><Shapes/><Connects/></PageContents>")
                var binding = VisioPageBinding(pageID:page.id,visioID:entry.attr("ID")!,part:part,original:page,nodeIDs:[:],edgeIDs:[:])
                try patchPage(page,old:DiagramPage(id:page.id,name:page.name,width:page.width,height:page.height),binding:&binding,root:root,part:part,parts:&parts,types:typeRoot,layerSheet:sheet)
                let document = XMLDocument(rootElement:root); document.version = "1.0"; document.characterEncoding = "UTF-8"
                parts[part] = document.xmlData(options:.nodePreserveAll); bindings.append(binding); entries.append(entry)
                let override = XMLElement(name:"Override"); override.setAttr("PartName","/"+part); override.setAttr("ContentType","application/vnd.ms-visio.page+xml"); typeRoot.addChild(override)
            }
        }
        let keptIDs = Set(bindings.map(\.visioID))
        for entry in oldPageElements where !keptIDs.contains(entry.attr("ID") ?? "") {
            if let rid = entry.firstLocal("Rel")?.attributes?.first(where:{$0.localName == "id" || $0.name == "r:id"})?.stringValue {
                relationships.elementsLocal("Relationship").first(where:{$0.attr("Id") == rid})?.detach()
            }
        }
        if indexChanged {
            for entry in indexRoot.elementsLocal("Page") { entry.detach() }
            for entry in entries { indexRoot.addChild(entry) }
            parts[source.pagesPart] = index.xmlData(options:.nodePreserveAll)
        }
        if relationships.xmlString != originalRelationships { parts[relPart] = pageRels.xmlData(options:.nodePreserveAll) }
        ensureType("json","application/json",root:typeRoot)
        parts["[Content_Types].xml"] = types.xmlData(options:.nodePreserveAll)
        try ensureFonts(diagram,parts:&parts,bindings:bindings,original:source.pages.map(\.original))
        parts[nativePart] = try VisioFormat.nativeMetadata(diagram,parts:&parts,bindings:bindings)
        try VisioPackage.write(parts,to:url)
    }

    private static func contentsChanged(_ page:DiagramPage,from old:DiagramPage) -> Bool {
        var projected = old;let dy = page.height-old.height
        if dy != 0 {
            for i in projected.nodes.indices { projected.nodes[i].y += dy }
            for i in projected.edges.indices {
                projected.edges[i].points = projected.edges[i].points?.map{DiagramPoint(x:$0.x,y:$0.y+dy)}
                if let p = projected.edges[i].sourcePosition { projected.edges[i].sourcePosition = DiagramPoint(x:p.x,y:p.y+dy) }
                if let p = projected.edges[i].targetPosition { projected.edges[i].targetPosition = DiagramPoint(x:p.x,y:p.y+dy) }
            }
        }
        return page.nodes != projected.nodes || page.edges != projected.edges || page.layers != old.layers
    }

    private static func patchPage(_ page:DiagramPage,old:DiagramPage,binding:inout VisioPageBinding,root:XMLElement,part:String,parts:inout [String:Data],types:XMLElement,layerSheet:XMLElement) throws {
        let shapes = root.firstLocal("Shapes") ?? XMLElement(name:"Shapes"); if shapes.parent == nil { root.addChild(shapes) }
        let connects = root.firstLocal("Connects") ?? XMLElement(name:"Connects"); if connects.parent == nil { root.addChild(connects) }
        var byID:[String:XMLElement] = [:],numericIDs = Set<UInt32>()
        for shape in shapes.allShapes {
            if ["1","true"].contains(shape.attr("Del") ?? "") { if let id = shape.attr("ID").flatMap(UInt32.init) { numericIDs.insert(id) };continue }
            guard let id = shape.attr("ID"),let numeric = UInt32(id),numericIDs.insert(numeric).inserted else { throw DiagramError.invalid("The preserved page contains duplicate or invalid shape identifiers.") };byID[id] = shape
        }
        let oldNodes = Dictionary(uniqueKeysWithValues:old.nodes.map{($0.id,$0)}), oldEdges = Dictionary(uniqueKeysWithValues:old.edges.map{($0.id,$0)})
        let newNodeSet = Set(page.nodes.map(\.id)), newEdgeSet = Set(page.edges.map(\.id))
        let originalNodeIDs = binding.nodeIDs,originalEdgeIDs = binding.edgeIDs
        var inheritance = binding.inheritedShapes ?? [:]
        let newNodes = Dictionary(uniqueKeysWithValues:page.nodes.map{($0.id,$0)}),newEdges = Dictionary(uniqueKeysWithValues:page.edges.map{($0.id,$0)})
        // Ungrouping/reparenting a master member breaks its original inheritance
        // slot. Retain supported cached content as an independent shape, and leave
        // a tombstone at the old slot when its original parent still exists.
        var detachedInheritance = Set<UUID>(),detachedSource:[UUID:XMLElement] = [:]
        for (id,info) in inheritance where newNodeSet.contains(id) || newEdgeSet.contains(id) {
            let currentParent = newNodes[id]?.parentID ?? newEdges[id]?.parentID
            var broken = currentParent != info.parentID,next:UUID? = info.parentID
            for _ in 0..<64 {
                guard let parentID = next,let oldParent = oldNodes[parentID] else { break }
                if let current = newNodes[parentID] { if inheritance[parentID] != nil && current.parentID != oldParent.parentID { broken = true } }
                else { broken = true }
                next = oldParent.parentID
            }
            if broken { detachedInheritance.insert(id) }
        }
        var required = Set<UUID>(),elements = byID
        var takenIDs = Set(elements.keys).union(originalNodeIDs.values).union(originalEdgeIDs.values)
        var takenNumeric = Set(takenIDs.compactMap(UInt32.init)),nextID = (takenIDs.compactMap(UInt64.init).max() ?? 0)+1
        func allocateID() throws -> String {
            guard takenNumeric.count < 150000 else { throw DiagramError.invalid("The page has too many shapes.") }
            if nextID > UInt32.max { nextID = 0 }
            while takenNumeric.contains(UInt32(nextID)) { nextID += 1;if nextID > UInt32.max { nextID = 0 } }
            let id = String(nextID);takenIDs.insert(id);takenNumeric.insert(UInt32(nextID));nextID += 1;return id
        }
        // Minimal inherited overrides are attached only when necessary, including
        // an otherwise unchanged inherited group containing an edited descendant.
        func inheritedElement(_ id:UUID) throws -> XMLElement? {
            guard let info = inheritance[id],let shapeID = binding.nodeIDs[id] ?? binding.edgeIDs[id] else { return nil }
            if let element = elements[shapeID] { return element }
            let element = XMLElement(name:"Shape");element.setAttr("ID",shapeID);element.setAttr("MasterShape",info.masterShapeID)
            if oldNodes[id]?.formatting.isGroup == true { element.setAttr("Type","Group") }
            elements[shapeID] = element;return element
        }
        func require(_ id:UUID) throws {
            guard required.insert(id).inserted else { return }
            if let info = inheritance[id] {
                _ = try inheritedElement(id)
                if newNodeSet.contains(info.parentID) { try require(info.parentID) }
            }
        }
        func attachInherited(_ id:UUID,_ element:XMLElement) throws {
            guard let info = inheritance[id],newNodeSet.contains(info.parentID),let parentShapeID = binding.nodeIDs[info.parentID] else { return }
            let parent = try elements[parentShapeID] ?? inheritedElement(info.parentID)
            guard let parent else { throw DiagramError.invalid("An inherited shape has no group instance.") }
            if parent.parent == nil,inheritance[info.parentID] != nil { try attachInherited(info.parentID,parent) }
            let children = parent.firstLocal("Shapes") ?? XMLElement(name:"Shapes");if children.parent == nil { parent.addChild(children) }
            if element.parent == nil { children.addChild(element) }
        }
        for id in detachedInheritance {
            guard let info = inheritance[id],let shapeID = binding.nodeIDs[id] ?? binding.edgeIDs[id] else { continue }
            if let source = byID[shapeID] { detachedSource[id] = source.copy() as? XMLElement }
            if newNodeSet.contains(info.parentID),!detachedInheritance.contains(info.parentID) {
                let tombstone = XMLElement(name:"Shape");tombstone.setAttr("ID",try allocateID());tombstone.setAttr("MasterShape",info.masterShapeID);tombstone.setAttr("Del","1")
                try require(info.parentID);try attachInherited(id,tombstone)
            }
            byID[shapeID]?.detach();elements.removeValue(forKey:shapeID)
            byID.removeValue(forKey:shapeID)
        }
        for id in detachedInheritance { inheritance.removeValue(forKey:id) }
        var deletedShapeIDs = Set<String>()
        for (id,shapeID) in binding.nodeIDs.merging(binding.edgeIDs,uniquingKeysWith:{$1}) where !newNodeSet.contains(id) && !newEdgeSet.contains(id) {
            if let info = inheritance[id],newNodeSet.contains(info.parentID),let element = try inheritedElement(id) {
                // Removing the local XML alone would restore the master child.
                element.setAttr("Del","1");try require(info.parentID);try attachInherited(id,element)
            } else { byID[shapeID]?.detach() }
            deletedShapeIDs.insert(shapeID)
        }
        binding.nodeIDs = binding.nodeIDs.filter { newNodeSet.contains($0.key) }; binding.edgeIDs = binding.edgeIDs.filter { newEdgeSet.contains($0.key) }
        for node in page.nodes where binding.nodeIDs[node.id] == nil {
            if let candidate = node.formatting.sourceShapeID,let numeric = UInt32(candidate),!takenNumeric.contains(numeric) { binding.nodeIDs[node.id] = candidate;takenIDs.insert(candidate);takenNumeric.insert(numeric) }
            else { binding.nodeIDs[node.id] = try allocateID() }
        }
        for edge in page.edges where binding.edgeIDs[edge.id] == nil {
            if let candidate = edge.sourceShapeID,let numeric = UInt32(candidate),!takenNumeric.contains(numeric) { binding.edgeIDs[edge.id] = candidate;takenNumeric.insert(numeric);takenIDs.insert(candidate) }
            else { binding.edgeIDs[edge.id] = try allocateID() }
        }
        for node in page.nodes {
            let shapeID = binding.nodeIDs[node.id]!
            let local = localNode(node,in:page), original = oldNodes[node.id].map{localNode($0,in:old)}
            let parentHeight = node.parentID.flatMap { id in page.nodes.first(where:{$0.id == id})?.height } ?? page.height
            let implicit = inheritance[node.id]?.implicit == true && byID[shapeID] == nil
            if implicit,local == original,page.layers == old.layers { continue }
            try require(node.id)
            let element: XMLElement
            if let existing = byID[shapeID] { element = existing }
            else if let inherited = try inheritedElement(node.id) { element = inherited }
            else { element = try VisioXML.element(VisioFormat.shapeXML(local,id:Int(shapeID)!,pageHeight:parentHeight,paperScale:page.paperScale)); elements[shapeID] = element }
            let parentChanged = node.parentID != oldNodes[node.id]?.parentID
            if let previous = original,!detachedInheritance.contains(node.id) { try patchShape(local,old:previous,element:element,pageHeight:parentHeight,oldPageHeight:oldNodes[node.id]?.parentID.flatMap{id in old.nodes.first(where:{$0.id == id})?.height} ?? old.height,parentChanged:parentChanged) }
            if let previous = detachedSource[node.id] { preserveOpaqueInstance(previous,in:element) }
            if node.formatting.isGroup { element.setAttr("Type","Group") }
            if original == nil || detachedInheritance.contains(node.id) || original?.formatting.image != local.formatting.image {
                if let image = local.formatting.image { try attachImage(image,to:element,root:root,part:part,parts:&parts,types:types) }
            }
            if original == nil || original?.layer != local.layer || original?.formatting.layerNames != local.formatting.layerNames || page.layers != old.layers {
                let names = Set(local.formatting.layerNames+[local.layer])
                let rows = layerSheet.elementsLocal("Section").first(where:{$0.attr("N") == "Layer"})?.elementsLocal("Row") ?? []
                let ids = rows.filter { names.contains(VisioXML.value($0,"Name") ?? "") }.compactMap{$0.attr("IX")}
                if !ids.isEmpty { VisioXML.set(element,"LayerMember",ids.joined(separator:";")) }
                else { element.elementsLocal("Cell").first(where:{$0.attr("N") == "LayerMember"})?.detach() }
            }
        }
        // Parents can follow children in the model. Attach only after all group elements exist.
        for node in page.nodes {
            guard let element = elements[binding.nodeIDs[node.id]!] else { continue }
            if inheritance[node.id]?.implicit == true,!required.contains(node.id),byID[binding.nodeIDs[node.id]!] == nil { continue }
            if element.parent == nil || node.parentID != oldNodes[node.id]?.parentID {
                element.detach()
                if let parentID = node.parentID,let visioID = binding.nodeIDs[parentID],let parent = elements[visioID] {
                    let children = parent.firstLocal("Shapes") ?? XMLElement(name:"Shapes"); if children.parent == nil { parent.addChild(children) }; children.addChild(element)
                } else { shapes.addChild(element) }
            }
        }
        for connection in connects.elementsLocal("Connect") where deletedShapeIDs.contains(connection.attr("FromSheet") ?? "") || deletedShapeIDs.contains(connection.attr("ToSheet") ?? "") { connection.detach() }
        for edge in page.edges {
            let shapeID = binding.edgeIDs[edge.id]!, previous = oldEdges[edge.id]
            let coordinates = DiagramCoordinates.connector(edge,in:page)
            let route = DiagramGeometry.route(coordinates.edge,in:coordinates.page).map{CGPoint(x:$0.x,y:coordinates.page.height-$0.y)}
            let previousCoordinates = previous.map{DiagramCoordinates.connector($0,in:old)}
            let previousRoute = previousCoordinates.map{c in DiagramGeometry.route(c.edge,in:c.page).map{CGPoint(x:$0.x,y:c.page.height-$0.y)}} ?? []
            let sameRoute = route.count == previousRoute.count && zip(route,previousRoute).allSatisfy{abs($0.0.x-$0.1.x)<1e-9 && abs($0.0.y-$0.1.y)<1e-9}
            let parentChanged = previous?.parentID != edge.parentID
            let portsChanged = previous?.sourcePort != edge.sourcePort || previous?.targetPort != edge.targetPort
            let bindingsChanged = detachedInheritance.contains(edge.id) || detachedInheritance.contains(edge.source) || detachedInheritance.contains(edge.target) || originalNodeIDs[edge.source] != binding.nodeIDs[edge.source] || originalNodeIDs[edge.target] != binding.nodeIDs[edge.target] || originalEdgeIDs[edge.id] != shapeID
            let reroute = previous == nil || !sameRoute || parentChanged || bindingsChanged || portsChanged || previous?.source != edge.source || previous?.target != edge.target || previous?.style != edge.style
            var currentStyle = edge,oldStyle = previous;currentStyle.points = nil;currentStyle.sourcePosition = nil;currentStyle.targetPosition = nil;oldStyle?.points = nil;oldStyle?.sourcePosition = nil;oldStyle?.targetPosition = nil
            if inheritance[edge.id]?.implicit == true,byID[shapeID] == nil,currentStyle == oldStyle,!reroute { continue }
            try require(edge.id)
            let from = ConnectionGeometry.destination(edge.sourcePort,on:newNodes[edge.source]),to = ConnectionGeometry.destination(edge.targetPort,on:newNodes[edge.target])
            let generated = try VisioXML.element(VisioFormat.connectorXML(coordinates.edge,id:Int(shapeID)!,page:coordinates.page,sourceID:binding.nodeIDs[edge.source].flatMap(Int.init),targetID:binding.nodeIDs[edge.target].flatMap(Int.init),sourceCells:(from.x,from.y),targetCells:(to.x,to.y)))
            let element = try byID[shapeID] ?? inheritedElement(edge.id) ?? generated
            if let previous = detachedSource[edge.id] { preserveOpaqueInstance(previous,in:element) }
            if element.parent == nil || parentChanged {
                element.detach()
                if let parentID = edge.parentID,let parentShapeID = binding.nodeIDs[parentID],let parent = try elements[parentShapeID] ?? inheritedElement(parentID) {
                    let children = parent.firstLocal("Shapes") ?? XMLElement(name:"Shapes");if children.parent == nil { parent.addChild(children) };children.addChild(element)
                } else { shapes.addChild(element) }
            }
            if element !== generated && (previous == nil || reroute) {
                let geometryCells: Set<String> = ["PinX","PinY","Width","Height","LocPinX","LocPinY","Angle","BeginX","BeginY","EndX","EndY","ShapeRouteStyle"]
                for cell in element.elementsLocal("Cell") where geometryCells.contains(cell.attr("N") ?? "") { cell.detach() }
                for cell in generated.elementsLocal("Cell") where geometryCells.contains(cell.attr("N") ?? "") { element.addChild(cell.copy() as! XMLNode) }
                for section in element.elementsLocal("Section") where section.attr("N") == "Geometry" { section.detach() }
                for section in generated.elementsLocal("Section") where section.attr("N") == "Geometry" { element.addChild(section.copy() as! XMLNode) }
            }
            if previous?.label != edge.label { VisioXML.setText(element,edge.label) }
            if previous?.color != edge.color { VisioXML.set(element,"LineColor",String(edge.color.prefix(7))) }
            if previous?.width != edge.width { VisioXML.set(element,"LineWeight",edge.width/72) }
            if previous?.arrow != edge.arrow { VisioXML.set(element,"EndArrow",edge.arrow ? 4 : 0) }
            if previous?.startArrow != edge.startArrow { VisioXML.set(element,"BeginArrow",edge.startArrow == true ? 4 : 0) }
            if previous?.dash != edge.dash { VisioXML.set(element,"LinePattern",Double(edge.dash ?? 1)) }
            if previous == nil || previous?.layer != edge.layer || page.layers != old.layers {
                let rows = layerSheet.elementsLocal("Section").first{$0.attr("N") == "Layer"}?.elementsLocal("Row") ?? []
                if let id = rows.first(where:{VisioXML.value($0,"Name") == edge.layer})?.attr("IX") { VisioXML.set(element,"LayerMember",id) }
                else { element.elementsLocal("Cell").first{$0.attr("N") == "LayerMember"}?.detach() }
            }
            if previous == nil || bindingsChanged || portsChanged || reroute && inheritance[edge.id] != nil || previous?.source != edge.source || previous?.target != edge.target {
                for connection in connects.elementsLocal("Connect") where connection.attr("FromSheet") == shapeID { connection.detach() }
                for (endpoint,id,fromPart,destination) in [("BeginX",edge.source,"9",from),("EndX",edge.target,"12",to)] {
                    guard let target = binding.nodeIDs[id] else { continue }
                    if inheritance[id]?.implicit == true { try require(id) }
                    let c = XMLElement(name:"Connect"); c.setAttr("FromSheet",shapeID); c.setAttr("FromCell",endpoint); c.setAttr("FromPart",fromPart); c.setAttr("ToSheet",target); c.setAttr("ToCell",destination.x); c.setAttr("ToPart",destination.part); connects.addChild(c)
                }
            }
        }
        // An edited connector may have required a model-only ancestor after the
        // node attachment pass. Attach that shell as well, without expanding siblings.
        for id in required where newNodeSet.contains(id) {
            if let shapeID = binding.nodeIDs[id],let element = elements[shapeID],element.parent == nil {
                if inheritance[id] != nil { try attachInherited(id,element) }
                else { shapes.addChild(element) }
            }
        }
        binding.inheritedShapes = inheritance.filter{newNodeSet.contains($0.key) || newEdgeSet.contains($0.key)}.mapValues{$0}
        for id in required where binding.inheritedShapes?[id] != nil { binding.inheritedShapes?[id]?.implicit = false }
    }

    private static func preserveOpaqueInstance(_ original:XMLElement,in element:XMLElement) {
        let managed:Set<String> = ["ID","Master","MasterShape","Type","NameU","Del"]
        for attribute in original.attributes ?? [] where !managed.contains(attribute.name ?? "") { if element.attr(attribute.name ?? "") == nil { element.addAttribute(attribute.copy() as! XMLNode) } }
        for child in original.children ?? [] {
            guard let node = child as? XMLElement else { continue }
            if !["Cell","Section","Shapes","Text","ForeignData"].contains(node.localTag) { element.addChild(node.copy() as! XMLNode) }
            else if node.localTag == "Section",let name = node.attr("N"),!element.elementsLocal("Section").contains(where:{$0.attr("N") == name}) { element.addChild(node.copy() as! XMLNode) }
        }
    }

    static func localNode(_ node:DiagramNode,in page:DiagramPage) -> DiagramNode {
        guard let id = node.parentID,let parent = page.nodes.first(where:{$0.id == id}) else { return node }
        var local = node; let angle = -parent.rotation * .pi/180
        let dx = node.center.x-parent.center.x,dy = node.center.y-parent.center.y
        local.x = dx*cos(angle)-dy*sin(angle)+parent.width/2-node.width/2
        local.y = dx*sin(angle)+dy*cos(angle)+parent.height/2-node.height/2
        local.rotation -= parent.rotation
        if parent.formatting.flipX { local.x = parent.width-local.x-node.width }
        if parent.formatting.flipY { local.y = parent.height-local.y-node.height }
        if parent.formatting.flipX != parent.formatting.flipY { local.rotation = -local.rotation }
        local.formatting.flipX = node.formatting.flipX != parent.formatting.flipX;local.formatting.flipY = node.formatting.flipY != parent.formatting.flipY
        local.x += parent.sheetOrigin.x;local.y -= parent.sheetOrigin.y
        return local
    }

    private static func patchShape(_ node:DiagramNode,old:DiagramNode,element:XMLElement,pageHeight:Double,oldPageHeight:Double,parentChanged:Bool) throws {
        if node.width != old.width || node.height != old.height || node.rotation != old.rotation || node.formatting.flipX != old.formatting.flipX || node.formatting.flipY != old.formatting.flipY || node.sheetWidth != old.sheetWidth || node.sheetHeight != old.sheetHeight || parentChanged || abs(node.x-old.x)>1e-9 || abs((pageHeight-node.y)-(oldPageHeight-old.y))>1e-9 {
            let w = node.sheetWidth/72,h = node.sheetHeight/72,a = -node.rotation * .pi/180
            var lx = VisioXML.number(element,"LocPinX",Double(old.formatting.sheet["LocPinX"]?.value ?? "") ?? old.sheetWidth/144),ly = VisioXML.number(element,"LocPinY",Double(old.formatting.sheet["LocPinY"]?.value ?? "") ?? old.sheetHeight/144)
            let fx = element.elementsLocal("Cell").first(where:{$0.attr("N") == "LocPinX"})?.attr("F") ?? old.formatting.sheet["LocPinX"]?.formula ?? ""
            let fy = element.elementsLocal("Cell").first(where:{$0.attr("N") == "LocPinY"})?.attr("F") ?? old.formatting.sheet["LocPinY"]?.formula ?? ""
            func resolve(_ name:String) throws -> Double { if name.lowercased() == "width" { return w };if name.lowercased() == "height" { return h };if let v = node.formatting.sheet.first(where:{$0.key.caseInsensitiveCompare(name) == .orderedSame}).flatMap({Double($0.value.value)}) { return v };throw DiagramError.invalid("Unsupported pin formula") }
            if !fx.isEmpty,let v = try? ShapeSheet.evaluate(fx,resolve:resolve) { lx = v;VisioXML.set(element,"LocPinX",lx,formula:fx) }
            if !fy.isEmpty,let v = try? ShapeSheet.evaluate(fy,resolve:resolve) { ly = v;VisioXML.set(element,"LocPinY",ly,formula:fy) }
            if node.sheetWidth != old.sheetWidth { VisioXML.set(element,"Width",w) }
            if node.sheetHeight != old.sheetHeight { VisioXML.set(element,"Height",h) }
            let cx = node.center.x/72,cy = (pageHeight-node.center.y)/72
            let dx = (w/2-lx)*(node.formatting.flipX ? -1 : 1),dy = (h/2-ly)*(node.formatting.flipY ? -1 : 1)
            let pinX = cx-dx*cos(a)+dy*sin(a),pinY = cy-dx*sin(a)-dy*cos(a)
            if parentChanged || abs(VisioXML.number(element,"PinX",.infinity)-pinX)>1e-9 { VisioXML.set(element,"PinX",pinX) }
            if parentChanged || abs(VisioXML.number(element,"PinY",.infinity)-pinY)>1e-9 { VisioXML.set(element,"PinY",pinY) }
            if node.rotation != old.rotation || parentChanged { VisioXML.set(element,"Angle",a) }
            if node.formatting.geometry == nil && (node.width != old.width || node.height != old.height) { scaleCachedGeometry(element,x:node.width/old.width,y:node.height/old.height) }
        }
        if node.text != old.text || node.formatting.textRuns != old.formatting.textRuns {
            if node.formatting.textRuns != nil { ShapeRichText.patch(node,element:element,previous:old) } else { VisioXML.setText(element,node.text) }
        }
        if node.formatting.textFields != old.formatting.textFields { TextFieldEngine.patch(node.formatting.textFields ?? [],element:element,previous:old.formatting.textFields ?? []) }
        if node.fill != old.fill { VisioXML.set(element,"FillForegnd",String(node.fill.prefix(7))); VisioXML.set(element,"FillPattern",alpha(node.fill) == 0 ? 0 : 1); VisioXML.set(element,"FillForegndTrans",1-alpha(node.fill)) }
        if node.stroke != old.stroke { VisioXML.set(element,"LineColor",String(node.stroke.prefix(7))); VisioXML.set(element,"LinePattern",Double(alpha(node.stroke) == 0 ? 0 : node.formatting.linePattern)); VisioXML.set(element,"LineColorTrans",1-alpha(node.stroke)) }
        if node.strokeWidth != old.strokeWidth { VisioXML.set(element,"LineWeight",node.strokeWidth/72) }
        if node.locked != old.locked { VisioXML.set(element,"LockMoveX",node.locked ? 1 : 0); VisioXML.set(element,"LockMoveY",node.locked ? 1 : 0) }
        if node.fontSize != old.fontSize { VisioXML.set(VisioXML.row(element,"Character"),"Size",node.fontSize/72) }
        if node.textColor != old.textColor { VisioXML.set(VisioXML.row(element,"Character"),"Color",String(node.textColor.prefix(7))) }
        if node.bold != old.bold || node.formatting.italic != old.formatting.italic || node.formatting.underline != old.formatting.underline {
            let row = VisioXML.row(element,"Character"), extra = Int(VisioXML.number(VisioXML.row(element,"Character"),"Style")) & ~7
            VisioXML.set(row,"Style",Double(extra | (node.bold ? 1 : 0) | (node.formatting.italic ? 2 : 0) | (node.formatting.underline ? 4 : 0)))
        }
        if node.formatting.alignment != old.formatting.alignment { VisioXML.set(VisioXML.row(element,"Paragraph"),"HorzAlign",node.formatting.alignment == .left ? 0 : node.formatting.alignment == .right ? 2 : 1) }
        if node.formatting.linePattern != old.formatting.linePattern { VisioXML.set(element,"LinePattern",Double(node.formatting.linePattern)) }
        if node.formatting.flipX != old.formatting.flipX { VisioXML.set(element,"FlipX",node.formatting.flipX ? 1 : 0) }
        if node.formatting.flipY != old.formatting.flipY { VisioXML.set(element,"FlipY",node.formatting.flipY ? 1 : 0) }
        if node.formatting.data != old.formatting.data { patchData(node.formatting.data,element:element,previous:old.formatting.data) }
        if node.formatting.hyperlinks != old.formatting.hyperlinks { patchHyperlinks(node.formatting.hyperlinks,element:element,previous:old.formatting.hyperlinks) }
        if node.formatting.connectionPoints != old.formatting.connectionPoints || node.width != old.width || node.height != old.height { if !node.formatting.connectionPoints.isEmpty || !old.formatting.connectionPoints.isEmpty { patchConnectionPoints(ConnectionGeometry.cached(node.formatting.connectionPoints,on:node),element:element,previous:old.formatting.connectionPoints) } }
        if node.formatting.sheet != old.formatting.sheet { patchSheet(node.formatting.sheet,old:old.formatting.sheet,element:element) }
        if node.formatting.controls != old.formatting.controls { ControlGeometry.patch(node.formatting.controls,on:element,previous:old.formatting.controls) }
        if let geometry = node.formatting.geometry {
            if geometry != old.formatting.geometry { GeometrySheet.patch(geometry,element:element,previous:old.formatting.geometry ?? []) }
        } else if node.kind != old.kind || node.formatting.paths != old.formatting.paths {
            let generated = try VisioXML.element(VisioFormat.shapeXML(node,id:Int(element.attr("ID") ?? "1") ?? 1,pageHeight:pageHeight))
            for section in element.elementsLocal("Section") where section.attr("N") == "Geometry" { section.detach() }
            for section in generated.elementsLocal("Section") where section.attr("N") == "Geometry" { element.addChild(section.copy() as! XMLNode) }
        }
    }
    static func patchConnectionPoints(_ points:[ShapeConnectionPoint],element:XMLElement,previous:[ShapeConnectionPoint] = []) {
        let section = VisioXML.section(element,"Connection"),old = section.elementsLocal("Row")
        func key(_ row:XMLElement) -> String { row.attr("N").map{"N:"+$0} ?? "IX:"+(row.attr("IX") ?? "") }
        var rows:[UInt32:XMLElement] = [:]
        for (i,row) in old.enumerated() {
            let index = previous.first{$0.id == key(row)}?.index ?? row.attr("IX").flatMap(UInt32.init) ?? UInt32(i)
            if !previous.contains(where:{$0.id == key(row)}) { rows[index] = row }
        }
        for row in old { row.detach() }
        for point in points {
            let row = old.first{key($0) == point.id} ?? previous.first{$0.index == point.index}.flatMap{oldPoint in old.first{key($0) == oldPoint.id}} ?? XMLElement(name:"Row")
            row.setAttr("N",point.name);row.setAttr("IX",point.name == nil ? String(point.index) : nil);row.setAttr("Del",nil)
            VisioXML.set(row,"X",point.x.value,formula:point.x.formula.isEmpty ? nil : point.x.formula);VisioXML.set(row,"Y",point.y.value,formula:point.y.formula.isEmpty ? nil : point.y.formula)
            VisioXML.set(row,"DirX",point.directionX);VisioXML.set(row,"DirY",point.directionY);VisioXML.set(row,"Type",Double(point.type));rows[point.index] = row
        }
        for point in previous where !points.contains(where:{$0.index == point.index}) { let row = XMLElement(name:"Row");row.setAttr("N",point.name);row.setAttr("IX",point.name == nil ? String(point.index) : nil);row.setAttr("Del","1");rows[point.index] = row }
        if let lastNamed = points.filter({$0.name != nil}).map(\.index).max() {
            for index in 0...lastNamed where rows[index] == nil { let row = XMLElement(name:"Row");row.setAttr("N","_MacVisioDeleted\(index)");row.setAttr("Del","1");rows[index] = row }
        }
        for index in rows.keys.sorted() { section.addChild(rows[index]!) }
    }
    static func patchData(_ values:[ShapeDataProperty],element:XMLElement,previous:[ShapeDataProperty] = []) {
        let section = VisioXML.section(element,"Property")
        let original = section.elementsLocal("Row")
        for row in original { row.detach() }
        for p in values {
            let row = original.first(where:{$0.attr("N") == p.key}) ?? XMLElement(name:"Row");row.setAttr("N",p.key);row.setAttr("IX",nil);row.setAttr("Del",nil)
            VisioXML.set(row,"Label",p.label); VisioXML.set(row,"Value",p.value); VisioXML.set(row,"Type",Double(p.type)); VisioXML.set(row,"Format",p.format); VisioXML.set(row,"Prompt",p.prompt); section.addChild(row)
        }
        if element.attr("Master") != nil || element.attr("MasterShape") != nil {
            for key in Set(previous.map(\.key)).subtracting(values.map(\.key)) { let row = XMLElement(name:"Row");row.setAttr("N",key);row.setAttr("Del","1");section.addChild(row) }
        }
        // Empty optional sections confuse readers that seek an explicit end tag.
        // Retain deletion markers, which carry master-inheritance semantics.
        if section.childCount == 0 && section.attr("Del") != "1" { section.detach() }
    }
    static func patchSheet(_ values:[String:ShapeSheetCell],old:[String:ShapeSheetCell],element:XMLElement) {
        for (name,cell) in values where old[name] != cell {
            let parent:XMLElement,key:String
            if name.hasPrefix("User.") || name.hasPrefix("Prop.") {
                let sectionName = name.hasPrefix("User.") ? "User" : "Property",rowName = String(name.dropFirst(5))
                let section = VisioXML.section(element,sectionName)
                let row = section.elementsLocal("Row").first(where:{$0.attr("N") == rowName}) ?? XMLElement(name:"Row")
                if row.parent == nil { row.setAttr("N",rowName);row.setAttr("IX",String((section.elementsLocal("Row").compactMap{Int($0.attr("IX") ?? "")}.max() ?? -1)+1));section.addChild(row) }
                parent = row;key = "Value"
            } else if name == "Char.Size" { parent = VisioXML.row(element,"Character");key = "Size" }
            else { parent = element;key = name }
            let changed = VisioXML.set(parent,key,cell.value,formula:cell.formula.isEmpty ? nil : cell.formula)
            if !cell.unit.isEmpty { changed.setAttr("U",cell.unit) }
        }
    }
    static func patchHyperlinks(_ links:[ShapeHyperlink],element:XMLElement,previous:[ShapeHyperlink] = []) {
        let section = VisioXML.section(element,"Hyperlink"),original = section.elementsLocal("Row")
        for row in original { row.detach() }
        var names = Set<String>()
        for (index,link) in links.enumerated() {
            var name = link.sourceRowName ?? (index < previous.count ? previous[index].sourceRowName : nil) ?? "Row_\(index+1)"
            while names.contains(name) { name += "_" };names.insert(name)
            let row = original.first{$0.attr("N") == name} ?? XMLElement(name:"Row");row.setAttr("IX",nil);row.setAttr("N",name);row.setAttr("Del",nil)
            VisioXML.set(row,"Address",link.address);VisioXML.set(row,"SubAddress",link.subAddress);VisioXML.set(row,"Description",link.description);section.addChild(row)
        }
        if element.attr("Master") != nil || element.attr("MasterShape") != nil {
            for name in Set(previous.compactMap(\.sourceRowName)).subtracting(names) { let row = XMLElement(name:"Row");row.setAttr("N",name);row.setAttr("Del","1");section.addChild(row) }
        }
        if section.childCount == 0 && section.attr("Del") != "1" { section.detach() }
    }
    static func patchLayers(_ page:DiagramPage,sheet:XMLElement,originalLayers:[DiagramLayer] = []) {
        let section = VisioXML.section(sheet,"Layer"), original = VisioXML.section(sheet,"Layer").elementsLocal("Row")
        var next = (original.compactMap{Int($0.attr("IX") ?? "")}.max() ?? -1)+1
        for row in original { row.detach() }
        for layer in page.layers ?? [] {
            let sourceName = originalLayers.first(where:{$0.id == layer.id})?.name
            let row = original.first(where:{VisioXML.value($0,"Name") == layer.name}) ?? sourceName.flatMap{name in original.first(where:{VisioXML.value($0,"Name") == name})} ?? XMLElement(name:"Row")
            if row.attr("IX") == nil { row.setAttr("IX",String(next)); next += 1 }
            for (name,cell) in layer.sheet where VisioXML.value(row,name) == nil {
                let node = VisioXML.set(row,name,cell.value,formula:cell.formula.isEmpty ? nil : cell.formula);node.setAttr("U",cell.unit.isEmpty ? nil : cell.unit)
            }
            func setIfChanged(_ name:String,_ value:String) { if VisioXML.value(row,name) != value { VisioXML.set(row,name,value) } }
            setIfChanged("Name",layer.name);setIfChanged("Visible",layer.visible ? "1" : "0");setIfChanged("Lock",layer.locked ? "1" : "0");setIfChanged("Print",layer.printable ? "1" : "0")
            setIfChanged("Snap",layer.snap ? "1" : "0");setIfChanged("Glue",layer.glue ? "1" : "0")
            func matchesImportedCell(_ name:String) -> Bool {
                let current = row.elementsLocal("Cell").first{$0.attr("N") == name},source = layer.sheet[name]
                guard let source else { return current == nil }
                return current?.attr("V") == source.value && (current?.attr("F") ?? "") == source.formula && (current?.attr("U") ?? "") == source.unit
            }
            if layer.color != layer.sourceColor || !matchesImportedCell("Color") {
                let value = layer.color ?? "255"
                if VisioXML.value(row,"Color") != value { VisioXML.set(row,"Color",value) }
            }
            if let sourceTransparency = layer.sourceColorTransparency {
                if abs(layer.colorTransparency-sourceTransparency) > 0.001 || !matchesImportedCell("ColorTrans") {
                    VisioXML.set(row,"ColorTrans",String(format:"%.6g",locale:Locale(identifier:"en_US_POSIX"),max(0,min(100,layer.colorTransparency))/100))
                }
            } else if layer.colorTransparency != 0 {
                VisioXML.set(row,"ColorTrans",String(format:"%.6g",locale:Locale(identifier:"en_US_POSIX"),max(0,min(100,layer.colorTransparency))/100))
            }
            section.addChild(row)
        }
    }
    static func patchPageSheetCells(_ current:[String:ShapeSheetCell],from original:[String:ShapeSheetCell],sheet:XMLElement) {
        for key in Set(current.keys).union(original.keys) where current[key] != original[key] {
            if ["PageWidth","PageHeight","PageScale","DrawingScale","DrawingScaleType"].contains(where:{$0.caseInsensitiveCompare(key) == .orderedSame}) { continue }
            let cellValue = current[key]
            if key.hasPrefix("User.") || key.hasPrefix("Prop.") {
                let sectionName = key.hasPrefix("User.") ? "User" : "Property"
                let remainder = String(key.dropFirst(sectionName == "User" ? 5 : 5))
                let parts = remainder.split(separator:".",omittingEmptySubsequences:false).map(String.init)
                guard let rowName = parts.first,!rowName.isEmpty else { continue }
                let cellName = parts.count > 1 ? parts.dropFirst().joined(separator:".") : "Value"
                let existingSection = sheet.elementsLocal("Section").first{$0.attr("N") == sectionName}
                if cellValue == nil,let row = existingSection?.elementsLocal("Row").first(where:{$0.attr("N") == rowName}) {
                    row.elementsLocal("Cell").first(where:{$0.attr("N") == cellName})?.detach();continue
                }
                let section = existingSection ?? VisioXML.section(sheet,sectionName)
                var row = section.elementsLocal("Row").first{$0.attr("N") == rowName}
                if row == nil {
                    row = XMLElement(name:"Row");row!.setAttr("N",rowName)
                    let next = (section.elementsLocal("Row").compactMap{Int($0.attr("IX") ?? "")}.max() ?? -1)+1
                    row!.setAttr("IX",String(next));section.addChild(row!)
                }
                guard let cellValue else { continue }
                let cell = row!.elementsLocal("Cell").first{$0.attr("N") == cellName} ?? XMLElement(name:"Cell")
                if cell.parent == nil { row!.addChild(cell) }
                cell.setAttr("N",cellName);cell.setAttr("V",cellValue.value);cell.setAttr("F",cellValue.formula.isEmpty ? nil : cellValue.formula);cell.setAttr("U",cellValue.unit.isEmpty ? nil : cellValue.unit)
            } else {
                let existing = sheet.elementsLocal("Cell").first{$0.attr("N") == key}
                guard let cellValue else { existing?.detach();continue }
                let cell = existing ?? XMLElement(name:"Cell")
                if cell.parent == nil { sheet.insertChild(cell,at:0) }
                cell.setAttr("N",key);cell.setAttr("V",cellValue.value);cell.setAttr("F",cellValue.formula.isEmpty ? nil : cellValue.formula);cell.setAttr("U",cellValue.unit.isEmpty ? nil : cellValue.unit)
            }
        }
    }
    private static func scaleCachedGeometry(_ element:XMLElement,x:Double,y:Double) {
        for section in element.elementsLocal("Section") where section.attr("N") == "Geometry" {
            for row in section.elementsLocal("Row") {
                let type = row.attr("T") ?? ""; if type.hasPrefix("Rel") { continue }
                for cell in row.elementsLocal("Cell") {
                    guard let name = cell.attr("N"),let value = Double(cell.attr("V") ?? "") else { continue }
                    let factor:Double
                    if name == "X" || (["CubBezTo","Ellipse","EllipticalArcTo"].contains(type) && ["A","C"].contains(name)) { factor = x }
                    else if name == "Y" || (["CubBezTo","Ellipse","EllipticalArcTo"].contains(type) && ["B","D"].contains(name)) { factor = y }
                    else if type == "ArcTo" && name == "A" { factor = sqrt(x*y) }
                    else { continue }
                    cell.setAttr("V",String(format:"%.12g",locale:Locale(identifier:"en_US_POSIX"),value*factor))
                }
            }
        }
    }
    static func attachImage(_ image:EmbeddedImage,to element:XMLElement,root:XMLElement,part:String,parts:inout [String:Data],types:XMLElement) throws {
        let ext = image.mimeType == "image/jpeg" ? "jpg" : image.mimeType == "application/pdf" ? "pdf" : image.mimeType == "image/svg+xml" ? "svg" : "png"
        let media = "visio/media/macvisio-\(UUID().uuidString).\(ext)"; parts[media] = image.data
        let relPart = VisioXML.relationshipPart(part)
        let rels = try VisioXML.document(parts[relPart] ?? Data("<Relationships xmlns=\"\(relNS)\"/>".utf8))
        let relRoot = rels.rootElement()!, rid = uniqueRelationshipID(relRoot)
        let relation = XMLElement(name:"Relationship"); relation.setAttr("Id",rid); relation.setAttr("Type","http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"); relation.setAttr("Target","../media/"+(media as NSString).lastPathComponent); relRoot.addChild(relation)
        for foreign in element.elementsLocal("ForeignData") { foreign.detach() }
        let foreign = XMLElement(name:"ForeignData"); foreign.setAttr("ForeignType","Bitmap"); foreign.setAttr("CompressionType",ext == "jpg" ? "JPEG" : "PNG")
        let rel = XMLElement(name:"Rel"); rel.setAttr("r:id",rid); foreign.addChild(rel); element.addChild(foreign); element.setAttr("Type","Foreign")
        parts[relPart] = rels.xmlData(options:.nodePreserveAll); ensureType(ext,image.mimeType,root:types)
    }
    private static func alpha(_ value:String) -> Double { value.count == 9 ? Double(UInt8(value.suffix(2),radix:16) ?? 255)/255 : 1 }
    static func ensureFonts(_ diagram:Diagram,parts:inout [String:Data],bindings:[VisioPageBinding],original:[DiagramPage]? = nil) throws {
        guard let relationshipsData = parts["_rels/.rels"] else { return }
        let rels = try VisioXML.document(relationshipsData)
        guard let relationship = rels.rootElement()?.elementsLocal("Relationship").first(where:{$0.attr("Type") == visioRel+"document"}),let target = relationship.attr("Target") else { return }
        let docPart = try VisioFormat.resolve(target,relativeTo:"")
        guard let data = parts[docPart] else { return }
        let document = try VisioXML.document(data)
        guard let root = document.rootElement() else { return }
        let faces = root.firstLocal("FaceNames") ?? XMLElement(name:"FaceNames");if faces.parent == nil { root.insertChild(faces,at:0) }
        var changedDocument = false,ids:[String:String] = [:]
        for (index,face) in faces.elementsLocal("FaceName").enumerated() {
            if let name = face.attr("NameU") ?? face.attr("Name") {
                if ids[name] == nil { ids[name] = String(index) }
                if face.attr("NameU") == nil { face.setAttr("NameU",name);changedDocument = true }
            }
        }
        var nextID = faces.elementsLocal("FaceName").count
        for page in diagram.pages {
            guard let binding = bindings.first(where:{$0.pageID == page.id}),let data = parts[binding.part] else { continue }
            let old = original?.first(where:{$0.id == page.id})
            let changed = page.nodes.filter { node in
                let previous = old?.nodes.first(where:{$0.id == node.id})
                return original == nil || previous?.formatting.fontName != node.formatting.fontName || previous?.formatting.textRuns != node.formatting.textRuns
            }
            guard !changed.isEmpty else { continue }
            let pageXML = try VisioXML.document(data)
            let shapes = pageXML.rootElement()?.firstLocal("Shapes")?.allShapes ?? []
            for node in changed {
                guard let id = binding.nodeIDs[node.id],let element = shapes.first(where:{$0.attr("ID") == id}) else { continue }
                let section = VisioXML.section(element,"Character")
                let rows = section.elementsLocal("Row")
                let entries:[(index:Int,name:String)] = node.formatting.textRuns == nil ? ShapeRichText.fontRows(node) : rows.compactMap { row in
                    guard let name = VisioXML.value(row,"Font"),Double(name) == nil,let index = Int(row.attr("IX") ?? "") else { return nil };return (index,name)
                }
                for entry in entries {
                    let name = entry.name == "System" ? "Arial" : entry.name
                    if ids[name] == nil { let face = XMLElement(name:"FaceName");face.setAttr("NameU",name);faces.addChild(face);ids[name] = String(nextID);nextID += 1;changedDocument = true }
                    let row = rows.first{$0.attr("IX") == String(entry.index)} ?? VisioXML.row(element,"Character")
                    VisioXML.set(row,"Font",ids[name]!,formula:"FONT(\"\(name)\")")
                }
            }
            parts[binding.part] = pageXML.xmlData(options:.nodePreserveAll)
        }
        if changedDocument { parts[docPart] = document.xmlData(options:.nodePreserveAll) }
    }
    private static func ensureType(_ ext:String,_ mime:String,root:XMLElement) { if !root.elementsLocal("Default").contains(where:{$0.attr("Extension") == ext}) { let type = XMLElement(name:"Default"); type.setAttr("Extension",ext); type.setAttr("ContentType",mime); root.addChild(type) } }
    private static func uniqueRelationshipID(_ root:XMLElement) -> String { let taken = Set(root.elementsLocal("Relationship").compactMap{$0.attr("Id")}); var number = 1; while taken.contains("rId\(number)") { number += 1 }; return "rId\(number)" }
}
