import Foundation

enum VisioReusableFormat {
    static let relationship = "http://schemas.microsoft.com/visio/2010/relationships/"
    static func documentPart(_ parts:[String:Data]) throws -> String {
        guard let data = parts["_rels/.rels"],let root = try VisioXML.document(data).rootElement(),
              let rel = root.elementsLocal("Relationship").first(where:{$0.attr("Type") == relationship+"document"}),
              rel.attr("TargetMode") != "External",let target = rel.attr("Target") else { throw DiagramError.invalid("The package has no Visio document relationship.") }
        return try VisioFormat.resolve(target,relativeTo:"")
    }
    static func setMainContentType(_ type:String,parts:inout [String:Data]) throws {
        let part = try documentPart(parts)
        guard let data = parts["[Content_Types].xml"] else { throw DiagramError.invalid("The Visio content type index is missing.") }
        let index = try VisioXML.document(data)
        guard let entry = index.rootElement()?.elementsLocal("Override").first(where:{$0.attr("PartName") == "/"+part}) else { throw DiagramError.invalid("The Visio document content type is missing.") }
        entry.setAttr("ContentType",type)
        parts["[Content_Types].xml"] = index.xmlData(options:.nodePreserveAll)
    }
    static func writeTemplate(_ diagram:Diagram,to url:URL) throws {
        guard url.pathExtension.lowercased() == "vstx" else { throw DiagramError.invalid("Visio templates must use the .vstx extension.") }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-template-\(UUID()).vsdx")
        defer { try? FileManager.default.removeItem(at:temp) }
        try VisioFormat.write(diagram,to:temp)
        let saved = try VisioFormat.read(from:temp).diagram
        var parts = try VisioPackage.read(temp)
        try setMainContentType("application/vnd.ms-visio.template.main+xml",parts:&parts)
        parts["macvisio/document.json"] = try VisioFormat.nativeMetadata(saved,parts:&parts,bindings:saved.visioArchive?.pages)
        try VisioPackage.write(parts,to:url)
    }
    static func writeStencil(_ definitions:[StencilDefinition],to url:URL) throws {
        guard url.pathExtension.lowercased() == "vssx",!definitions.isEmpty,definitions.count <= 1000 else { throw DiagramError.invalid("A stencil needs 1–1000 masters and a .vssx extension.") }
        // Serialize supported editable features using the drawing serializer, then
        // relocate each page to a proper public master part. No private metadata.
        var diagram = Diagram();diagram.title = url.deletingPathExtension().lastPathComponent
        diagram.pages = definitions.map { definition in
            var page = definition.fragment;page.id = UUID();page.name = definition.name;page.isBackground = nil;page.backgroundPageID = nil;return page
        }
        diagram.activePageID = diagram.pages[0].id
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-stencil-\(UUID()).vsdx")
        defer { try? FileManager.default.removeItem(at:temp) }
        try VisioFormat.write(diagram,to:temp)
        var parts = try VisioPackage.read(temp)
        let ns = "http://schemas.microsoft.com/office/visio/2012/main",rns = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        let masters = try VisioXML.element("<Masters xmlns=\"\(ns)\" xmlns:r=\"\(rns)\"/>")
        let relations = try VisioXML.element("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"/>")
        let pages = try VisioXML.document(parts["visio/pages/pages.xml"]!).rootElement()!.elementsLocal("Page")
        let types = try VisioXML.document(parts["[Content_Types].xml"]!),typeRoot = types.rootElement()!
        for entry in typeRoot.elementsLocal("Override") where entry.attr("PartName")?.hasPrefix("/visio/pages/") == true || entry.attr("PartName") == "/macvisio/document.json" { entry.detach() }
        func contentType(_ part:String,_ type:String) { let entry = XMLElement(name:"Override");entry.setAttr("PartName","/"+part);entry.setAttr("ContentType",type);typeRoot.addChild(entry) }
        for (i,page) in pages.enumerated() {
            let source = "visio/pages/page\(i+1).xml",target = "visio/masters/master\(i+1).xml"
            let content = try VisioXML.document(parts[source]!);content.rootElement()!.name = "MasterContents"
            parts[target] = content.xmlData(options:.nodePreserveAll)
            if let data = parts[VisioXML.relationshipPart(source)] {
                let rels = try VisioXML.document(data)
                for rel in rels.rootElement()?.elementsLocal("Relationship") ?? [] where rel.attr("TargetMode") != "External" {
                    if let value = rel.attr("Target") { rel.setAttr("Target","/"+(try VisioFormat.resolve(value,relativeTo:source))) }
                }
                parts[VisioXML.relationshipPart(target)] = rels.xmlData(options:.nodePreserveAll)
            }
            let master = XMLElement(name:"Master");master.setAttr("ID",String(i+1));master.setAttr("Name",definitions[i].name);master.setAttr("NameU",definitions[i].name)
            master.setAttr("BaseID","{\(UUID().uuidString)}");master.setAttr("UniqueID","{\(UUID().uuidString)}");master.setAttr("MatchByName","0");master.setAttr("IconUpdate","1")
            if let sheet = page.firstLocal("PageSheet")?.copy() as? XMLElement { master.addChild(sheet) }
            let rel = XMLElement(name:"Rel");rel.setAttr("r:id","rId\(i+1)");master.addChild(rel);masters.addChild(master)
            let relation = XMLElement(name:"Relationship");relation.setAttr("Id","rId\(i+1)");relation.setAttr("Type",relationship+"master");relation.setAttr("Target","master\(i+1).xml");relations.addChild(relation)
            contentType(target,"application/vnd.ms-visio.master+xml")
        }
        contentType("visio/masters/masters.xml","application/vnd.ms-visio.masters+xml")
        parts["visio/masters/masters.xml"] = Data(masters.xmlString.utf8);parts["visio/masters/_rels/masters.xml.rels"] = Data(relations.xmlString.utf8)
        let documentRels = try VisioXML.document(parts["visio/_rels/document.xml.rels"]!),docRoot = documentRels.rootElement()!
        for entry in docRoot.elementsLocal("Relationship") where entry.attr("Type") == relationship+"pages" { entry.setAttr("Type",relationship+"masters");entry.setAttr("Target","masters/masters.xml") }
        parts["visio/_rels/document.xml.rels"] = documentRels.xmlData(options:.nodePreserveAll)
        let packageRels = try VisioXML.document(parts["_rels/.rels"]!)
        for entry in packageRels.rootElement()!.elementsLocal("Relationship") where entry.attr("Target") == "macvisio/document.json" { entry.detach() }
        parts["_rels/.rels"] = packageRels.xmlData(options:.nodePreserveAll)
        for name in Array(parts.keys) where name.hasPrefix("visio/pages/") || name == "macvisio/document.json" { parts.removeValue(forKey:name) }
        parts["[Content_Types].xml"] = types.xmlData(options:.nodePreserveAll)
        try setMainContentType("application/vnd.ms-visio.stencil.main+xml",parts:&parts)
        try VisioPackage.write(parts,to:url)
    }
}
