import MacVisioInfrastructure
import Foundation

struct StencilDefinition: Identifiable {
    var id = UUID()
    var name: String
    var family: String
    var fragment: DiagramPage
    var source: StencilSource? = nil
    var searchMetadata: String { [name,family,source?.universalName ?? "",source?.masterID ?? "",source?.url.lastPathComponent ?? ""].joined(separator:" ") }
    var metadataDescription: String {
        guard let source else { return name + " · " + family }
        return [name,"\(family) · Master \(source.masterID)",source.universalName,source.url.path].filter{!$0.isEmpty}.joined(separator:"\n")
    }
}
enum VisioStencil {
    static func read(from url:URL) throws -> (items:[StencilDefinition],warnings:[String]) {
        let imported = try readWithPalette(from:url)
        return (imported.items,imported.warnings)
    }
    static func readForCalculationAudit(from url:URL) throws -> (items:[StencilDefinition],warnings:[String],paletteArchive:VisioDocumentArchive?) {
        try readWithPalette(from:url)
    }
    private static func readWithPalette(from url:URL) throws -> (items:[StencilDefinition],warnings:[String],paletteArchive:VisioDocumentArchive?) {
        let job = LifecycleJobContext.current
        try job?.checkpoint()
        if url.pathExtension.lowercased() == "vss" {
            let imported = try LegacyVisioFormat.graphicPages(from:url,stencils:true)
            let usable = imported.pages.filter{!$0.nodes.isEmpty || !$0.edges.isEmpty}
            guard !usable.isEmpty else { throw DiagramError.invalid("This binary stencil has no supported visible masters.") }
            return (try definitions(usable,family:url.deletingPathExtension().lastPathComponent),imported.warnings+["Binary stencil masters are imported as editable cached graphics. Original master names, formulas, shape data and glue are not retained."],nil)
        }
        var parts = try VisioPackage.read(url)
        let relType = "http://schemas.microsoft.com/visio/2010/relationships/"
        let packageRels = try VisioXML.document(parts["_rels/.rels"]!)
        guard let root = packageRels.rootElement(),let docRel = root.elementsLocal("Relationship").first(where:{$0.attr("Type") == relType+"document"}),let docTarget = docRel.attr("Target") else { throw DiagramError.invalid("The stencil has no Visio document relationship.") }
        let docPart = try VisioFormat.resolve(docTarget,relativeTo:"")
        let documentRelsPart = VisioXML.relationshipPart(docPart)
        guard let relData = parts[documentRelsPart] else { throw DiagramError.invalid("The stencil has no master relationships.") }
        let documentRels = try VisioXML.document(relData)
        guard let relRoot = documentRels.rootElement(),let mastersRel = relRoot.elementsLocal("Relationship").first(where:{$0.attr("Type") == relType+"masters"}),let target = mastersRel.attr("Target") else { throw DiagramError.invalid("This package does not contain stencil masters.") }
        let mastersPart = try VisioFormat.resolve(target,relativeTo:docPart)
        guard let mastersData = parts[mastersPart],let masterRelsData = parts[VisioXML.relationshipPart(mastersPart)] else { throw DiagramError.invalid("The stencil master index is incomplete.") }
        let masters = try VisioXML.document(mastersData),masterRels = try VisioXML.document(masterRelsData)
        let masterElements = masters.rootElement()?.elementsLocal("Master") ?? []
        guard !masterElements.isEmpty,masterElements.count <= 1000 else { throw DiagramError.invalid("The stencil is empty or contains too many masters.") }
        let namespace = "http://schemas.microsoft.com/office/visio/2012/main",relationNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let pagesRoot = try VisioXML.element("<Pages xmlns=\"\(namespace)\" xmlns:r=\"\(relationNS)\"/>")
        let pagesRels = try VisioXML.element("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"/>")
        let types = try VisioXML.document(parts["[Content_Types].xml"]!)
        guard let typeRoot = types.rootElement(),typeRoot.localTag == "Types" else { throw DiagramError.invalid("The stencil has an invalid content type index.") }
        let virtualDirectory = "visio/macvisio-stencil-\(UUID().uuidString)",indexPart = virtualDirectory+"/pages.xml"
        for (i,master) in masterElements.enumerated() {
            try job?.checkpoint()
            job?.progress("Importing master \(i + 1) of \(masterElements.count)",fraction:Double(i) / Double(masterElements.count))
            guard let id = master.firstLocal("Rel")?.attributes?.first(where:{$0.localName == "id" || $0.name == "r:id"})?.stringValue,
                  let relationship = masterRels.rootElement()?.elementsLocal("Relationship").first(where:{$0.attr("Id") == id}),let target = relationship.attr("Target") else { throw DiagramError.invalid("A stencil master has no content relationship.") }
            let masterPart = try VisioFormat.resolve(target,relativeTo:mastersPart)
            guard let content = parts[masterPart],let contents = try VisioXML.document(content).rootElement() else { throw DiagramError.invalid("A stencil master is missing its content.") }
            let part = virtualDirectory+"/page\(i+1).xml"
            contents.name = "PageContents"
            parts[part] = Data(contents.xmlString.utf8)
            if let data = parts[VisioXML.relationshipPart(masterPart)] {
                let relations = try VisioXML.document(data)
                for relation in relations.rootElement()?.elementsLocal("Relationship") ?? [] where relation.attr("TargetMode") != "External" { if let value = relation.attr("Target") { relation.setAttr("Target","/"+(try VisioFormat.resolve(value,relativeTo:masterPart))) } }
                parts[VisioXML.relationshipPart(part)] = relations.xmlData(options:.nodePreserveAll)
            }
            let page = XMLElement(name:"Page");page.setAttr("ID",String(i));page.setAttr("Name",master.attr("Name") ?? master.attr("NameU") ?? "Master \(i+1)");page.setAttr("NameU",master.attr("NameU") ?? "Master\(i+1)")
            let sheet = master.firstLocal("PageSheet")?.copy() as? XMLElement ?? XMLElement(name:"PageSheet")
            if VisioXML.value(sheet,"PageWidth") == nil { VisioXML.set(sheet,"PageWidth",12) };if VisioXML.value(sheet,"PageHeight") == nil { VisioXML.set(sheet,"PageHeight",12) };page.addChild(sheet)
            let rel = XMLElement(name:"Rel");rel.setAttr("r:id","rId\(i+1)");page.addChild(rel);pagesRoot.addChild(page)
            let r = XMLElement(name:"Relationship");r.setAttr("Id","rId\(i+1)");r.setAttr("Type",relType+"page");r.setAttr("Target","page\(i+1).xml");pagesRels.addChild(r)
            let type = XMLElement(name:"Override");type.setAttr("PartName","/"+part);type.setAttr("ContentType","application/vnd.ms-visio.page+xml");typeRoot.addChild(type)
        }
        for r in relRoot.elementsLocal("Relationship") where r.attr("Type") == relType+"pages" { r.detach() }
        let pageRel = XMLElement(name:"Relationship");pageRel.setAttr("Id","macvisioPages");pageRel.setAttr("Type",relType+"pages");pageRel.setAttr("Target","/"+indexPart);relRoot.addChild(pageRel)
        for type in typeRoot.elementsLocal("Override") where type.attr("PartName") == "/"+docPart { type.setAttr("ContentType","application/vnd.ms-visio.drawing.main+xml") }
        let type = XMLElement(name:"Override");type.setAttr("PartName","/"+indexPart);type.setAttr("ContentType","application/vnd.ms-visio.pages+xml");typeRoot.addChild(type)
        parts[indexPart] = Data(pagesRoot.xmlString.utf8);parts[VisioXML.relationshipPart(indexPart)] = Data(pagesRels.xmlString.utf8)
        parts[documentRelsPart] = documentRels.xmlData(options:.nodePreserveAll);parts["[Content_Types].xml"] = types.xmlData(options:.nodePreserveAll);parts.removeValue(forKey:"macvisio/document.json")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("Stencil-\(UUID()).vsdx");defer{try? FileManager.default.removeItem(at:temp)}
        try VisioPackage.write(parts,to:temp)
        try job?.checkpoint()
        let imported = try VisioFormat.read(from:temp)
        // Calculate supported RGB formulas while the stencil's ColorEntry table is
        // still available, before its master fragments are detached from the package.
        let calculated = cacheRGBValues(imported.diagram)
        var items = try definitions(calculated.pages,family:url.deletingPathExtension().lastPathComponent)
        guard items.count == masterElements.count else { throw DiagramError.invalid("The stencil master metadata does not match its public pages.") }
        let sourceURL = url.standardizedFileURL.resolvingSymlinksInPath()
        for i in items.indices {
            try job?.checkpoint()
            guard let id = masterElements[i].attr("ID"),UInt32(id) != nil else { throw DiagramError.invalid("The stencil contains an invalid public master identity.") }
            items[i].source = StencilSource(url:sourceURL,masterID:id,universalName:masterElements[i].attr("NameU") ?? masterElements[i].attr("Name") ?? "")
        }
        return (items,imported.warnings,imported.diagram.visioArchive)
    }
    private static func cacheRGBValues(_ input:Diagram) -> Diagram {
        var diagram = input
        let palette = ShapeSheetColorPalette(documentArchive:input.visioArchive)
        for pageIndex in diagram.pages.indices {
            let binding = diagram.visioArchive?.pages.first{$0.pageID == diagram.pages[pageIndex].id}
            let context = ShapeSheetContext(page:diagram.pages[pageIndex],binding:binding,colorPalette:palette,document:diagram)
            for nodeIndex in diagram.pages[pageIndex].nodes.indices {
                let node = diagram.pages[pageIndex].nodes[nodeIndex]
                for key in node.formatting.sheet.keys {
                    guard let cell = node.formatting.sheet[key],cell.formula.localizedCaseInsensitiveContains("RGB(") else { continue }
                    if let value = try? context.value(node.id,key) { diagram.pages[pageIndex].nodes[nodeIndex].formatting.sheet[key]?.value = ShapeSheetContext.cached(value) }
                }
            }
        }
        return diagram
    }
    static func definitions(_ pages:[DiagramPage],family:String) throws -> [StencilDefinition] {
        try pages.map { page -> StencilDefinition in
            try LifecycleJobContext.current?.checkpoint()
            var fragment = page
            var bounds = page.nodes.reduce(CGRect.null){ result,node in
                var points = [CGPoint(x:0,y:0),CGPoint(x:node.width,y:0),CGPoint(x:node.width,y:node.height),CGPoint(x:0,y:node.height)]
                for command in node.formatting.paths.flatMap(\.commands) { for i in stride(from:0,to:command.values.count-1,by:2) { points.append(CGPoint(x:command.values[i]*node.width,y:command.values[i+1]*node.height)) } }
                if !node.text.isEmpty,let box = node.formatting.textBox {
                    let center = CGPoint(x:box.centerX*node.width,y:box.centerY*node.height),w = box.width*node.width/2,h = box.height*node.height/2,a = box.rotation * .pi/180
                    for p in [CGPoint(x:-w,y:-h),CGPoint(x:w,y:-h),CGPoint(x:w,y:h),CGPoint(x:-w,y:h)] { points.append(CGPoint(x:center.x+p.x*cos(a)-p.y*sin(a),y:center.y+p.x*sin(a)+p.y*cos(a))) }
                }
                return points.reduce(result){$0.union(CGRect(origin:DiagramCoordinates.world($1,in:node),size:.zero))}
            }
            for edge in page.edges { for point in DiagramGeometry.route(edge,in:page) { bounds = bounds.union(CGRect(origin:point,size:.zero)) } }
            if !bounds.isNull {
                for i in fragment.nodes.indices { fragment.nodes[i].x -= bounds.minX;fragment.nodes[i].y -= bounds.minY }
                for i in fragment.edges.indices {
                    fragment.edges[i].points = fragment.edges[i].points?.map{DiagramPoint(x:$0.x-bounds.minX,y:$0.y-bounds.minY)}
                    if let p = fragment.edges[i].sourcePosition { fragment.edges[i].sourcePosition = DiagramPoint(x:p.x-bounds.minX,y:p.y-bounds.minY) }
                    if let p = fragment.edges[i].targetPosition { fragment.edges[i].targetPosition = DiagramPoint(x:p.x-bounds.minX,y:p.y-bounds.minY) }
                }
                fragment.width = max(1,bounds.width);fragment.height = max(1,bounds.height)
            }
            var check = Diagram();check.pages = [fragment];check.activePageID = fragment.id;_ = try check.validated()
            return StencilDefinition(name:page.name,family:family,fragment:fragment)
        }
    }
}
