import MacVisioInfrastructure
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import CryptoKit

struct VisioImportResult {
    let diagram: Diagram
    let warnings: [String]
    var legacyNative = false
    var diagnostics: [DocumentDiagnostic] = []
}

/// OPC/ShapeSheet interchange. This is deliberately a bounded, non-executing reader:
/// masters supply cached values; ShapeSheet formulas, VBA and external links never run.
enum VisioFormat {
    private static let visioNamespace = "http://schemas.microsoft.com/office/visio/2012/main"
    private static let relationshipNamespace = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let officeThemeRelationship = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme"
    private static let visioRelationship = "http://schemas.microsoft.com/visio/2010/relationships/"
    private static let nativePart = "macvisio/document.json"

    static func read(from url: URL,trace:((String)->Void)? = nil) throws -> VisioImportResult {
        try read(archive: PackageReader(url: url), title: url.deletingPathExtension().lastPathComponent, trace: trace)
    }

    /// Used by definition projection: the public package remains the semantic
    /// input even when a hash-valid native cache is present.
    static func readPublic(parts: [String: Data], title: String) throws -> VisioImportResult {
        try read(archive: PackageReader(parts: parts), title: title, allowNativeMetadata: false)
    }

    private static func read(archive: PackageReader, title: String, allowNativeMetadata: Bool = true,
                             trace: ((String) -> Void)? = nil) throws -> VisioImportResult {
        try LifecycleJobContext.current?.checkpoint()
        trace?("package")
        _ = try archive.xml("[Content_Types].xml", expectedRoot: "Types")
        let rootRelationships = try relationships(in: archive, source: "")
        guard let documentRelationship = rootRelationships.values.first(where: { $0.type == visioRelationship + "document" }),
              !documentRelationship.external else {
            throw DiagramError.invalid("This archive is not a Visio drawing: the document relationship is missing.")
        }
        let documentPart = try resolve(documentRelationship.target, relativeTo: "")
        let document = try archive.xml(documentPart, expectedRoot: "VisioDocument")
        let documentRelationships = try relationships(in:archive,source:documentPart)
        var warnings = Set<String>()
        var importDiagnostics: [DocumentDiagnostic] = []
        var officeTheme: VisioTheme?
        do { officeTheme = try selectedOfficeTheme(in:documentRelationships,documentPart:documentPart,archive:archive) }
        catch { warnings.insert("The Office theme could not be imported; its package parts are preserved.") }
        let hasMasters = documentRelationships.values.contains{$0.type == visioRelationship+"masters" && !$0.external}
        trace?("document")

        // Only accept the private representation if every public part still matches.
        // Editing the drawing in Visio therefore cannot make our JSON hide new content.
        if allowNativeMetadata && archive.names.contains(nativePart) {
            do {
                let storedMetadata = try NativeMetadataStorage.load(archive.data(nativePart), parts: archive.parts)
                trace?("metadataStorage")
                let envelope = try JSONDecoder().decode(NativeEnvelope.self, from: storedMetadata.data)
                trace?("metadataDecode")
                if [1, 2, 4].contains(envelope.format), !envelope.publicHashes.isEmpty {
                    let needsPorts = envelope.connectionPointsVersion != 1 && archive.parts.contains{part in
                        guard part.key.hasSuffix(".xml"),let xml = String(data:part.value,encoding:.utf8) else { return false }
                        return xml.range(of:"<[^>]*Section\\b[^>]*\\bN\\s*=\\s*[\"']Connection[\"']",options:.regularExpression) != nil
                    }
                    if needsPorts { warnings.insert("Older native metadata did not model connection points; public Visio content was reimported.") }
                    var matches = true
                    for (part, expected) in envelope.publicHashes {
                        guard archive.names.contains(part) else { matches = false; break }
                        if hash(try archive.data(part)) != expected { matches = false; break }
                    }
                    trace?("metadataHashes")
                    let publicNames = Set(archive.names.filter { envelope.format >= 2 ? $0 != nativePart && !storedMetadata.storageParts.contains($0) : $0.hasPrefix("visio/") && ($0.hasSuffix(".xml") || $0.hasSuffix(".rels")) })
                    if hasMasters,envelope.masterExpansionVersion != 1 { warnings.insert("Older native metadata did not expand master subshapes; the public Visio content was reimported.") }
                    let needsTransforms = envelope.coordinateTransformVersion != 1 && archive.parts.contains { part in
                        guard part.key.hasSuffix(".xml"),let xml = String(data:part.value,encoding:.utf8) else { return false }
                        return xml.range(of:"<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?Cell\\b(?=[^>]*\\bN\\s*=\\s*[\"']Flip[XY][\"'])(?=[^>]*\\bV\\s*=\\s*[\"']1(?:\\.0)?[\"'])[^>]*>",options:.regularExpression) != nil
                    }
                    if needsTransforms { warnings.insert("Older native metadata used different flipped-pin transforms; public Visio coordinates were reimported.") }
                    let needsRichText = envelope.textRunsVersion != 1 && archive.parts.contains { part in
                        guard part.key.hasSuffix(".xml"),let xml = String(data:part.value,encoding:.utf8) else { return false }
                        return xml.range(of:"<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?(?:cp|pp)\\b[^>]*\\bIX\\s*=\\s*[\"'][1-9][0-9]*[\"']",options:.regularExpression) != nil || xml.range(of:"<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?FaceName\\b[^>]*\\bNameU\\s*=",options:.regularExpression) != nil
                    }
                    if needsRichText { warnings.insert("Older native metadata reduced mixed text formatting; public text runs were reimported.") }
                    let needsFields = envelope.textFieldsVersion != 1 && archive.parts.contains { part in
                        guard part.key.hasSuffix(".xml"),let xml = String(data:part.value,encoding:.utf8) else { return false };return xml.range(of:"<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?fld\\b",options:.regularExpression) != nil
                    }
                    if needsFields { warnings.insert("Older native metadata omitted text field references; public fields were reimported.") }
                    let needsGeometry = ![1,2,3,4].contains(envelope.geometryVersion ?? 0) && archive.parts.contains { part in
                        guard part.key.hasSuffix(".xml"),let xml = String(data:part.value,encoding:.utf8) else { return false };return xml.range(of:"<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?Section\\b[^>]*\\bN\\s*=\\s*[\"']Geometry[\"']",options:.regularExpression) != nil
                    }
                    if needsGeometry { warnings.insert("Older native metadata lacked current geometry support; public geometry rows were reimported.") }
                    if matches && publicNames == Set(envelope.publicHashes.keys) && (!hasMasters || envelope.masterExpansionVersion == 1) && !needsPorts && !needsTransforms && !needsRichText && !needsFields && !needsGeometry {
                        var diagram = envelope.diagram
                        if let segments = envelope.legacyParts {
                            guard !segments.isEmpty,segments.count<=8,Set(segments).count == segments.count,diagram.legacySource != nil else { throw DiagramError.invalid("Invalid preserved binary source segments.") }
                            var bytes = Data()
                            for name in segments { let part = try archive.data(name);guard bytes.count<=100*1024*1024-part.count else { throw DiagramError.invalid("Oversized preserved binary source.") };bytes.append(part) }
                            diagram.legacySource?.data = bytes
                        }
                        diagram = try diagram.validated()
                        var bindings: [VisioPageBinding]
                        if envelope.format == 4 {
                            guard envelope.bindings == nil, let compact = envelope.compactBindings,
                                  compact.count == diagram.pages.count,
                                  Set(compact.map(\.pageID)).count == compact.count else {
                                throw DiagramError.invalid("Invalid compact native page bindings.")
                            }
                            let pagesByID = Dictionary(uniqueKeysWithValues: diagram.pages.map { ($0.id, $0) })
                            guard Set(compact.map(\.pageID)) == Set(pagesByID.keys) else {
                                throw DiagramError.invalid("Compact native metadata references missing pages.")
                            }
                            bindings = try compact.map { binding in
                                guard let currentPage = pagesByID[binding.pageID] else {
                                    throw DiagramError.invalid("Compact native metadata references a missing page.")
                                }
                                return VisioPageBinding(pageID: binding.pageID, visioID: binding.visioID,
                                    part: binding.part, original: binding.original ?? currentPage,
                                    nodeIDs: binding.nodeIDs, edgeIDs: binding.edgeIDs,
                                    inheritedShapes: binding.inheritedShapes)
                            }
                        } else {
                            bindings = envelope.bindings ?? diagram.pages.enumerated().map { index, page in
                                VisioPageBinding(pageID:page.id,visioID:String(index),part:"visio/pages/page\(index+1).xml",original:page,
                                    nodeIDs:Dictionary(uniqueKeysWithValues:page.nodes.enumerated().map { ($0.element.id,String($0.offset+1)) }),
                                    edgeIDs:Dictionary(uniqueKeysWithValues:page.edges.enumerated().map { ($0.element.id,String(page.nodes.count+$0.offset+1)) }))
                            }
                        }
                        var cacheWarnings:[String] = []
                        if envelope.connectorDetailsVersion != 1,diagram.pages.contains(where:{!$0.edges.isEmpty}) {
                            cacheWarnings.append("Older native metadata omitted connector sheets and rich text; public connector details were hydrated while retaining native identities.")
                        }
                        if envelope.controlsVersion != 1,archive.parts.contains(where:{$0.key.hasSuffix(".xml") && String(data:$0.value,encoding:.utf8)?.range(of:"<(?:[A-Za-z_][A-Za-z0-9_.-]*:)?Section\\b[^>]*\\bN\\s*=\\s*[\"']Controls?[\"']",options:.regularExpression) != nil}) {
                            try hydrateControls(&diagram,bindings:&bindings,parts:archive.parts)
                            cacheWarnings.append("Older native metadata omitted control handles; public definitions were hydrated while retaining native identities.")
                        }
                        if envelope.geometryVersion != 4 {
                            let refreshed = GeometrySheet.refreshCompositeCaches(diagram)
                            if refreshed.pages != diagram.pages { cacheWarnings.append("Older native composite caches were rebuilt from retained geometry definitions.") };diagram = refreshed
                            for i in bindings.indices { var original = Diagram();original.pages = [bindings[i].original];original.activePageID = original.pages[0].id;bindings[i].original = GeometrySheet.refreshCompositeCaches(original).pages[0] }
                        }
                        let indexPart = envelope.pagesPart ?? "visio/pages/pages.xml"
                        // Older native metadata did not model public background attributes.
                        // Hydrate those missing fields instead of letting it conceal them.
                        if let data = archive.parts[indexPart] {
                            let index = try VisioXML.document(data),entries = index.rootElement()?.elementsLocal("Page") ?? []
                            var ids:[UInt32:UUID] = [:]
                            for binding in bindings { guard let id = UInt32(binding.visioID),ids[id] == nil else { throw DiagramError.invalid("Invalid native Visio page bindings.") };ids[id] = binding.pageID }
                            for i in diagram.pages.indices where diagram.pages[i].isBackground == nil {
                                if let binding = bindings.first(where:{$0.pageID == diagram.pages[i].id}),let entry = entries.first(where:{UInt32($0.attr("ID") ?? "") == UInt32(binding.visioID)}),let flag = entry.attr("Background") { diagram.pages[i].isBackground = flag == "1" || flag == "true" }
                            }
                            for i in diagram.pages.indices where diagram.pages[i].backgroundPageID == nil {
                                if let binding = bindings.first(where:{$0.pageID == diagram.pages[i].id}),let entry = entries.first(where:{UInt32($0.attr("ID") ?? "") == UInt32(binding.visioID)}),let id = entry.attr("BackPage").flatMap(UInt32.init),let target = ids[id],diagram.pages.contains(where:{$0.id == target && $0.isBackground == true}) { diagram.pages[i].backgroundPageID = target }
                            }
                            // Older native envelopes predate PageSheet retention. Rehydrate
                            // supported cells from the hashed public page index on load.
                            for i in diagram.pages.indices where diagram.pages[i].sheet == nil {
                                guard let bindingIndex = bindings.firstIndex(where:{$0.pageID == diagram.pages[i].id}),
                                      let entry = entries.first(where:{$0.attr("ID") == bindings[bindingIndex].visioID}) else { continue }
                                let cells = pageSheetCells(entry.firstLocal("PageSheet"))
                                diagram.pages[i].sheet = cells
                                bindings[bindingIndex].original.sheet = cells
                            }
                            for i in bindings.indices { if let page = diagram.pages.first(where:{$0.id == bindings[i].pageID}) {
                                if bindings[i].original.isBackground == nil { bindings[i].original.isBackground = page.isBackground }
                                if bindings[i].original.backgroundPageID == nil { bindings[i].original.backgroundPageID = page.backgroundPageID }
                            } }
                        }
                        if officeTheme != nil {
                            for index in diagram.pages.indices {
                                let rawColorVariation = diagram.pages[index].sheet?["VariationColorIndex"].flatMap { Int($0.value) }
                                let rawStyleVariation = diagram.pages[index].sheet?["VariationStyleIndex"].flatMap { Int($0.value) }
                                diagram.pages[index].theme = pageTheme(officeTheme,variationColorIndex:rawColorVariation,variationStyleIndex:rawStyleVariation)
                            }
                            for index in bindings.indices {
                                bindings[index].original.theme = diagram.pages.first(where:{$0.id == bindings[index].pageID})?.theme
                            }
                        }
                        diagram.visioArchive = VisioDocumentArchive(parts:archive.parts,pagesPart:indexPart,pages:bindings,connectorHierarchyVersion:envelope.connectorHierarchyVersion,theme:officeTheme)
                        let result = VisioImportResult(diagram:try diagram.validated(),warnings:cacheWarnings,diagnostics:ImportedSourceDiagnostics.scan(diagram))
                        trace?("nativeMetadata")
                        return result
                    }
                }
                warnings.insert("The drawing changed outside MacVisio; its public Visio content was imported.")
            } catch {
                warnings.insert("MacVisio metadata could not be used; the public Visio content was imported.")
            }
        }

        guard let pagesRelationship = documentRelationships.values.first(where: { $0.type == visioRelationship + "pages" }), !pagesRelationship.external else {
            throw DiagramError.invalid("The Visio drawing has no pages relationship.")
        }
        let pagesPart = try resolve(pagesRelationship.target, relativeTo: documentPart)
        let pagesRoot = try archive.xml(pagesPart, expectedRoot: "Pages")
        let pageRelationships = try relationships(in: archive, source: pagesPart)
        let pageElements = pagesRoot.children(named: "Page")
        _ = try uniqueElements(pageElements,key:"ID")
        var pageIDs:[UInt32:UUID] = [:]
        for element in pageElements {
            let id = UInt32(element.attributes["ID"]!)!
            guard pageIDs[id] == nil else { throw DiagramError.invalid("Duplicate Visio page identifiers.") };pageIDs[id] = UUID()
        }
        guard !pageElements.isEmpty, pageElements.count <= 1000 else { throw DiagramError.invalid("The Visio drawing has an invalid page count.") }

        var palette: [String: String] = ["0": "#000000", "1": "#FFFFFF", "2": "#FF0000", "3": "#00FF00", "4": "#0000FF", "5": "#FFFF00", "6": "#FF00FF", "7": "#00FFFF"]
        for entry in document.child("Colors")?.children(named: "ColorEntry") ?? [] {
            if let index = entry.attributes["IX"], let value = entry.attributes["RGB"] { palette[index] = value }
        }
        let styles = Dictionary(uniqueKeysWithValues: try uniqueElements(document.child("StyleSheets")?.children(named: "StyleSheet") ?? [], key: "ID"))
        let resolvedStyles = ResolvedStyleCells(styles:styles)
        var masters: [String: MasterDefinition] = [:]
        if let relation = documentRelationships.values.first(where: { $0.type == visioRelationship + "masters" }), !relation.external {
            let part = try resolve(relation.target, relativeTo: documentPart)
            let masterRoot = try archive.xml(part, expectedRoot: "Masters")
            let masterRelations = try relationships(in: archive, source: part)
            _ = try uniqueElements(masterRoot.children(named:"Master"),key:"ID")
            for master in masterRoot.children(named: "Master") {
                guard let id = master.attributes["ID"], let relationID = master.child("Rel")?.attribute(local: "id"),
                      let masterRelation = masterRelations[relationID], !masterRelation.external else { continue }
                let contents = try archive.xml(resolve(masterRelation.target, relativeTo: part), expectedRoot: "MasterContents")
                let roots = contents.child("Shapes")?.children(named:"Shape") ?? []
                if !roots.isEmpty {
                    var ids = Set<UInt32>()
                    var shapeIndex:[UInt32:XElement] = [:]
                    func check(_ shapes:[XElement],_ depth:Int = 0) throws {
                        guard depth < 64 else { throw DiagramError.invalid("A master is nested too deeply.") }
                        for shape in shapes {
                            guard let id = shape.attributes["ID"].flatMap(UInt32.init),ids.insert(id).inserted,ids.count <= 150000 else { throw DiagramError.invalid("Invalid or duplicate master shape identifiers.") }
                            shapeIndex[id] = shape
                            try check(shape.child("Shapes")?.children(named:"Shape") ?? [],depth+1)
                        }
                    }
                    try check(roots)
                    let shape:XElement
                    if roots.count == 1 { shape = roots[0] }
                    else {
                        // A multi-root master is inherited as a group of those roots.
                        shape = XElement(name:"Shape",attributes:["Type":"Group"])
                        for (key,value) in [("Width",contents.child("PageSheet")?.cells["PageWidth"]?.value ?? "1"),("Height",contents.child("PageSheet")?.cells["PageHeight"]?.value ?? "1")] { shape.elements.append(XElement(name:"Cell",attributes:["N":key,"V":value])) }
                        let children = XElement(name:"Shapes",attributes:[:]);children.elements = roots;shape.elements.append(children)
                    }
                    masters[id] = MasterDefinition(name: master.attributes["NameU"] ?? master.attributes["Name"] ?? "", shape: shape, part: try resolve(masterRelation.target, relativeTo: part),shapeIndex:shapeIndex,connections:contents.child("Connects")?.children(named:"Connect") ?? [])
                }
            }
        }

        trace?("masters")
        if archive.names.contains(where: { $0.hasPrefix("visio/theme/") || $0.hasPrefix("visio/themes/") }) { warnings.insert("Theme effects and unsupported theme colors are approximated from cached ShapeSheet values.") }
        if documentRelationships.values.contains(where: { $0.external }) { warnings.insert("External relationships are ignored.") }

        var diagram = Diagram()
        diagram.title = title
        diagram.pages = []
        var bindings: [VisioPageBinding] = []
        for (pageIndex, pageElement) in pageElements.enumerated() {
            try LifecycleJobContext.current?.checkpoint()
            LifecycleJobContext.current?.progress("Reading page \(pageIndex + 1) of \(pageElements.count)",fraction:Double(pageIndex) / Double(pageElements.count))
            guard let relationshipID = pageElement.child("Rel")?.attribute(local: "id"),
                  let relation = pageRelationships[relationshipID], relation.type == visioRelationship + "page", !relation.external else {
                throw DiagramError.invalid("A Visio page has a missing or external content relationship.")
            }
            let pagePart = try resolve(relation.target, relativeTo: pagesPart)
            let contents = try archive.xml(pagePart, expectedRoot: "PageContents")
            let pageCells = pageElement.child("PageSheet")?.cells ?? [:]
            var page = DiagramPage()
            page.id = pageIDs[UInt32(pageElement.attributes["ID"]!)!]!
            let diagnosticPageID = page.id
            let pageDiagnosticStart = importDiagnostics.count
            func appendPageDiagnostic(_ code: String, _ message: String, shapeID: String? = nil,
                                      cell: String? = nil, feature: String? = nil,
                                      dimension: DocumentDiagnostic.Dimension = .rendering, part: String? = nil) {
                importDiagnostics.append(DocumentDiagnostic(code: code, origin: .importer, severity: .warning,
                    dimension: dimension, target: .page(diagnosticPageID),
                    source: .init(part: part ?? pagePart, visioID: shapeID, cell: cell, feature: feature),
                    displayState: .cached, message: message, requestedActions: [.revealTarget, .viewDetails]))
            }
            func pageWarning(_ code: String, _ message: String, shapeID: String? = nil,
                             cell: String? = nil, feature: String? = nil,
                             dimension: DocumentDiagnostic.Dimension = .rendering, part: String? = nil) {
                warnings.insert(message)
                appendPageDiagnostic(code, message, shapeID: shapeID, cell: cell, feature: feature, dimension: dimension, part: part)
            }
            page.name = pageElement.attributes["Name"] ?? pageElement.attributes["NameU"] ?? "Page \(pageIndex + 1)"
            page.sheet = pageSheetCells(pageElement.child("PageSheet"))
            page.theme = pageTheme(officeTheme,
                variationColorIndex:page.sheet?["VariationColorIndex"].flatMap { Int($0.value) },
                variationStyleIndex:page.sheet?["VariationStyleIndex"].flatMap { Int($0.value) })
            page.drawingScale = try DrawingScale.read(pageCells.mapValues{ShapeSheetCell(value:$0.value,formula:$0.formula,unit:$0.unit)})
            page.width = try dimension(pageCells, "PageWidth", default: 11.0,factor:page.paperScale) * 72
            page.height = try dimension(pageCells, "PageHeight", default: 8.5,factor:page.paperScale) * 72
            if let flag = pageElement.attributes["Background"] { page.isBackground = flag == "1" || flag == "true" }
            if let raw = pageElement.attributes["BackPage"] {
                if let id = UInt32(raw),let target = pageIDs[id],let element = pageElements.first(where:{UInt32($0.attributes["ID"] ?? "") == id}),["1","true"].contains(element.attributes["Background"] ?? "") { page.backgroundPageID = target }
                else { pageWarning("import.background-reference", "An invalid background-page reference retains its source XML but cannot be composed.", feature: "BackPage", part: pagesPart) }
            }
            let shapes = contents.child("Shapes")?.children(named: "Shape") ?? []
            guard shapes.count <= 150000 else { throw DiagramError.invalid("The page has too many shapes.") }
            _ = try uniqueElements(shapes.filter{!["1","true"].contains($0.attributes["Del"] ?? "")}, key: "ID")
            var identifiers: [String: UUID] = [:]
            var seenShapeIDs = Set<UInt32>()
            var reservedShapeIDs = Set<UInt32>()
            func reserve(_ shapes:[XElement],_ depth:Int = 0) throws {
                guard depth < 64 else { throw DiagramError.invalid("Shape groups are nested too deeply.") }
                for shape in shapes {
                    if ["1","true"].contains(shape.attributes["Del"] ?? "") { if let id = shape.attributes["ID"].flatMap(UInt32.init) { reservedShapeIDs.insert(id) };continue }
                    guard let id = shape.attributes["ID"].flatMap(UInt32.init),reservedShapeIDs.insert(id).inserted,reservedShapeIDs.count <= 150000 else { throw DiagramError.invalid("Duplicate or invalid Visio shape identifiers.") }
                    try reserve(shape.child("Shapes")?.children(named:"Shape") ?? [],depth+1)
                }
            }
            try reserve(shapes)
            var nextVirtualID = (reservedShapeIDs.max().map(UInt64.init) ?? 0)+1
            func virtualID() throws -> String {
                guard reservedShapeIDs.count < 150000 else { throw DiagramError.invalid("Master expansion exceeds the page shape limit.") }
                if nextVirtualID > UInt32.max { nextVirtualID = 0 }
                while reservedShapeIDs.contains(UInt32(nextVirtualID)) { nextVirtualID += 1;if nextVirtualID > UInt32.max { nextVirtualID = 0 } }
                let id = String(nextVirtualID);reservedShapeIDs.insert(UInt32(nextVirtualID));nextVirtualID += 1;return id
            }
            var inheritedShapes:[UUID:VisioInheritedShape] = [:]
            var inheritanceByShape:[String:VisioInheritedShape] = [:]
            var instanceContexts:[MasterInstance] = []
            var connectorElements: [(XElement, [String: XCell], XElement?, DiagramNode?, MasterInstance?)] = []
            var edgeIdentifiers: [UUID:String] = [:]
            let pageRelations = try relationships(in:archive,source:pagePart)
            let layerRows = pageElement.child("PageSheet")?.children(named:"Section").first(where:{$0.attributes["N"] == "Layer"})?.children(named:"Row") ?? []
            var layerNames:[String:String] = [:]
            var usedLayerNames = Set<String>()
            for row in layerRows {
                guard let id = row.attributes["IX"],let rawName = row.cells["Name"]?.value else { continue }
                let base = rawName.isEmpty ? "Unnamed layer \(id)" : rawName
                var name = base,suffix = 2
                while usedLayerNames.contains(name) { name = "\(base) (\(suffix))";suffix += 1 }
                usedLayerNames.insert(name)
                guard layerNames[id] == nil else { throw DiagramError.invalid("Duplicate Visio layer identifiers.") };layerNames[id] = name
            }
            if !layerRows.isEmpty { page.layers = layerRows.compactMap { row in
                guard let id = row.attributes["IX"],let name = layerNames[id] else { return nil }
                let cells = row.children(named:"Cell").reduce(into:[String:ShapeSheetCell]()) { result,cell in
                    guard let name = cell.attributes["N"] else { return }
                    result[name] = ShapeSheetCell(value:cell.attributes["V"] ?? "",formula:cell.attributes["F"] ?? "",unit:cell.attributes["U"] ?? "")
                }
                let rawColor = row.cells["Color"],numericColor = number(rawColor)
                let parsedColor = numericColor == 255 ? "" : color(rawColor,palette:palette,fallback:"")
                let layerColor:String? = parsedColor.isEmpty ? nil : parsedColor
                let rawTransparency = number(row.cells["ColorTrans"]) ?? 0
                // VSDX stores the percentage as a 0...1 ratio; accept legacy 0...100 values too.
                let transparency = max(0,min(100,rawTransparency <= 1 ? rawTransparency*100 : rawTransparency))
                return DiagramLayer(name:name,visible:number(row.cells["Visible"]) != 0,locked:number(row.cells["Lock"]) == 1,printable:number(row.cells["Print"]) != 0,snap:number(row.cells["Snap"]) != 0,glue:number(row.cells["Glue"]) != 0,color:layerColor,colorTransparency:transparency,sheet:cells,sourceColor:layerColor,sourceColorTransparency:transparency)
            } }
            func visit(_ shapes:[XElement],parent:DiagramNode? = nil,inheritedMaster:MasterDefinition? = nil,context:MasterInstance? = nil,depth:Int = 0) throws {
              guard depth < 64 else { throw DiagramError.invalid("Shape groups are nested too deeply.") }
              for shape in shapes {
                if ["1","true"].contains(shape.attributes["Del"] ?? "") { continue }
                guard let shapeID = shape.attributes["ID"] else { throw DiagramError.invalid("A Visio shape has no identifier.") }
                guard let numericID = UInt32(shapeID),seenShapeIDs.insert(numericID).inserted else { throw DiagramError.invalid("Duplicate or invalid Visio shape identifiers.") }
                var master = shape.attributes["Master"].flatMap { masters[$0] }
                var instance = context
                if let definition = master {
                    instance = MasterInstance();instance!.connections = definition.connections;instanceContexts.append(instance!)
                    if let rootID = definition.shape.attributes["ID"] { instance?.identifiers[rootID] = shapeID }
                }
                if let masterShape = shape.attributes["MasterShape"],let definition = master {
                    if let matched = definition.find(masterShape) { master = definition.withShape(matched) }
                }
                if master == nil,let masterShape = shape.attributes["MasterShape"],let definition = inheritedMaster {
                    if let matched = definition.find(masterShape) { master = definition.withShape(matched) }
                    else { pageWarning("import.master-reference", "An unresolved MasterShape reference retains its source XML and uses local cached properties.", shapeID: shapeID, feature: "MasterShape", dimension: .behavior) }
                }
                if let masterShape = shape.attributes["MasterShape"],master != nil,let parent {
                    instance?.identifiers[masterShape] = shapeID
                    if inheritanceByShape[shapeID] == nil { inheritanceByShape[shapeID] = VisioInheritedShape(masterShapeID:masterShape,parentID:parent.id,implicit:false) }
                }
                if shape.children(named: "Section").contains(where: { $0.attributes["N"] == "Actions" }) {
                    pageWarning("import.ignored-shape-action", "Imported shape actions are preserved but not executed.", shapeID: shapeID, feature: "Actions", dimension: .behavior)
                }
                let cells = inheritedCells(shape, master: master?.shape, styles: resolvedStyles)
                let hasEndpoints = cells["BeginX"] != nil && cells["EndX"] != nil
                if number(cells["OneD"]) == 1 || hasEndpoints {
                    connectorElements.append((shape, cells, master?.shape, parent, instance)); continue
                }
                var kind = recognize(shape, master: master, warnings: &warnings)
                if shape.attributes["Type"] == "Foreign" || shape.child("ForeignData") != nil {
                    kind = .rectangle
                }
                let signedWidth = try dimension(cells, "Width", default: 2,allowZero:true,factor:page.paperScale,allowSigned:true) * 72
                let signedHeight = try dimension(cells, "Height", default: 1,allowZero:true,factor:page.paperScale,allowSigned:true) * 72
                let width = abs(signedWidth),height = abs(signedHeight),origin = CGPoint(x:min(0,signedWidth),y:min(0,signedHeight))
                if number(cells["Width"]) == 0 || number(cells["Height"]) == 0 { pageWarning("import.zero-axis", "Zero-size shape axes use a minimal editing frame; original public dimensions remain preserved in the source package.", shapeID: shapeID, cell: number(cells["Width"]) == 0 ? "Width" : "Height") }
                let pinX = try finiteNumber(cells, "PinX", default: signedWidth / 144) * 72
                let pinY = try finiteNumber(cells, "PinY", default: signedHeight / 144) * 72
                let locPinX = try finiteNumber(cells, "LocPinX", default: signedWidth / 144) * 72
                let locPinY = try finiteNumber(cells, "LocPinY", default: signedHeight / 144) * 72
                let angle = try finiteNumber(cells, "Angle", default: 0)
                let dx = (signedWidth/2-locPinX)*(number(cells["FlipX"]) == 1 ? -1 : 1),dy = (signedHeight/2-locPinY)*(number(cells["FlipY"]) == 1 ? -1 : 1)
                let centerX = pinX + dx*cos(angle)-dy*sin(angle),centerY = pinY+dx*sin(angle)+dy*cos(angle)
                let parentOrigin = parent?.sheetOrigin ?? .zero
                var node = DiagramNode(kind: kind, x: centerX-parentOrigin.x - width / 2, y: (parent?.height ?? page.height) - (centerY-parentOrigin.y) - height / 2, text: shape.child("Text")?.shapeText ?? master?.shape.child("Text")?.shapeText ?? "")
                node.width = width; node.height = height; node.rotation = -angle * 180 / .pi
                node.fill = color(cells["FillForegnd"], palette: palette, fallback: "#FFFFFF")
                node.stroke = color(cells["LineColor"], palette: palette, fallback: "#000000")
                node.fill = withTransparency(node.fill, value: number(cells["FillForegndTrans"]))
                node.stroke = withTransparency(node.stroke, value: number(cells["LineColorTrans"]))
                if number(cells["FillPattern"]) == 0 { node.fill = "#FFFFFF00" }
                if number(cells["LinePattern"]) == 0 { node.stroke = "#FFFFFF00" }
                node.strokeWidth = try finiteNumber(cells, "LineWeight", default: 1 / 72) * 72
                let characterCells = inheritedSectionCells(shape, master: master?.shape, styles: styles, section: "Character", styleKey: "TextStyle")
                node.fontSize = try finiteNumber(characterCells, "Size", default: 12 / 72) * 72
                node.textColor = color(characterCells["Color"], palette: palette, fallback: "#000000")
                let textStyle = number(characterCells["Style"]) ?? 0
                node.bold = textStyle >= 0 && textStyle < 65536 && Int(textStyle) & 1 == 1
                node.locked = number(cells["LockMoveX"]) == 1 && number(cells["LockMoveY"]) == 1
                if (number(cells["FillPattern"]) ?? 1) > 1 {
                    pageWarning("import.fill-pattern", "Gradients and fill patterns are approximated by solid colors.", shapeID: shapeID, cell: "FillPattern")
                }
                if node.fontSize < 1 || node.fontSize > 500 { node.fontSize = min(500, max(1, node.fontSize)); pageWarning("import.font-size", "Text sizes outside the supported range were clamped.", shapeID: shapeID, cell: "Char.Size") }
                var detail = ShapeDetails()
                detail.sourceShapeID = shapeID
                detail.sheet = cells.mapValues { ShapeSheetCell(value:$0.value,formula:$0.formula,unit:$0.unit) }
                if let size = characterCells["Size"] { detail.sheet["Char.Size"] = ShapeSheetCell(value:size.value,formula:size.formula,unit:size.unit) }
                for sectionName in ["User","Property"] {
                    for row in inheritedRows(shape,master:master?.shape,section:sectionName) {
                        if let name = row.attributes["N"],let cell = row.cells["Value"] { detail.sheet[(sectionName == "Property" ? "Prop." : "User.")+name] = ShapeSheetCell(value:cell.value,formula:cell.formula,unit:cell.unit) }
                    }
                }
                detail.isGroup = shape.attributes["Type"] == "Group" || shape.child("Shapes") != nil || master?.shape.attributes["Type"] == "Group" || master?.shape.child("Shapes") != nil
                detail.flipX = number(cells["FlipX"]) == 1; detail.flipY = number(cells["FlipY"]) == 1
                if signedWidth < 0 { detail.negativeWidth = true };if signedHeight < 0 { detail.negativeHeight = true }
                let styleBits = Int(exactly:textStyle) ?? 0
                detail.italic = styleBits & 2 != 0; detail.underline = styleBits & 4 != 0
                detail.linePattern = number(cells["LinePattern"]).flatMap{Int(exactly:$0)} ?? 1
                let fontValue = characterCells["Font"]?.value ?? "0"
                detail.fontName = fontName(fontValue,in:document)
                let paragraphs = inheritedSectionCells(shape,master:master?.shape,styles:styles,section:"Paragraph",styleKey:"TextStyle")
                detail.alignment = number(paragraphs["HorzAlign"]) == 0 ? .left : number(paragraphs["HorzAlign"]) == 2 ? .right : .center
                if cells["TxtWidth"] != nil || cells["TxtHeight"] != nil {
                    let tw = (number(cells["TxtWidth"]) ?? width/72)*72,th = (number(cells["TxtHeight"]) ?? height/72)*72
                    let tx = (number(cells["TxtPinX"]) ?? width/144)*72,ty = (number(cells["TxtPinY"]) ?? height/144)*72
                    let lx = (number(cells["TxtLocPinX"]) ?? tw/144)*72,ly = (number(cells["TxtLocPinY"]) ?? th/144)*72,a = number(cells["TxtAngle"]) ?? 0
                    if tw > 0,th > 0 { detail.textBox = ShapeTextBox(centerX:(tx+(tw/2-lx)*cos(a)-(th/2-ly)*sin(a)-origin.x)/width,centerY:(height-ty-(tw/2-lx)*sin(a)-(th/2-ly)*cos(a)+origin.y)/height,width:tw/width,height:th/height,rotation:-a*180 / .pi,left:(number(cells["LeftMargin"]) ?? 0)*72,right:(number(cells["RightMargin"]) ?? 0)*72,top:(number(cells["TopMargin"]) ?? 0)*72,bottom:(number(cells["BottomMargin"]) ?? 0)*72,verticalAlignment:number(cells["VerticalAlign"]).flatMap{Int(exactly:$0)} ?? 1) }
                }
                let membership = cells["LayerMember"]?.value ?? ""
                detail.layerNames = membership.split(separator:";").compactMap { layerNames[String($0)] }
                if let name = detail.layerNames.first { node.layer = name }
                detail.data = inheritedRows(shape,master:master?.shape,section:"Property").enumerated().map { i,row in
                    let c = row.cells; return ShapeDataProperty(key:row.attributes["N"] ?? "Row_\(i)",label:c["Label"]?.value ?? row.attributes["N"] ?? "Property",value:c["Value"]?.value ?? "",type:number(c["Type"]).flatMap{Int(exactly:$0)} ?? 0,format:c["Format"]?.value ?? "",prompt:c["Prompt"]?.value ?? "",valueUnit:ShapeDataProperty.importedValueUnit(c["Value"]?.unit,type:number(c["Type"]).flatMap{Int(exactly:$0)} ?? 0,value:c["Value"]?.value ?? ""))
                }
                detail.hyperlinks = inheritedRows(shape,master:master?.shape,section:"Hyperlink").map { row in let c = row.cells; return ShapeHyperlink(address:c["Address"]?.value ?? "",subAddress:c["SubAddress"]?.value ?? "",description:c["Description"]?.value ?? "",sourceRowName:row.attributes["N"]) }
                for (index,row) in inheritedRows(shape,master:master?.shape,section:"Connection").enumerated() {
                    let c = row.cells
                    guard let x = c["X"],let y = c["Y"],number(x) != nil,number(y) != nil,let ix = UInt32(row.attributes["IX"] ?? row.attributes["MacVisio.RowIndex"] ?? String(index)) else { pageWarning("import.connection-point", "An unsupported connection point retains its source XML but cannot be edited.", shapeID: shapeID, feature: "Connection."+(row.attributes["IX"] ?? row.attributes["N"] ?? String(index)), dimension: .editing);continue }
                    detail.connectionPoints.append(ShapeConnectionPoint(index:ix,name:row.attributes["N"],x:ShapeSheetCell(value:x.value,formula:x.formula),y:ShapeSheetCell(value:y.value,formula:y.formula),directionX:number(c["DirX"]) ?? number(c["A"]) ?? 0,directionY:number(c["DirY"]) ?? number(c["B"]) ?? 0,type:number(c["Type"]).flatMap{Int(exactly:$0)} ?? 0))
                }
                let geometryRows = try geometryDefinitions(shape,master:master?.shape)
                for (index,row) in inheritedRows(shape,master:master?.shape,section:"Control").enumerated() {
                    let rowIndex = row.attributes["IX"].flatMap(Int.init) ?? row.attributes["MacVisio.RowIndex"].flatMap(Int.init) ?? index
                    detail.controls.append(ShapeControl(name:row.attributes["N"] ?? "Row_\(rowIndex+1)",index:rowIndex,cells:row.cells.mapValues{ShapeSheetCell(value:$0.value,formula:$0.formula,unit:$0.unit)},sourceIndex:row.attributes["N"] == nil ? row.attributes["IX"].flatMap(Int.init) : nil))
                }
                if !geometryRows.isEmpty || shape.children(named:"Section").contains(where:{$0.attributes["N"] == "Geometry"}) || master?.shape.children(named:"Section").contains(where:{$0.attributes["N"] == "Geometry"}) == true { detail.geometry = geometryRows }
                detail.paths = geometry(shape,master:master?.shape,width:signedWidth/72,height:signedHeight/72,warnings:&warnings,onIssue: { issue in
                    appendPageDiagnostic("import.geometry-row", issue.error, shapeID: shapeID,
                        feature: "Geometry.\(issue.section).Row.\(issue.row).\(issue.type)")
                })
                if let foreign = shape.child("ForeignData") ?? master?.shape.child("ForeignData"),let relID = foreign.child("Rel")?.attribute(local:"id") {
                    let relations = shape.child("ForeignData") != nil ? pageRelations : try master.map{try relationships(in:archive,source:$0.part)} ?? [:]
                    if let relation = relations[relID],!relation.external {
                        let part = try resolve(relation.target,relativeTo:shape.child("ForeignData") != nil ? pagePart : master!.part)
                        let ext = (part as NSString).pathExtension.lowercased()
                        let mime = ["png":"image/png","jpg":"image/jpeg","jpeg":"image/jpeg","gif":"image/gif","bmp":"image/bmp","tif":"image/tiff","tiff":"image/tiff","svg":"image/svg+xml","pdf":"application/pdf"][ext]
                        if let mime = mime { detail.image = EmbeddedImage(data:try archive.data(part),mimeType:mime); node.text = shape.child("Text")?.shapeText ?? ""; node.fill = "#FFFFFF00"; node.stroke = "#FFFFFF00" }
                        else { pageWarning("import.foreign-object", "An embedded OLE/WMF/EMF object is preserved in the file but cannot be rendered natively.", shapeID: shapeID, feature: "ForeignData") }
                    }
                }
                if shape.attributes["Type"] == "Foreign", detail.image == nil,node.text.isEmpty { node.text = "Embedded object" }
                if let parent = parent {
                    var dx = node.center.x-parent.width/2,dy = node.center.y-parent.height/2
                    if parent.formatting.flipX { dx = -dx }; if parent.formatting.flipY { dy = -dy }
                    let a = parent.rotation * .pi/180
                    node.x = parent.center.x+dx*cos(a)-dy*sin(a)-node.width/2
                    node.y = parent.center.y+dx*sin(a)+dy*cos(a)-node.height/2
                    node.rotation = parent.rotation + ((parent.formatting.flipX != parent.formatting.flipY) ? -node.rotation : node.rotation)
                    detail.flipX = detail.flipX != parent.formatting.flipX;detail.flipY = detail.flipY != parent.formatting.flipY
                    node.parentID = parent.id
                }
                node.details = detail
                let textElement = shape.child("Text") ?? master?.shape.child("Text")
                let fieldRows = inheritedRows(shape,master:master?.shape,section:"Field")
                if !fieldRows.isEmpty || textElement?.children(named:"fld").isEmpty == false {
                    var fields:[ShapeTextField] = []
                    for row in fieldRows {
                        guard let index = Int(row.attributes["IX"] ?? row.attributes["MacVisio.RowIndex"] ?? ""),index >= 0,index <= UInt32.max,!fields.contains(where:{$0.index == index}) else { throw DiagramError.invalid("Invalid field row index.") }
                        fields.append(ShapeTextField(index:index,cells:row.cells.mapValues{ShapeSheetCell(value:$0.value,formula:$0.formula,unit:$0.unit)},cached:textElement?.runs.first{$0.field == index}?.text))
                    }
                    for run in textElement?.runs ?? [] { if let index = run.field,!fields.contains(where:{$0.index == index}) { fields.append(ShapeTextField(index:index,cells:[:],cached:run.text));pageWarning("import.text-field", "An unresolved text field retains its cached display.", shapeID: shapeID, feature: "Field."+String(index), dimension: .behavior) } }
                    node.formatting.textFields = fields
                }
                if let text = textElement,!node.text.isEmpty || node.formatting.textFields?.isEmpty == false {
                    node.formatting.textRuns = ShapeRichText.droppingTerminalMark(try richText(text,shape:shape,master:master?.shape,document:document,styles:styles,palette:palette,node:node,warnings:&warnings))
                    if let first = node.formatting.textRuns?.first {
                        node.fontSize = first.character.size;node.textColor = first.character.color;node.bold = first.character.bold
                        node.formatting.fontName = first.character.fontName;node.formatting.italic = first.character.italic;node.formatting.underline = first.character.underline;node.formatting.alignment = first.paragraph.alignment
                    }
                }
                identifiers[shapeID] = node.id
                if let inheritance = inheritanceByShape[shapeID] { inheritedShapes[node.id] = inheritance }
                page.nodes.append(node)
                let localChildren = shape.child("Shapes")?.children(named:"Shape") ?? []
                var children:[XElement] = [],matched = Set<String>()
                for prototype in master?.shape.child("Shapes")?.children(named:"Shape") ?? [] {
                    guard let prototypeID = prototype.attributes["ID"] else { continue }
                    let overrides = localChildren.filter{UInt32($0.attributes["MasterShape"] ?? "") == UInt32(prototypeID)}
                    guard overrides.count <= 1 else { throw DiagramError.invalid("Duplicate master subshape overrides.") }
                    if let override = overrides.first {
                        children.append(override);matched.insert(override.attributes["ID"]!)
                        instance?.identifiers[prototypeID] = override.attributes["ID"]!
                    } else if !["1","true"].contains(prototype.attributes["Del"] ?? "") {
                        let id = try virtualID()
                        let inherited = XElement(name:"Shape",attributes:["ID":id,"MasterShape":prototypeID])
                        children.append(inherited);instance?.identifiers[prototypeID] = id
                        inheritanceByShape[id] = VisioInheritedShape(masterShapeID:prototypeID,parentID:node.id,implicit:true)
                    }
                }
                children.append(contentsOf:localChildren.filter{!matched.contains($0.attributes["ID"] ?? "")})
                if !children.isEmpty { try visit(children,parent:node,inheritedMaster:master ?? inheritedMaster,context:instance,depth:depth+1) }
                if let instance,let master { instance.nodes[node.id] = (shape,master.shape) }
              }
            }
            try visit(shapes)
            let connections = contents.child("Connects")?.children(named: "Connect") ?? []
            var ends: [String: (source: String?, target: String?)] = [:]
            var glue:[String:(source:XElement?,target:XElement?)] = [:]
            for connection in connections {
                guard let from = connection.attributes["FromSheet"], let to = connection.attributes["ToSheet"] else { continue }
                var pair = ends[from] ?? (nil, nil)
                if connection.attributes["FromCell"]?.hasPrefix("Begin") == true { pair.source = to }
                if connection.attributes["FromCell"]?.hasPrefix("End") == true { pair.target = to }
                ends[from] = pair
                var pairGlue = glue[from] ?? (nil,nil)
                if connection.attributes["FromCell"]?.hasPrefix("Begin") == true { pairGlue.source = connection }
                if connection.attributes["FromCell"]?.hasPrefix("End") == true { pairGlue.target = connection }
                glue[from] = pairGlue
            }
            let nodeIndices = Dictionary(uniqueKeysWithValues:page.nodes.enumerated().map{($0.element.id,$0.offset)})
            for instance in instanceContexts {
                // Master connection IDs are scoped to this instance, never another
                // instance of the same stencil shape on this page.
                for connection in instance.connections {
                    guard let from = connection.attributes["FromSheet"].flatMap({instance.identifiers[$0]}),let to = connection.attributes["ToSheet"].flatMap({instance.identifiers[$0]}) else { continue }
                    var pair = ends[from] ?? (nil,nil)
                    let local = connectorElements.first{$0.0.attributes["ID"] == from}?.0
                    let endpoint = connection.attributes["FromCell"]?.hasPrefix("Begin") == true ? "BeginX" : "EndX"
                    let localCell = local?.cells[endpoint]
                    let inherits = localCell == nil || localCell?.value == "Inh" || localCell?.formula == "Inh"
                    if connection.attributes["FromCell"]?.hasPrefix("Begin") == true,pair.source == nil,inherits { pair.source = to }
                    if connection.attributes["FromCell"]?.hasPrefix("End") == true,pair.target == nil,inherits { pair.target = to }
                    ends[from] = pair
                    var pairGlue = glue[from] ?? (nil,nil)
                    if connection.attributes["FromCell"]?.hasPrefix("Begin") == true,pairGlue.source == nil,inherits { pairGlue.source = connection }
                    if connection.attributes["FromCell"]?.hasPrefix("End") == true,pairGlue.target == nil,inherits { pairGlue.target = connection }
                    glue[from] = pairGlue
                }
                for (id,(local,prototype)) in instance.nodes {
                    guard let i = nodeIndices[id] else { continue }
                    // Mutate one value per shape instead of copying its sheet for each cell.
                    var detail = page.nodes[i].formatting
                    for (name,cell) in detail.sheet where !cell.formula.isEmpty {
                        let own = sheetCell(name,in:local)
                        if (own == nil || own?.value == "Inh"),sheetCell(name,in:prototype)?.formula == cell.formula {
                            let remapped = remapMasterFormula(cell.formula,identifiers:instance.identifiers)
                            if remapped != cell.formula { detail.sheet[name]?.formula = remapped }
                        }
                    }
                    if var fields = detail.textFields {
                        for j in fields.indices { for key in fields[j].cells.keys { let formula = fields[j].cells[key]!.formula;fields[j].cells[key]?.formula = remapMasterFormula(formula,identifiers:instance.identifiers) } };detail.textFields = fields
                    }
                    if var sections = detail.geometry {
                        for s in sections.indices {
                            let own = local.children(named:"Section").first{$0.attributes["N"] == "Geometry" && $0.attributes["IX"] == String(sections[s].index)}
                            for key in sections[s].cells.keys where own?.cells[key] == nil || own?.cells[key]?.value == "Inh" { let formula = sections[s].cells[key]!.formula;sections[s].cells[key]?.formula = remapMasterFormula(formula,identifiers:instance.identifiers) }
                            for r in sections[s].rows.indices {
                                let row = own?.children(named:"Row").first{$0.attributes["IX"] == String(sections[s].rows[r].index)}
                                for key in sections[s].rows[r].cells.keys where row?.cells[key] == nil || row?.cells[key]?.value == "Inh" { let formula = sections[s].rows[r].cells[key]!.formula;sections[s].rows[r].cells[key]?.formula = remapMasterFormula(formula,identifiers:instance.identifiers) }
                            }
                        };detail.geometry = sections
                    }
                    for c in detail.controls.indices {
                        let control = detail.controls[c]
                        let own = local.children(named:"Section").first{["Control","Controls"].contains($0.attributes["N"] ?? "")}?.children(named:"Row").first{$0.attributes["N"] == control.name || ($0.attributes["N"] == nil && $0.attributes["IX"] == String(control.sourceIndex ?? control.index))}
                        for key in detail.controls[c].cells.keys where own?.cells[key] == nil || own?.cells[key]?.value == "Inh" { let formula = detail.controls[c].cells[key]!.formula;detail.controls[c].cells[key]?.formula = remapMasterFormula(formula,identifiers:instance.identifiers) }
                    }
                    page.nodes[i].formatting = detail
                }
            }
            for (shape,cells,master,parent,instance) in connectorElements {
                let shapeID = shape.attributes["ID"] ?? ""
                let endpoint = ends[shapeID] ?? (nil,nil)
                func point(_ x:String,_ y:String) -> DiagramPoint? {
                    guard let x = number(cells[x]) else { return nil }; let y = number(cells[y]) ?? 0
                    var p = CGPoint(x:x*72-(parent?.sheetOrigin.x ?? 0),y:(parent?.height ?? page.height)-y*72+(parent?.sheetOrigin.y ?? 0))
                    if let parent = parent { var dx = p.x-parent.width/2,dy = p.y-parent.height/2;let a = parent.rotation * .pi/180;if parent.formatting.flipX { dx = -dx };if parent.formatting.flipY { dy = -dy };p = CGPoint(x:parent.center.x+dx*cos(a)-dy*sin(a),y:parent.center.y+dx*sin(a)+dy*cos(a)) }
                    return DiagramPoint(p)
                }
                let from = endpoint.source.flatMap{identifiers[$0]},to = endpoint.target.flatMap{identifiers[$0]}
                let begin = point("BeginX","BeginY"),end = point("EndX","EndY")
                guard (from != nil || begin != nil),(to != nil || end != nil) else { pageWarning("import.malformed-connector", "A malformed connector is preserved in the package but cannot be edited.", shapeID: shapeID, feature: "connector", dimension: .editing); continue }
                var edge = DiagramEdge(source:from ?? UUID(),target:to ?? UUID())
                edge.parentID = parent?.id
                edge.sourceShapeID = shapeID
                edge.layer = (cells["LayerMember"]?.value ?? "").split(separator:";").compactMap{layerNames[String($0)]}.first
                edge.sourcePosition = begin; edge.targetPosition = end
                func port(_ connection:XElement?,_ nodeID:UUID?) -> String? {
                    guard let connection,let nodeID,let node = page.nodes.first(where:{$0.id == nodeID}) else { return nil }
                    return ConnectionGeometry.matching(cell:connection.attributes["ToCell"] ?? "",part:connection.attributes["ToPart"],on:node)?.id
                }
                edge.sourcePort = port(glue[shapeID]?.source,from);edge.targetPort = port(glue[shapeID]?.target,to)
                edge.label = shape.child("Text")?.shapeText ?? master?.child("Text")?.shapeText ?? ""
                edge.color = color(cells["LineColor"],palette:palette,fallback:"#000000")
                edge.width = try finiteNumber(cells,"LineWeight",default:1/72)*72
                edge.arrow = (number(cells["EndArrow"]) ?? 0) != 0
                edge.startArrow = (number(cells["BeginArrow"]) ?? 0) != 0
                edge.dash = number(cells["LinePattern"]).flatMap{Int(exactly:$0)} ?? 1
                edge.details = try connectorDetails(shape,cells:cells,master:master,document:document,styles:styles,palette:palette,layerNames:layerNames,edge:edge,warnings:&warnings)
                if let instance,let master {
                    var detail = edge.formatting
                    for (name,cell) in detail.sheet where !cell.formula.isEmpty {
                        let own = sheetCell(name,in:shape)
                        if (own == nil || own?.value == "Inh" || own?.formula == "Inh"),sheetCell(name,in:master)?.formula == cell.formula {
                            detail.sheet[name]?.formula = remapMasterFormula(cell.formula,identifiers:instance.identifiers)
                        }
                    }
                    if var fields = detail.textFields {
                        let localRows = shape.children(named:"Section").first{$0.attributes["N"] == "Field"}?.children(named:"Row") ?? []
                        for f in fields.indices {
                            let local = localRows.first{$0.attributes["IX"] == String(fields[f].index)}
                            for key in fields[f].cells.keys where local?.cells[key] == nil || local?.cells[key]?.value == "Inh" || local?.cells[key]?.formula == "Inh" {
                                let formula = fields[f].cells[key]!.formula
                                fields[f].cells[key]?.formula = remapMasterFormula(formula,identifiers:instance.identifiers)
                            }
                        };detail.textFields = fields
                    }
                    edge.formatting = detail
                }
                let rows = shape.children(named:"Section").filter{$0.attributes["N"] == "Geometry"}.flatMap{$0.children(named:"Row")}
                edge.style = rows.count > 2 || number(cells["ShapeRouteStyle"]) == 1 ? .orthogonal : .straight
                let w = max(0.001,abs(number(cells["Width"]) ?? 1)),h = max(0.001,abs(number(cells["Height"]) ?? 1))
                let cachedPaths = geometry(shape,master:master,width:w,height:h,warnings:&warnings,onIssue: { issue in
                    appendPageDiagnostic("import.geometry-row", issue.error, shapeID: shapeID,
                        feature: "Geometry.\(issue.section).Row.\(issue.row).\(issue.type)")
                })
                if let path = cachedPaths.first,!path.commands.isEmpty {
                    let pinX = number(cells["PinX"]) ?? w/2,pinY = number(cells["PinY"]) ?? h/2,locX = number(cells["LocPinX"]) ?? w/2,locY = number(cells["LocPinY"]) ?? h/2,a = number(cells["Angle"]) ?? 0
                    func world(_ x:Double,_ y:Double) -> DiagramPoint {
                        let dx = (min(0,w)+x*abs(w)-locX)*(number(cells["FlipX"]) == 1 ? -1 : 1),dy = (min(0,h)+(1-y)*abs(h)-locY)*(number(cells["FlipY"]) == 1 ? -1 : 1)
                        var p = CGPoint(x:(pinX+dx*cos(a)-dy*sin(a))*72-(parent?.sheetOrigin.x ?? 0),y:(parent?.height ?? page.height)-(pinY+dx*sin(a)+dy*cos(a))*72+(parent?.sheetOrigin.y ?? 0))
                        if let parent = parent { var x = p.x-parent.width/2,y = p.y-parent.height/2;let b = parent.rotation * .pi/180;if parent.formatting.flipX { x = -x };if parent.formatting.flipY { y = -y };p = CGPoint(x:parent.center.x+x*cos(b)-y*sin(b),y:parent.center.y+x*sin(b)+y*cos(b)) };return DiagramPoint(p)
                    }
                    if parent == nil && OneDimensionalGeometry.needsOwnGeometry(cachedPaths.filter { !$0.commands.isEmpty }) {
                        // Arcs, callouts and other multi-part 1-D shapes draw their own geometry (render only;
                        // the source geometry is what is saved).
                        // They are not routed, so their begin-end frame is all the model moves.
                        var detail = edge.formatting; detail.paths = cachedPaths.filter { !$0.commands.isEmpty }; edge.details = detail; edge.style = .straight
                    } else if path.commands.allSatisfy({["M","L","Z"].contains($0.kind)}) {
                        var points = path.commands.filter{$0.kind != "Z"}.map{world($0.values[0],$0.values[1])}
                        if path.commands.last?.kind == "Z",let first = points.first { points.append(first) }
                        if points.count >= 2 { edge.points = points }
                    } else { pageWarning("import.curved-connector", "Curved connectors retain their source geometry; the native preview uses an approximate route.", shapeID: shapeID, feature: "Geometry") }
                }
                page.edges.append(edge); edgeIdentifiers[edge.id] = shapeID
                if let inheritance = inheritanceByShape[shapeID] { inheritedShapes[edge.id] = inheritance }
            }
            let edgeIDsBySource = Dictionary(edgeIdentifiers.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
            for i in pageDiagnosticStart..<importDiagnostics.count {
                guard let sourceID = importDiagnostics[i].source.visioID else { continue }
                if let id = identifiers[sourceID] { importDiagnostics[i].target = .shape(page: page.id, shape: id) }
                else if let id = edgeIDsBySource[sourceID] { importDiagnostics[i].target = .connector(page: page.id, connector: id) }
                // A rejected object has no native identity; its real source ID
                // remains available in the page-scoped details, never fabricated.
            }
            diagram.pages.append(page)
            bindings.append(VisioPageBinding(pageID:page.id,visioID:pageElement.attributes["ID"] ?? String(pageIndex),part:pagePart,original:page,nodeIDs:Dictionary(uniqueKeysWithValues:identifiers.map { ($0.value,$0.key) }),edgeIDs:edgeIdentifiers,inheritedShapes:inheritedShapes.isEmpty ? nil : inheritedShapes))
            trace?("page\(pageIndex+1)")
        }
        diagram.activePageID = diagram.pages.first(where:{$0.isBackground != true})?.id ?? diagram.pages[0].id
        if document.child("EventList") != nil || archive.names.contains(where: { $0.lowercased().contains("vbaproject") }) {
            let message = "Macros and document events are ignored."; warnings.insert(message)
            importDiagnostics.append(DocumentDiagnostic(code: "import.ignored-actions", origin: .importer, severity: .warning,
                dimension: .behavior, target: .document, source: .init(part: documentPart, feature: "macros-events"),
                displayState: .notApplicable, message: message))
        }
        warnings.insert("Saved ShapeSheet values are used on open. Supported numeric formulas recalculate after edits; other formulas retain their source and cached values. Data links, macros and advanced effects are not executed.")
        importDiagnostics.append(DocumentDiagnostic(code: "import.cached-policy", origin: .importer, severity: .information,
            dimension: .behavior, target: .document, source: .init(part: documentPart, feature: "cached-policy"), displayState: .cached,
            message: "Saved ShapeSheet values are used on open. Supported numeric formulas recalculate after edits; other formulas retain their source and cached values. Data links, macros and advanced effects are not executed."))
        resolveThemedAppearance(&diagram, bindings: &bindings)
        diagram.visioArchive = VisioDocumentArchive(parts:archive.parts,pagesPart:pagesPart,pages:bindings,connectorHierarchyVersion:1,theme:officeTheme)
        let previewDiagnostics = ImagePreviewDiagnostics.records(in: diagram)
        importDiagnostics += previewDiagnostics
        warnings.formUnion(previewDiagnostics.map(\.message))
        let result = VisioImportResult(diagram: try diagram.validated(), warnings: warnings.sorted(), diagnostics: importDiagnostics)
        trace?("validation")
        return result
    }

    static func write(_ diagram: Diagram, to url: URL) throws {
        _ = try writeRebased(diagram,to:url)
    }

    static func writeRebased(_ diagram: Diagram, to url: URL) throws -> VisioDocumentArchive {
        guard url.pathExtension.lowercased() != "vsd" else { throw DiagramError.invalid("This exporter writes VSDX. Use the binary VSD exporter for .vsd files.") }
        var diagram = try diagram.validated()
        if var archive = diagram.visioArchive {
            let part = try VisioReusableFormat.documentPart(archive.parts)
            if let data = archive.parts["[Content_Types].xml"],let entry = try VisioXML.document(data).rootElement()?.elementsLocal("Override").first(where:{$0.attr("PartName") == "/"+part}),entry.attr("ContentType") == "application/vnd.ms-visio.template.main+xml" {
                try VisioReusableFormat.setMainContentType("application/vnd.ms-visio.drawing.main+xml",parts:&archive.parts)
                diagram.visioArchive = archive
            }
            return try VisioPreservation.writeRebased(diagram,to:url)
        }
        var parts: [String: Data] = [:]
        func put(_ path: String, _ value: String) { parts[path] = Data(value.utf8) }
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        let namespace = "xmlns=\"\(visioNamespace)\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" xml:space=\"preserve\""
        put("visio/document.xml", header + """
        <VisioDocument \(namespace)><DocumentSettings><GlueSettings>9</GlueSettings><SnapSettings>65847</SnapSettings></DocumentSettings><Colors><ColorEntry IX="0" RGB="#000000"/><ColorEntry IX="1" RGB="#FFFFFF"/></Colors><FaceNames><FaceName NameU="Arial"/></FaceNames><StyleSheets><StyleSheet ID="0" NameU="No Style" Name="No Style"><Cell N="EnableLineProps" V="1"/><Cell N="EnableFillProps" V="1"/><Cell N="EnableTextProps" V="1"/><Cell N="LineWeight" V="0.0138888888888889"/><Cell N="LineColor" V="#000000"/><Cell N="LinePattern" V="1"/><Cell N="FillForegnd" V="#FFFFFF"/><Cell N="FillPattern" V="1"/><Cell N="VerticalAlign" V="1"/><Section N="Character"><Row IX="0"><Cell N="Font" V="Arial"/><Cell N="Color" V="#000000"/><Cell N="Size" V="0.166666666666667"/><Cell N="Style" V="0"/></Row></Section><Section N="Paragraph"><Row IX="0"><Cell N="HorzAlign" V="1"/></Row></Section></StyleSheet></StyleSheets><DocumentSheet NameU="TheDoc" LineStyle="0" FillStyle="0" TextStyle="0"><Cell N="DocLangID" V="en-US"/></DocumentSheet></VisioDocument>
        """)
        put("_rels/.rels", relationshipXML([
            ("rId1", visioRelationship + "document", "visio/document.xml"),
            ("rId2", "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties", "docProps/core.xml"),
            ("rId3", "urn:macvisio:relationships:diagram", nativePart)
        ]))
        put("visio/_rels/document.xml.rels", relationshipXML([("rId1", visioRelationship + "pages", "pages/pages.xml")]))
        put("docProps/core.xml", header + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>\(xml(diagram.title))</dc:title><dc:creator>MacVisio</dc:creator></cp:coreProperties>")
        var pageIndexXML = ""
        var pageRelations: [(String, String, String)] = []
        var pageContentTypes = ""
        var freshBindings: [VisioPageBinding] = []
        let extraTypes = XMLElement(name:"Types")
        let pageIDs = Dictionary(uniqueKeysWithValues:diagram.pages.enumerated().map{($0.element.id,String($0.offset))})
        for (index, page) in diagram.pages.enumerated() {
            try LifecycleJobContext.current?.checkpoint()
            let file = "page\(index + 1).xml"
            pageRelations.append(("rId\(index + 1)", visioRelationship + "page", file))
            pageContentTypes += "<Override PartName=\"/visio/pages/\(file)\" ContentType=\"application/vnd.ms-visio.page+xml\"/>"
            let sheet = XMLElement(name:"PageSheet"); sheet.setAttr("LineStyle","0"); sheet.setAttr("FillStyle","0"); sheet.setAttr("TextStyle","0")
            VisioXML.set(sheet,"PageWidth",page.width/72); VisioXML.set(sheet,"PageHeight",page.height/72); DrawingScale.write(page,to:sheet)
            VisioPreservation.patchPageSheetCells(page.sheet ?? [:],from:[:],sheet:sheet)
            if !(page.layers ?? []).isEmpty { VisioPreservation.patchLayers(page,sheet:sheet) }
            let backgroundFlag = page.isBackground == true ? " Background=\"1\"" : ""
            let backPage = page.backgroundPageID.flatMap{pageIDs[$0]}.map{" BackPage=\"\($0)\""} ?? ""
            pageIndexXML += "<Page ID=\"\(index)\" NameU=\"\(xml(page.name))\" Name=\"\(xml(page.name))\"\(backgroundFlag)\(backPage)>\(sheet.xmlString)<Rel r:id=\"rId\(index + 1)\"/></Page>"
            var nodeIDs:[UUID:Int] = [:],used = Set<Int>()
            for node in page.nodes { if let raw = node.formatting.sourceShapeID,let numeric = UInt32(raw),used.insert(Int(numeric)).inserted { nodeIDs[node.id] = Int(numeric) } }
            var edgeIDs:[UUID:String] = [:]
            for edge in page.edges { if let raw = edge.sourceShapeID,let numeric = UInt32(raw),used.insert(Int(numeric)).inserted { edgeIDs[edge.id] = String(numeric) } }
            var allocator = try VisioIDAllocator(reserved:used.map(String.init))
            for node in page.nodes where nodeIDs[node.id] == nil { nodeIDs[node.id] = Int(try allocator.allocate())! }
            let shapes = XMLElement(name:"Shapes")
            var elements: [UUID:XMLElement] = [:]
            for node in page.nodes {
                let local = VisioPreservation.localNode(node,in:page)
                let height = node.parentID.flatMap { id in page.nodes.first(where:{$0.id == id})?.height } ?? page.height
                let element = try VisioXML.element(shapeXML(local,id:nodeIDs[node.id]!,pageHeight:height,paperScale:page.paperScale))
                let names = Set(node.formatting.layerNames+[node.layer])
                let memberships = (page.layers ?? []).enumerated().filter { names.contains($0.element.name) }.map{String($0.offset)}
                if !memberships.isEmpty { VisioXML.set(element,"LayerMember",memberships.joined(separator:";")) }
                elements[node.id] = element
            }
            for node in page.nodes {
                let element = elements[node.id]!
                if let parentID = node.parentID,let parent = elements[parentID] { let children = parent.firstLocal("Shapes") ?? XMLElement(name:"Shapes"); if children.parent == nil { parent.addChild(children) }; children.addChild(element) }
                else { shapes.addChild(element) }
            }
            var connectionsXML = ""
            for edge in page.edges {
                let shapeID = try edgeIDs[edge.id] ?? allocator.allocate(),id = Int(shapeID)!;edgeIDs[edge.id] = shapeID
                let fromID = nodeIDs[edge.source], toID = nodeIDs[edge.target]
                let coordinates = DiagramCoordinates.connector(edge,in:page)
                let from = ConnectionGeometry.destination(edge.sourcePort,on:page.nodes.first{$0.id == edge.source}),to = ConnectionGeometry.destination(edge.targetPort,on:page.nodes.first{$0.id == edge.target})
                let element = try VisioXML.element(connectorXML(coordinates.edge,id:id,page:coordinates.page,sourceID:fromID,targetID:toID,sourceCells:(from.x,from.y),targetCells:(to.x,to.y)))
                let names = Set(edge.formatting.layerNames + [edge.layer].compactMap{$0})
                let memberships = (page.layers ?? []).enumerated().filter{names.contains($0.element.name)}.map{String($0.offset)}
                if !memberships.isEmpty { VisioXML.set(element,"LayerMember",memberships.joined(separator:";")) }
                else { element.elementsLocal("Cell").first{$0.attr("N") == "LayerMember"}?.detach() }
                if let parentID = edge.parentID,let parent = elements[parentID] { let children = parent.firstLocal("Shapes") ?? XMLElement(name:"Shapes");if children.parent == nil { parent.addChild(children) };children.addChild(element) }
                else { shapes.addChild(element) }
                if let fromID = fromID { connectionsXML += "<Connect FromSheet=\"\(id)\" FromCell=\"BeginX\" FromPart=\"9\" ToSheet=\"\(fromID)\" ToCell=\"\(xml(from.x))\" ToPart=\"\(from.part)\"/>" }
                if let toID = toID { connectionsXML += "<Connect FromSheet=\"\(id)\" FromCell=\"EndX\" FromPart=\"12\" ToSheet=\"\(toID)\" ToCell=\"\(xml(to.x))\" ToPart=\"\(to.part)\"/>" }
            }
            let root = try VisioXML.element("<PageContents \(namespace)>\(shapes.xmlString)<Connects>\(connectionsXML)</Connects></PageContents>")
            for node in page.nodes { if let image = node.formatting.image, let element = root.firstLocal("Shapes")?.allShapes.first(where:{$0.attr("ID") == String(nodeIDs[node.id]!)}) { try VisioPreservation.attachImage(image,to:element,root:root,part:"visio/pages/\(file)",parts:&parts,types:extraTypes) } }
            put("visio/pages/\(file)", header+root.xmlString)
            freshBindings.append(VisioPageBinding(pageID:page.id,visioID:String(index),part:"visio/pages/\(file)",original:page,nodeIDs:nodeIDs.mapValues(String.init),edgeIDs:edgeIDs))
        }
        put("visio/pages/pages.xml", header + "<Pages \(namespace)>\(pageIndexXML)</Pages>")
        put("visio/pages/_rels/pages.xml.rels", relationshipXML(pageRelations))
        put("[Content_Types].xml", header + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"json\" ContentType=\"application/json\"/><Override PartName=\"/visio/document.xml\" ContentType=\"application/vnd.ms-visio.drawing.main+xml\"/><Override PartName=\"/visio/pages/pages.xml\" ContentType=\"application/vnd.ms-visio.pages+xml\"/><Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>\(pageContentTypes)\(extraTypes.elementsLocal("Default").map(\.xmlString).joined())</Types>")
        try VisioPreservation.ensureFonts(diagram,parts:&parts,bindings:freshBindings)
        try VisioPreservation.ensureWindowsPart(parts:&parts)
        var source = VisioDocumentArchive(parts:parts,pagesPart:"visio/pages/pages.xml",pages:freshBindings,connectorHierarchyVersion:1,
            lineageID: DefinitionRegistry.stableID(diagram.pages[0].id, "new-public-document"))
        diagram.visioArchive = source
        diagram = try DefinitionRegistry.hydrate(diagram)
        parts[nativePart] = try nativeMetadata(diagram,parts:&parts,bindings:freshBindings)
        guard parts.values.allSatisfy({ $0.count <= PackageReader.partLimit }), parts.values.reduce(0, { $0 + $1.count }) <= PackageReader.totalLimit else { throw DiagramError.invalid("This drawing exceeds the VSDX export size limit.") }
        try VisioPackage.write(parts, to: url)
        source.parts = parts
        return source
    }

    struct NativeBinding: Codable {
        let pageID: UUID
        let visioID: String
        let part: String
        let nodeIDs: [UUID: String]
        let edgeIDs: [UUID: String]
        let inheritedShapes: [UUID: VisioInheritedShape]?
        let original: DiagramPage?
    }

    struct NativeEnvelope: Codable {
        let format: Int
        let publicHashes: [String: String]
        let diagram: Diagram
        var bindings: [VisioPageBinding]? = nil
        var compactBindings: [NativeBinding]? = nil
        var pagesPart: String?
        var legacyParts: [String]?
        var masterExpansionVersion:Int? = nil
        var connectorHierarchyVersion:Int? = nil
        var connectionPointsVersion:Int? = nil
        var coordinateTransformVersion:Int? = nil
        var textRunsVersion:Int? = nil
        var textFieldsVersion:Int? = nil
        var geometryVersion:Int? = nil
        var controlsVersion:Int? = nil
        var connectorDetailsVersion:Int? = nil
    }
    private struct ConnectorMetadataHeader:Decodable {
        struct Payload:Decodable {
            struct Page:Decodable {
                struct Edge:Decodable {
                    var id:UUID;var hasDetails:Bool
                    enum CodingKeys:String,CodingKey { case id,details }
                    init(from decoder:Decoder) throws {
                        let c = try decoder.container(keyedBy:CodingKeys.self)
                        id = try c.decode(UUID.self,forKey:.id);hasDetails = c.contains(.details) ? !(try c.decodeNil(forKey:.details)) : false
                    }
                }
                var edges:[Edge]
            }
            var pages:[Page]
        }
        var connectorDetailsVersion:Int?;var publicHashes:[String:String];var diagram:Payload
    }
    private final class ConnectorMetadataGate:NSObject {
        let defaultIDs:Set<UUID>
        init(_ ids:Set<UUID>) { defaultIDs = ids }
    }
    // Archive stores are immutable and shared by snapshots. Avoid repeatedly
    // decoding an entire native cache merely to validate a default connector.
    private static let connectorMetadataGates:NSCache<NSUUID,ConnectorMetadataGate> = {
        let cache = NSCache<NSUUID,ConnectorMetadataGate>();cache.countLimit = 16;cache.totalCostLimit = 100000;return cache
    }()
    private static func currentDefaultConnectorIDs(_ archive:VisioDocumentArchive) -> Set<UUID> {
        let key = archive.sourceResourceID as NSUUID
        if let gate = connectorMetadataGates.object(forKey:key) { return gate.defaultIDs }
        var defaults = Set<UUID>()
        if let data = archive.parts[nativePart],let stored = try? NativeMetadataStorage.load(data,parts:archive.parts),
           let header = try? JSONDecoder().decode(ConnectorMetadataHeader.self,from:stored.data),header.connectorDetailsVersion == 1,
           !header.publicHashes.isEmpty,header.publicHashes.allSatisfy({name,value in archive.parts[name].map{hash($0) == value} == true}),
           Set(archive.parts.keys.filter{$0 != nativePart && !stored.storageParts.contains($0)}) == Set(header.publicHashes.keys) {
            defaults = Set(header.diagram.pages.flatMap(\.edges).filter{!$0.hasDetails}.map(\.id))
        }
        connectorMetadataGates.setObject(ConnectorMetadataGate(defaults),forKey:key,cost:max(1,defaults.count));return defaults
    }
    /// Upgrade source-backed native drawings as well as old public-package caches.
    /// Only the previously unmodelled payload is imported: cached IDs, labels,
    /// endpoints, and parent transforms remain the native drawing's own values.
    static func hydrateMissingConnectorDetails(_ diagram:Diagram) throws -> Diagram? {
        guard var archive = diagram.visioArchive else { return nil }
        let boundPages = Dictionary(archive.pages.map{($0.pageID,$0)},uniquingKeysWith:{first,_ in first})
        guard diagram.pages.contains(where:{page in page.edges.contains{$0.details == nil && boundPages[page.id]?.edgeIDs[$0.id] != nil}}) || archive.pages.contains(where:{$0.original.edges.contains{$0.details == nil}}) else { return nil }
        let defaultIDs = currentDefaultConnectorIDs(archive)
        let missing = diagram.pages.contains { page in
            guard let binding = boundPages[page.id] else { return false }
            return page.edges.contains{binding.edgeIDs[$0.id] != nil && $0.details == nil && !defaultIDs.contains($0.id)}
        } || archive.pages.contains{$0.original.edges.contains{$0.details == nil && !defaultIDs.contains($0.id)}}
        guard missing else { return nil }
        let imported = try readPublic(parts:archive.parts,title:diagram.title).diagram
        guard let publicArchive = imported.visioArchive else { return nil }
        var result = diagram,changed = false
        func details(_ publicEdge:DiagramEdge,for native:DiagramEdge) -> ShapeDetails {
            var detail = publicEdge.formatting
            if let runs = detail.textRuns,publicEdge.label != native.label {
                detail.textRuns = ShapeRichText.replacingText(publicEdge.label,with:native.label,runs:runs)
            }
            return detail
        }
        for b in archive.pages.indices {
            guard let publicBinding = publicArchive.pages.first(where:{$0.visioID == archive.pages[b].visioID}),
                  let page = imported.pages.first(where:{$0.id == publicBinding.pageID}) else { continue }
            let byID = Dictionary(page.edges.map{($0.id,$0)},uniquingKeysWith:{first,_ in first})
            let bySource = Dictionary(publicBinding.edgeIDs.compactMap{key,value in byID[key].map{(value,$0)}},uniquingKeysWith:{first,_ in first})
            if let p = result.pages.firstIndex(where:{$0.id == archive.pages[b].pageID}) {
                for e in result.pages[p].edges.indices where result.pages[p].edges[e].details == nil && !defaultIDs.contains(result.pages[p].edges[e].id) {
                    let edge = result.pages[p].edges[e]
                    guard let source = archive.pages[b].edgeIDs[edge.id],let publicEdge = bySource[source] else { continue }
                    result.pages[p].edges[e].details = details(publicEdge,for:edge);changed = true
                }
            }
            for e in archive.pages[b].original.edges.indices where archive.pages[b].original.edges[e].details == nil && !defaultIDs.contains(archive.pages[b].original.edges[e].id) {
                let edge = archive.pages[b].original.edges[e]
                guard let source = archive.pages[b].edgeIDs[edge.id],let publicEdge = bySource[source] else { continue }
                archive.pages[b].original.edges[e].details = details(publicEdge,for:edge);changed = true
            }
        }
        guard changed else { return nil };result.visioArchive = archive;return result
    }
    private static func hydrateControls(_ diagram:inout Diagram,bindings:inout [VisioPageBinding],parts:[String:Data]) throws {
        var publicParts = parts;publicParts.removeValue(forKey:nativePart)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-controls-\(UUID()).vsdx");defer { try? FileManager.default.removeItem(at:file) }
        try VisioPackage.write(publicParts,to:file);let imported = try read(from:file).diagram
        for b in bindings.indices {
            guard let publicBinding = imported.visioArchive?.pages.first(where:{$0.visioID == bindings[b].visioID}),let page = imported.pages.first(where:{$0.id == publicBinding.pageID}),let p = diagram.pages.firstIndex(where:{$0.id == bindings[b].pageID}) else { continue }
            let publicIds = Dictionary(uniqueKeysWithValues:publicBinding.nodeIDs.map{($0.value,$0.key)})
            for n in diagram.pages[p].nodes.indices {
                let id = diagram.pages[p].nodes[n].id
                guard let source = bindings[b].nodeIDs[id],let publicID = publicIds[source],let publicNode = page.nodes.first(where:{$0.id == publicID}) else { continue }
                diagram.pages[p].nodes[n].formatting.controls = publicNode.formatting.controls
                if let old = bindings[b].original.nodes.firstIndex(where:{$0.id == id}) { bindings[b].original.nodes[old].formatting.controls = publicNode.formatting.controls }
            }
        }
    }
    static func nativeMetadata(_ diagram:Diagram,parts:inout [String:Data],bindings:[VisioPageBinding]?) throws -> Data {
        NativeMetadataStorage.removeSegments(from: &parts)
        var content = diagram; content.visioArchive = nil
        var synchronizedBindings = bindings
        func synchronize(_ page:inout DiagramPage) {
            let nodesByID = Dictionary(uniqueKeysWithValues: page.nodes.map { ($0.id, $0) })
            for i in page.nodes.indices where !page.nodes[i].formatting.sheet.isEmpty || !page.nodes[i].formatting.connectionPoints.isEmpty {
                let values = ShapeSheetEngine.defaults(page.nodes[i],page:page,nodesByID:nodesByID)
                for key in ShapeSheetEngine.geometryKeys {
                    guard var cell = page.nodes[i].formatting.sheet[key],let value = values[key],value.isFinite else { continue }
                    if Double(cell.value).map({abs($0-value)>1e-10}) ?? true { cell.value = ShapeSheetEngine.format(value);page.nodes[i].formatting.sheet[key] = cell }
                }
                let points = ConnectionGeometry.cached(page.nodes[i].formatting.connectionPoints,on:page.nodes[i]);page.nodes[i].formatting.connectionPoints = points
            }
            if let binding = bindings?.first(where:{$0.pageID == page.id}),let data = parts[binding.part],let root = try? VisioXML.document(data).rootElement() {
                let shapes = root.firstLocal("Shapes")?.allShapes ?? []
                let shapesByID = Dictionary(shapes.compactMap { shape in shape.attr("ID").map { ($0, shape) } }, uniquingKeysWith: { first, _ in first })
                for i in page.nodes.indices { if let runs = page.nodes[i].formatting.textRuns,let id = binding.nodeIDs[page.nodes[i].id],let text = shapesByID[id]?.firstLocal("Text") { page.nodes[i].formatting.textRuns = ShapeRichText.synchronizeSources(runs,text:text) } }
                for i in page.edges.indices {
                    guard var detail = page.edges[i].details,let id = binding.edgeIDs[page.edges[i].id],let shape = shapesByID[id] else { continue }
                    if let runs = detail.textRuns,let text = shape.firstLocal("Text") { detail.textRuns = ShapeRichText.synchronizeSources(runs,text:text) }
                    // Keep sheet aliases coherent with the cells actually written,
                    // including typed property edits and route/line cache updates.
                    for cell in shape.elementsLocal("Cell") { if let name = cell.attr("N"),detail.sheet[name] != nil { detail.sheet[name] = ShapeSheetCell(value:cell.attr("V") ?? "",formula:cell.attr("F") ?? "",unit:cell.attr("U") ?? "") } }
                    for section in shape.elementsLocal("Section") where ["User","Property"].contains(section.attr("N") ?? "") {
                        let prefix = section.attr("N") == "User" ? "User." : "Prop."
                        for row in section.elementsLocal("Row") {
                            guard let name = row.attr("N") else { continue }
                            if row.attr("Del") == "1" {
                                detail.sheet = detail.sheet.filter{$0.key != prefix+name && !$0.key.hasPrefix(prefix+name+".")};continue
                            }
                            for cell in row.elementsLocal("Cell") { if let key = cell.attr("N") {
                                let address = prefix+name+(key == "Value" ? "" : "."+key)
                                detail.sheet[address] = ShapeSheetCell(value:cell.attr("V") ?? "",formula:cell.attr("F") ?? "",unit:cell.attr("U") ?? "")
                            } }
                            if prefix == "Prop.",let d = detail.data.firstIndex(where:{$0.key == name}) {
                                detail.data[d].value = VisioXML.value(row,"Value") ?? detail.data[d].value
                                detail.data[d].label = VisioXML.value(row,"Label") ?? detail.data[d].label
                                detail.data[d].type = VisioXML.value(row,"Type").flatMap(Int.init) ?? detail.data[d].type
                                detail.data[d].format = VisioXML.value(row,"Format") ?? detail.data[d].format
                                detail.data[d].prompt = VisioXML.value(row,"Prompt") ?? detail.data[d].prompt
                            }
                        }
                    }
                    page.edges[i].details = detail
                }
            }
        }
        for i in content.pages.indices { synchronize(&content.pages[i]) }
        let originalPages = Dictionary(uniqueKeysWithValues: diagram.pages.map { ($0.id, $0) })
        let synchronizedPages = Dictionary(uniqueKeysWithValues: content.pages.map { ($0.id, $0) })
        if synchronizedBindings != nil { for i in synchronizedBindings!.indices {
            let original = synchronizedBindings![i].original
            if originalPages[original.id] == original, let synchronized = synchronizedPages[original.id] {
                synchronizedBindings![i].original = synchronized
            } else {
                synchronize(&synchronizedBindings![i].original)
            }
        } }
        var segments:[String]?
        if let source = diagram.legacySource {
            let directory = "macvisio/legacy/"+hash(source.data)
            var names:[String] = []
            for start in stride(from:0,to:source.data.count,by:VisioPackage.partLimit) {
                let name = directory+"/segment\(names.count).mvsd";parts[name] = source.data.subdata(in:start..<min(source.data.count,start+VisioPackage.partLimit));names.append(name)
            }
            let types = try VisioXML.document(parts["[Content_Types].xml"]!)
            guard let root = types.rootElement() else { throw DiagramError.invalid("Missing package content types.") }
            if !root.elementsLocal("Default").contains(where:{$0.attr("Extension") == "mvsd"}) { let type = XMLElement(name:"Default");type.setAttr("Extension","mvsd");type.setAttr("ContentType","application/octet-stream");root.addChild(type) }
            parts["[Content_Types].xml"] = types.xmlData(options:.nodePreserveAll)
            parts[VisioXML.relationshipPart(nativePart)] = Data(relationshipXML(names.enumerated().map{("rId\($0.offset+1)","urn:macvisio:relationships:legacy-source","/"+$0.element)}).utf8)
            content.legacySource?.data = Data();segments = names
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var publicHashes = parts.filter { $0.key != nativePart }.mapValues(hash)
        let currentPages = Dictionary(uniqueKeysWithValues: content.pages.map { ($0.id, $0) })
        let compactBindings: [NativeBinding]? = synchronizedBindings.map { bindings in
            bindings.map { binding in
                NativeBinding(pageID: binding.pageID, visioID: binding.visioID, part: binding.part,
                    nodeIDs: binding.nodeIDs, edgeIDs: binding.edgeIDs,
                    inheritedShapes: binding.inheritedShapes,
                    original: currentPages[binding.pageID] == binding.original ? nil : binding.original)
            }
        }
        func encodedEnvelope() throws -> Data {
            if let compactBindings, compactBindings.count == content.pages.count {
                let compact = try encoder.encode(NativeEnvelope(format:4,publicHashes:publicHashes,diagram:content,
                    bindings:nil,compactBindings:compactBindings,pagesPart:diagram.visioArchive?.pagesPart,
                    legacyParts:segments,masterExpansionVersion:1,connectorHierarchyVersion:1,
                    connectionPointsVersion:1,coordinateTransformVersion:1,textRunsVersion:1,
                    textFieldsVersion:1,geometryVersion:4,controlsVersion:1,connectorDetailsVersion:1))
                if compact.count > VisioPackage.partLimit { return compact }
            }
            return try encoder.encode(NativeEnvelope(format:2,publicHashes:publicHashes,diagram:content,
                bindings:synchronizedBindings,pagesPart:diagram.visioArchive?.pagesPart,legacyParts:segments,
                masterExpansionVersion:1,connectorHierarchyVersion:1,connectionPointsVersion:1,
                coordinateTransformVersion:1,textRunsVersion:1,textFieldsVersion:1,geometryVersion:4,
                controlsVersion:1,connectorDetailsVersion:1))
        }
        var payload = try encodedEnvelope()
        if payload.count > VisioPackage.partLimit {
            // Register the segment content type, then patch its hash into the already encoded envelope.
            let previousContentTypes = parts["[Content_Types].xml"]
            try NativeMetadataStorage.registerContentType(in: &parts)
            if parts["[Content_Types].xml"] != previousContentTypes {
                guard let contentTypes = parts["[Content_Types].xml"], publicHashes["[Content_Types].xml"] != nil else {
                    throw DiagramError.invalid("Native metadata is missing the public content-types hash.")
                }
                let originalHashes = publicHashes
                publicHashes["[Content_Types].xml"] = hash(contentTypes)
                let memberPrefix = Data("\"publicHashes\":".utf8)
                let originalMember = memberPrefix + (try encoder.encode(originalHashes))
                let replacementMember = memberPrefix + (try encoder.encode(publicHashes))
                guard originalMember.count == replacementMember.count,
                      let memberRange = payload.range(of: originalMember, options: .backwards) else {
                    throw DiagramError.invalid("Could not safely update the native metadata content-types hash.")
                }
                payload.replaceSubrange(memberRange, with: replacementMember)
            }
        }
        return try NativeMetadataStorage.store(payload, in: &parts)
    }
    private struct MasterDefinition {
        let name:String
        let shape:XElement
        let part:String
        let shapeIndex:[UInt32:XElement]
        let connections:[XElement]
        func find(_ id:String) -> XElement? {
            UInt32(id).flatMap{shapeIndex[$0]}
        }
        func withShape(_ shape:XElement) -> MasterDefinition { MasterDefinition(name:name,shape:shape,part:part,shapeIndex:shapeIndex,connections:connections) }
    }
    private final class MasterInstance {
        var identifiers:[String:String] = [:]
        var nodes:[UUID:(XElement,XElement)] = [:]
        var connections:[XElement] = []
    }
    private static func remapMasterFormula(_ formula:String,identifiers:[String:String]) -> String {
        VisioIDAllocator.remap(formula,using:identifiers)
    }
    private static func sheetCell(_ key:String,in shape:XElement) -> XCell? {
        if key.hasPrefix("User.") || key.hasPrefix("Prop.") {
            let section = key.hasPrefix("User.") ? "User" : "Property",name = String(key.dropFirst(5))
            let rows = shape.children(named:"Section").first{$0.attributes["N"] == section}?.children(named:"Row") ?? []
            if let row = rows.first(where:{$0.attributes["N"] == name}) { return row.cells["Value"] }
            guard let separator = name.lastIndex(of:".") else { return nil }
            let rowName = String(name[..<separator]),cellName = String(name[name.index(after:separator)...])
            return rows.first{$0.attributes["N"] == rowName}?.cells[cellName]
        }
        if key == "Char.Size" { return shape.children(named:"Section").first{$0.attributes["N"] == "Character"}?.children(named:"Row").first?.cells["Size"] }
        return shape.cells[key]
    }
    private static func inheritedRows(_ shape:XElement,master:XElement?,section:String) -> [XElement] {
        func matching(_ row:XElement) -> Bool { row.attributes["N"] == section || (section == "Control" && row.attributes["N"] == "Controls") }
        let own = shape.children(named:"Section").first(where:matching)
        if ["1","true"].contains(own?.attributes["Del"] ?? "") { return [] }
        let base = master?.children(named:"Section").first(where:matching)?.children(named:"Row") ?? []
        let local = own?.children(named:"Row") ?? []
        func key(_ row:XElement) -> String {
            if let name = row.attributes["N"] { return name }
            if section == "Control",let index = row.attributes["IX"],let inherited = base.enumerated().first(where:{($0.element.attributes["IX"] ?? String($0.offset)) == index})?.element { return inherited.attributes["N"] ?? index }
            return row.attributes["IX"] ?? ""
        }
        var result:[XElement] = [],used = Set<String>(),rowIndex = 0
        for row in base+local {
            let name = key(row);guard used.insert(name).inserted else { continue }
            let originalIndex = rowIndex;rowIndex += 1
            let inherited = base.first{key($0) == name},override = local.first{key($0) == name}
            if ["1","true"].contains(override?.attributes["Del"] ?? inherited?.attributes["Del"] ?? "") { continue }
            var attributes = inherited?.attributes ?? [:];attributes.merge(override?.attributes ?? [:]){_,new in new};attributes["MacVisio.RowIndex"] = String(originalIndex)
            let merged = XElement(name:"Row",attributes:attributes)
            var cells = inherited?.cells ?? [:];cells.merge(override?.cells ?? [:]){old,new in new.value == "Inh" ? old : new}
            merged.elements = cells.keys.sorted().map{key in let cell = cells[key]!;return XElement(name:"Cell",attributes:["N":key,"V":cell.value,"F":cell.formula,"U":cell.unit]) }
            result.append(merged)
        }
        return result
    }
    /// Visio caches theme-driven colors as "Themed"; resolve them through the shape's quick style so the
    /// drawing shows Visio's colors. The page binding's original receives the same values, so a save
    /// never mistakes them for edits.
    private static func resolveThemedAppearance(_ diagram: inout Diagram, bindings: inout [VisioPageBinding]) {
        for p in diagram.pages.indices where diagram.pages[p].theme != nil {
            let context = ShapeSheetContext(page: diagram.pages[p], binding: bindings.first { $0.pageID == diagram.pages[p].id }, document: diagram)
            func themed(_ cell: ShapeSheetCell?) -> Bool { cell.map { $0.value.caseInsensitiveCompare("Themed") == .orderedSame } ?? false }
            var updates: [UUID: (fill: String?, stroke: String?, text: String?)] = [:]
            for node in diagram.pages[p].nodes {
                let sheet = node.formatting.sheet
                let fill = themed(sheet["FillForegnd"]) ? context.themedColor(.fill, for: node.id)?.hex : nil
                let stroke = themed(sheet["LineColor"]) ? context.themedColor(.line, for: node.id)?.hex : nil
                let text = themed(sheet["Char.Color"]) ? context.themedColor(.font, for: node.id)?.hex : nil
                if fill != nil || stroke != nil || text != nil { updates[node.id] = (fill, stroke, text) }
            }
            // Connector labels take the theme's connector font paint.
            var labelColors: [UUID: String] = [:]
            for edge in diagram.pages[p].edges where themed(edge.formatting.sheet["Char.Color"]) && edge.formatting.textRuns != nil {
                if let color = context.themedColor(.font, for: edge.id)?.hex { labelColors[edge.id] = String(color.prefix(7)) }
            }
            func apply(_ page: inout DiagramPage) {
                for i in page.edges.indices { guard let color = labelColors[page.edges[i].id],var detail = page.edges[i].details,var runs = detail.textRuns else { continue }
                    for r in runs.indices { runs[r].character.color = color }
                    detail.textRuns = runs; page.edges[i].details = detail
                }
                for i in page.nodes.indices { guard let update = updates[page.nodes[i].id] else { continue }
                    if let fill = update.fill { page.nodes[i].fill = String(fill.prefix(7)) + String(page.nodes[i].fill.dropFirst(7)) }
                    if let stroke = update.stroke { page.nodes[i].stroke = String(stroke.prefix(7)) + String(page.nodes[i].stroke.dropFirst(7)) }
                    if let text = update.text { page.nodes[i].textColor = String(text.prefix(7)) }
                }
            }
            apply(&diagram.pages[p])
            if let b = bindings.firstIndex(where: { $0.pageID == diagram.pages[p].id }) { apply(&bindings[b].original) }
        }
    }
    private struct Relationship { let type: String; let target: String; let external: Bool }

    /// A VSDX document selects its Office theme through a document-level OPC
    /// relationship. The theme part itself contains DrawingML color slots and
    /// Visio extensions; unsupported color encodings remain typed raw metadata.
    private static func selectedOfficeTheme(in relationships:[String:Relationship],documentPart:String,archive:PackageReader) throws -> VisioTheme? {
        let candidates = relationships.filter{$0.value.type == officeThemeRelationship}
        guard !candidates.isEmpty else { return nil }
        guard candidates.count == 1,let (relationshipID,relationship) = candidates.first else {
            throw DiagramError.invalid("The document has an ambiguous Office theme relationship.")
        }
        guard !relationship.external else { return nil }
        let part = try resolve(relationship.target,relativeTo:documentPart)
        let root = try archive.xml(part,expectedRoot:"theme")
        let themeElements = root.child("themeElements")
        let colorScheme = themeElements?.child("clrScheme")
        var rawColors:[String:VisioThemeColor] = [:],colors:[String:String] = [:]
        let colorSlots:[String:String] = ["dk1":"Dark","lt1":"Light","dk2":"Dark2","lt2":"Light2",
            "accent1":"AccentColor1","accent2":"AccentColor2","accent3":"AccentColor3",
            "accent4":"AccentColor4","accent5":"AccentColor5","accent6":"AccentColor6",
            "hlink":"Hyperlink","folHlink":"FollowedHyperlink"]
        func hexColor(_ element:XElement?) -> String? {
            guard let element else { return nil }
            let raw = element.name == "sysClr" ? (element.attributes["lastClr"] ?? "") : (element.attributes["val"] ?? "")
            guard raw.count == 6,raw.allSatisfy({$0.isHexDigit}) else { return nil }
            return "#"+raw.uppercased()
        }
        for (slot,key) in colorSlots {
            guard let entry = colorScheme?.child(slot),let color = entry.elements.first else { continue }
            rawColors[slot] = VisioThemeColor(type:color.name,value:color.attributes["val"],lastColor:color.attributes["lastClr"])
            if let value = hexColor(color) { colors[key] = value }
        }
        func descendants(_ element:XElement?,named name:String) -> [XElement] {
            guard let element else { return [] }
            return element.elements.flatMap{child in child.name == name ? [child]+descendants(child,named:name) : descendants(child,named:name)}
        }
        func schemeEnum(_ element:XElement?) -> Int? {
            descendants(element,named:"schemeID").first?.attributes["schemeEnum"].flatMap(Int.init)
        }
        func standardLineStyles(_ scheme:XElement?) -> [VisioThemeLineStyle] {
            guard let list = scheme?.child("lnStyleLst") else { return [] }
            return list.elements.filter{$0.name == "ln"}.map { line in
                let widthEMU:Int?
                if let rawWidth = line.attributes["w"] { widthEMU = Int(rawWidth) }
                else { widthEMU = 0 }
                return VisioThemeLineStyle(widthEMU:widthEMU,cap:line.attributes["cap"])
            }
        }
        func extensionLineStyles(_ list:XElement?) -> [VisioThemeLineExtension] {
            guard let list else { return [] }
            return list.elements.filter{$0.name == "lineStyle"}.map { style in
                let line = style.child("lineEx")
                return VisioThemeLineExtension(roundingEMU:line?.attributes["rndg"].flatMap(Int.init),
                    beginArrow:line?.attributes["start"].flatMap(Int.init),beginSize:line?.attributes["startSize"].flatMap(Int.init),
                    endArrow:line?.attributes["end"].flatMap(Int.init),endSize:line?.attributes["endSize"].flatMap(Int.init))
            }
        }
        // Quick-style paints. A color element is srgbClr/sysClr/schemeClr with modifier children.
        func paint(_ color:XElement?) -> VisioThemePaint? {
            guard let color else { return nil }
            let modifiers = color.elements.compactMap { modifier -> VisioThemeColorModifier? in
                guard let raw = modifier.attributes["val"],let value = Double(raw) else { return nil }
                return VisioThemeColorModifier(name:modifier.name,value:value/100000)
            }
            switch color.name {
            case "schemeClr": return VisioThemePaint(base:color.attributes["val"] ?? "phClr",modifiers:modifiers)
            case "srgbClr","sysClr": return hexColor(color).map { VisioThemePaint(base:$0,modifiers:modifiers) }
            default: return nil
            }
        }
        func fillPaint(_ fill:XElement) -> VisioThemePaint? {
            switch fill.name {
            case "solidFill": return paint(fill.elements.first)
            case "gradFill","pattFill","blipFill": return VisioThemePaint(base:"phClr",gradient:true)
            case "noFill": return VisioThemePaint(base:"none")
            default: return paint(fill.elements.first)
            }
        }
        func linePaints(_ scheme:XElement?) -> [VisioThemePaint]? {
            guard let list = scheme?.child("lnStyleLst") else { return nil }
            return list.elements.filter{$0.name == "ln"}.map { line in line.elements.first(where:{$0.name.hasSuffix("Fill")}).flatMap(fillPaint) ?? VisioThemePaint(base:"phClr") }
        }
        func fontPaints(_ list:XElement?) -> [VisioThemePaint]? {
            guard let list else { return nil }
            return list.elements.filter{$0.name == "fontProps"}.map { props in paint(props.child("color")?.elements.first) ?? VisioThemePaint(base:"phClr") }
        }
        let effectScheme = themeElements?.child("fmtScheme")
        let connectorScheme = descendants(themeElements,named:"fmtConnectorScheme").first
        let lineStylesExtension = descendants(themeElements,named:"lineStyles").first
        let effectLineStyles = standardLineStyles(effectScheme)
        let connectorLineStyles = standardLineStyles(connectorScheme)
        let effectLineExtensions = extensionLineStyles(lineStylesExtension?.child("fmtSchemeLineStyles"))
        let connectorLineExtensions = extensionLineStyles(lineStylesExtension?.child("fmtConnectorSchemeLineStyles"))
        let effectSchemeIndex = schemeEnum(descendants(themeElements,named:"fmtSchemeEx").first)
        let connectorSchemeIndex = schemeEnum(descendants(themeElements,named:"fmtConnectorSchemeEx").first)
        var variationColorSchemes:[Int:[String:String]] = [:],variationColorSchemeMonotone:[Int:Bool] = [:]
        if let list = descendants(colorScheme,named:"variationClrSchemeLst").first {
            let schemes = list.elements.filter{$0.name == "variationClrScheme"}
            for (index,scheme) in schemes.enumerated() {
                variationColorSchemeMonotone[index] = scheme.attributes["monotone"].map{["1","true"].contains($0.lowercased())} ?? false
                var variation:[String:String] = [:]
                for entry in scheme.elements where entry.name.hasPrefix("varColor") {
                    guard let number = Int(entry.name.dropFirst("varColor".count)),(1...7).contains(number),
                          let color = entry.elements.first,let value = hexColor(color) else { continue }
                    variation["VariantColor\(number)"] = value
                }
                if !variation.isEmpty { variationColorSchemes[index] = variation }
            }
        }
        var variationStyleSchemes:[Int:VisioThemeVariationStyleScheme] = [:]
        if let list = descendants(root,named:"variationStyleSchemeLst").first {
            for (index,scheme) in list.elements.filter({$0.name == "variationStyleScheme"}).enumerated() {
                let styles = scheme.elements.filter{$0.name == "varStyle"}.map{entry in
                    VisioThemeVariationStyle(fillIndex:entry.attributes["fillIdx"].flatMap{Int($0)},
                        lineIndex:entry.attributes["lineIdx"].flatMap{Int($0)},
                        effectIndex:entry.attributes["effectIdx"].flatMap{Int($0)},
                        fontIndex:entry.attributes["fontIdx"].flatMap{Int($0)})
                }
                variationStyleSchemes[index] = VisioThemeVariationStyleScheme(embellishment:scheme.attributes["embellishment"].flatMap{Int($0)},styles:styles)
            }
        }
        if let background = descendants(colorScheme,named:"bkgnd").first,
           let rgb = descendants(background,named:"srgbClr").first ?? descendants(background,named:"sysClr").first,
           let value = hexColor(rgb) { colors["BackgroundColor"] = value }
        return VisioTheme(relationshipID:relationshipID,relationshipType:relationship.type,target:relationship.target,part:part,
            name:root.attributes["name"],colorSchemeName:colorScheme?.attributes["name"],schemeIndex:schemeEnum(colorScheme),
            effectSchemeIndex:effectSchemeIndex,connectorSchemeIndex:connectorSchemeIndex,
            colorScheme:rawColors,
            effectLineStyles:effectLineStyles,connectorLineStyles:connectorLineStyles,
            effectLineExtensions:effectLineExtensions,connectorLineExtensions:connectorLineExtensions,
            variationColorSchemes:variationColorSchemes,variationColorSchemeMonotone:variationColorSchemeMonotone,
            variationStyleSchemes:variationStyleSchemes,values:[:],colors:colors,
            fillPaints:effectScheme?.child("fillStyleLst").map { $0.elements.compactMap(fillPaint) },
            linePaints:linePaints(effectScheme),
            fontPaints:fontPaints(descendants(root,named:"fontStyles").first),
            connectorLinePaints:linePaints(connectorScheme),
            connectorFontPaints:fontPaints(descendants(root,named:"connectorFontStyles").first))
    }

    /// Build a page-specific theme view, retaining the full variation list and
    /// exposing the selected variation as VariantColor1...VariantColor7.
    private static func pageTheme(_ source:VisioTheme?,variationColorIndex:Int?,variationStyleIndex:Int?) -> VisioTheme? {
        guard var theme = source else { return nil }
        theme.variationColorIndex = variationColorIndex
        theme.variationStyleIndex = variationStyleIndex
        let selected = variationColorIndex ?? 0
        let index = theme.variationColorSchemes[selected] == nil ? 0 : selected
        if let colors = theme.variationColorSchemes[index] {
            theme.colors.merge(colors,uniquingKeysWith:{_,new in new})
        }
        return theme
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func relationshipXML(_ values: [(String, String, String)]) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Relationships xmlns=\"\(relationshipNamespace)\">" + values.map { "<Relationship Id=\"\(xml($0.0))\" Type=\"\(xml($0.1))\" Target=\"\(xml($0.2))\"/>" }.joined() + "</Relationships>"
    }

    private static func relationships(in archive: PackageReader, source: String) throws -> [String: Relationship] {
        let path: String
        if source.isEmpty { path = "_rels/.rels" }
        else {
            let parent = (source as NSString).deletingLastPathComponent
            path = (parent.isEmpty ? "" : parent + "/") + "_rels/" + (source as NSString).lastPathComponent + ".rels"
        }
        guard archive.names.contains(path) else { return [:] }
        let root = try archive.xml(path, expectedRoot: "Relationships")
        var values: [String: Relationship] = [:]
        for entry in root.children(named: "Relationship") {
            guard let id = entry.attributes["Id"], let type = entry.attributes["Type"], let target = entry.attributes["Target"], values[id] == nil else { throw DiagramError.invalid("Invalid or duplicate package relationship.") }
            values[id] = Relationship(type: type, target: target, external: entry.attributes["TargetMode"] == "External")
        }
        return values
    }

    /// URI normalization stays inside the package and never resolves filesystem URLs.
    static func resolve(_ target: String, relativeTo source: String) throws -> String {
        guard let decoded = target.removingPercentEncoding, !decoded.contains(":"), !decoded.contains("\\"), !decoded.contains("?"), !decoded.contains("#"), !decoded.contains("\0") else { throw DiagramError.invalid("An unsafe package relationship was rejected.") }
        var components = target.hasPrefix("/") ? [] : (source as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        for component in decoded.split(separator: "/") {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else { throw DiagramError.invalid("A package relationship escapes the archive.") }
                components.removeLast()
            } else { components.append(String(component)) }
        }
        guard !components.isEmpty else { throw DiagramError.invalid("A package relationship has an empty target.") }
        return components.joined(separator: "/")
    }

    private static func uniqueElements(_ elements: [XElement], key: String) throws -> [(String, XElement)] {
        var seen = Set<String>(), result: [(String, XElement)] = []
        for element in elements {
            guard let value = element.attributes[key], seen.insert(value).inserted else { throw DiagramError.invalid("Missing or duplicate Visio identifiers.") }
            if key == "ID",UInt32(value) == nil { throw DiagramError.invalid("A Visio shape has an invalid numeric identifier.") }
            result.append((value, element))
        }
        return result
    }

    /// Styles are immutable during one import. Resolve each family/ID once,
    /// retaining the existing bounded inheritance rules and per-shape overrides.
    private final class ResolvedStyleCells {
        let styles:[String:XElement]
        private var cache:[String:[String:[String:XCell]]] = [:]
        init(styles:[String:XElement]) { self.styles = styles }
        func cells(_ id:String,family:String) -> [String:XCell] {
            if let result = cache[family]?[id] { return result }
            let result = VisioFormat.styleCells(id,styles:styles,styleKey:family,depth:0)
            cache[family,default:[:]][id] = result
            return result
        }
    }

    private static func inheritedCells(_ shape: XElement, master: XElement?, styles: ResolvedStyleCells) -> [String: XCell] {
        var cells: [String: XCell] = [:]
        for key in ["LineStyle", "FillStyle", "TextStyle"] {
            let id = shape.attributes[key] ?? master?.attributes[key] ?? "0"
            for (name, value) in styles.cells(id,family:key) { cells[name] = value }
        }
        if let master { cells.merge(master.cells) { _, new in new } }
        cells.merge(shape.cells) { old, new in new.value == "Inh" ? old : new }
        return cells
    }

    private static func styleCells(_ id: String, styles: [String: XElement], styleKey: String, depth: Int) -> [String: XCell] {
        guard let style = styles[id], depth < 10 else { return [:] }
        var values = style.attributes[styleKey].map { styleCells($0, styles: styles, styleKey: styleKey, depth: depth + 1) } ?? [:]
        // A shape can use different line, fill and text styles; do not let one overwrite another.
        let themeSelectorNames = ["QuickStyleLineMatrix","QuickStyleType","EffectSchemeIndex","ConnectorSchemeIndex","ThemeIndex","ColorSchemeIndex","FontSchemeIndex"]
        let filtered = style.cells.filter { name,_ in
            switch styleKey {
            case "LineStyle":
                return name.hasPrefix("Line") || name.contains("Arrow")
                    || themeSelectorNames.contains(where:{selector in selector.caseInsensitiveCompare(name) == .orderedSame})
            case "FillStyle": return name.hasPrefix("Fill") || name.hasPrefix("Shdw")
            default: return !name.hasPrefix("Line") && !name.hasPrefix("Fill") && !name.hasPrefix("Shdw")
            }
        }
        values.merge(filtered) { old, new in new.value == "Inh" ? old : new }
        return values
    }

    private static func inheritedSectionCells(_ shape: XElement, master: XElement?, styles: [String: XElement], section: String, styleKey: String) -> [String: XCell] {
        func row(_ element: XElement?) -> [String: XCell] { element?.children(named: "Section").first(where: { $0.attributes["N"] == section })?.children(named: "Row").first?.cells ?? [:] }
        var cells = row(styles[shape.attributes[styleKey] ?? master?.attributes[styleKey] ?? "0"])
        cells.merge(row(master)) { _, new in new }
        cells.merge(row(shape)) { old, new in new.value == "Inh" ? old : new }
        return cells
    }

    private static func connectorDetails(_ shape:XElement,cells:[String:XCell],master:XElement?,document:XElement,styles:[String:XElement],palette:[String:String],layerNames:[String:String],edge:DiagramEdge,warnings:inout Set<String>) throws -> ShapeDetails {
        var detail = ShapeDetails();detail.sourceShapeID = edge.sourceShapeID
        detail.sheet = cells.mapValues{ShapeSheetCell(value:$0.value,formula:$0.formula,unit:$0.unit)}
        for section in ["User","Property"] {
            let prefix = section == "User" ? "User." : "Prop."
            for row in inheritedRows(shape,master:master,section:section) {
                guard let name = row.attributes["N"] else { continue }
                for (key,cell) in row.cells {
                    let address = prefix+name+(key == "Value" ? "" : "."+key)
                    detail.sheet[address] = ShapeSheetCell(value:cell.value,formula:cell.formula,unit:cell.unit)
                }
            }
        }
        let character = inheritedSectionCells(shape,master:master,styles:styles,section:"Character",styleKey:"TextStyle")
        if let size = character["Size"] { detail.sheet["Char.Size"] = ShapeSheetCell(value:size.value,formula:size.formula,unit:size.unit) }
        if let color = character["Color"] { detail.sheet["Char.Color"] = ShapeSheetCell(value:color.value,formula:color.formula,unit:color.unit) }
        detail.fontName = fontName(character["Font"]?.value ?? "0",in:document)
        let bits = Int(exactly:number(character["Style"]) ?? 0) ?? 0
        detail.italic = bits & 2 != 0;detail.underline = bits & 4 != 0
        let paragraph = inheritedSectionCells(shape,master:master,styles:styles,section:"Paragraph",styleKey:"TextStyle")
        detail.alignment = number(paragraph["HorzAlign"]) == 0 ? .left : number(paragraph["HorzAlign"]) == 2 ? .right : .center
        detail.layerNames = (cells["LayerMember"]?.value ?? "").split(separator:";").compactMap{layerNames[String($0)]}
        detail.data = inheritedRows(shape,master:master,section:"Property").enumerated().map{i,row in
            let c = row.cells;return ShapeDataProperty(key:row.attributes["N"] ?? "Row_\(i)",label:c["Label"]?.value ?? row.attributes["N"] ?? "Property",value:c["Value"]?.value ?? "",type:number(c["Type"]).flatMap{Int(exactly:$0)} ?? 0,format:c["Format"]?.value ?? "",prompt:c["Prompt"]?.value ?? "",valueUnit:ShapeDataProperty.importedValueUnit(c["Value"]?.unit,type:number(c["Type"]).flatMap{Int(exactly:$0)} ?? 0,value:c["Value"]?.value ?? ""))
        }
        detail.hyperlinks = inheritedRows(shape,master:master,section:"Hyperlink").map{row in
            let c = row.cells;return ShapeHyperlink(address:c["Address"]?.value ?? "",subAddress:c["SubAddress"]?.value ?? "",description:c["Description"]?.value ?? "",sourceRowName:row.attributes["N"])
        }
        let text = shape.child("Text") ?? master?.child("Text"),fieldRows = inheritedRows(shape,master:master,section:"Field")
        if !fieldRows.isEmpty || text?.runs.contains(where:{$0.field != nil}) == true {
            var fields:[ShapeTextField] = []
            for row in fieldRows {
                guard let index = Int(row.attributes["IX"] ?? row.attributes["MacVisio.RowIndex"] ?? ""),index >= 0,index <= UInt32.max,!fields.contains(where:{$0.index == index}) else { throw DiagramError.invalid("Invalid connector field row index.") }
                fields.append(ShapeTextField(index:index,cells:row.cells.mapValues{ShapeSheetCell(value:$0.value,formula:$0.formula,unit:$0.unit)},cached:text?.runs.first{$0.field == index}?.text))
            }
            for run in text?.runs ?? [] { if let index = run.field,!fields.contains(where:{$0.index == index}) {
                fields.append(ShapeTextField(index:index,cells:[:],cached:run.text));warnings.insert("An unresolved connector text field retains its cached display.")
            } };detail.textFields = fields
        }
        if let text,!edge.label.isEmpty || detail.textFields?.isEmpty == false {
            var node = edge.textNode;node.details = detail
            node.fontSize = min(500,max(1,try finiteNumber(character,"Size",default:12/72)*72))
            node.textColor = color(character["Color"],palette:palette,fallback:"#000000");node.bold = bits & 1 != 0
            detail.textRuns = ShapeRichText.droppingTerminalMark(try richText(text,shape:shape,master:master,document:document,styles:styles,palette:palette,node:node,warnings:&warnings))
            if let first = detail.textRuns?.first {
                detail.fontName = first.character.fontName;detail.italic = first.character.italic;detail.underline = first.character.underline;detail.alignment = first.paragraph.alignment
            }
        }
        return detail
    }
    private static func richText(_ text:XElement,shape:XElement,master:XElement?,document:XElement,styles:[String:XElement],palette:[String:String],node:DiagramNode,warnings:inout Set<String>) throws -> [ShapeTextRun] {
        func cells(_ section:String,_ index:Int) -> [String:XCell] {
            func row(_ element:XElement?,_ ix:Int) -> [String:XCell] { element?.children(named:"Section").first{$0.attributes["N"] == section}?.children(named:"Row").first{($0.attributes["IX"] ?? "0") == String(ix) && $0.attributes["Del"] != "1"}?.cells ?? [:] }
            func inheritedStyle(_ id:String,_ depth:Int) -> [String:XCell] {
                guard depth < 10,let style = styles[id] else { return [:] }
                var result = style.attributes["TextStyle"].map{inheritedStyle($0,depth+1)} ?? [:]
                result.merge(row(style,0)){old,new in new.value == "Inh" ? old : new};return result
            }
            var result = inheritedStyle(shape.attributes["TextStyle"] ?? master?.attributes["TextStyle"] ?? "0",0)
            result.merge(row(master,index)){old,new in new.value == "Inh" ? old : new}
            result.merge(row(shape,index)){old,new in new.value == "Inh" ? old : new};return result
        }
        if !text.children(named:"tp").isEmpty { warnings.insert("Custom tab runs are retained in the source; native tab layout is incomplete.") }
        var output:[ShapeTextRun] = []
        for fragment in text.runs {
            guard fragment.character >= 0,fragment.paragraph >= 0,fragment.character <= Int32.max,fragment.paragraph <= Int32.max else { throw DiagramError.invalid("Invalid text run style index.") }
            let c = cells("Character",fragment.character),p = cells("Paragraph",fragment.paragraph)
            var character = ShapeCharacterStyle(node:node);character.sourceIndex = fragment.character;character.cells = c.mapValues{ShapeSheetCell(value:$0.value,formula:$0.formula,unit:$0.unit)}
            let font = c["Font"]?.value ?? "0"
            character.fontName = fontName(font,in:document)
            character.size = min(500,max(1,try finiteNumber(c,"Size",default:node.fontSize/72)*72))
            character.color = withTransparency(color(c["Color"],palette:palette,fallback:node.textColor),value:number(c["ColorTrans"]))
            let bits = Int(exactly:number(c["Style"]) ?? 0) ?? 0;character.bold = bits & 1 != 0;character.italic = bits & 2 != 0;character.underline = bits & 4 != 0;character.strikethrough = number(c["Strikethru"]) == 1
            var paragraph = ShapeParagraphStyle();paragraph.sourceIndex = fragment.paragraph;paragraph.cells = p.mapValues{ShapeSheetCell(value:$0.value,formula:$0.formula,unit:$0.unit)}
            let align = number(p["HorzAlign"]) ?? 1;paragraph.alignment = align == 0 ? .left : align == 2 ? .right : .center
            if align > 2 || ["Bullet","IndFirst","IndLeft","IndRight","SpBefore","SpAfter"].contains(where:{(number(p[$0]) ?? 0) != 0}) { warnings.insert("Advanced paragraph spacing, indentation and bullets use an approximate native layout; source cells remain preserved.") }
            if ["Pos","Case","Letterspace"].contains(where:{(number(c[$0]) ?? 0) != 0}) || (number(c["FontScale"]) ?? 1) != 1 { warnings.insert("Advanced character placement/case/spacing uses an approximate native layout; source cells remain preserved.") }
            let run = ShapeTextRun(text:fragment.text,character:character,paragraph:paragraph,fieldIndex:fragment.field,fieldToken:fragment.field.map{_ in UUID()})
            if fragment.field == nil,let last = output.last,last.fieldIndex == nil,last.character == character,last.paragraph == paragraph { output[output.count-1].text += fragment.text } else { output.append(run) }
        }
        return output
    }

    private static func fontName(_ value:String,in document:XElement) -> String {
        guard let index = Int(value) else { return value }
        let faces = document.child("FaceNames")?.children(named:"FaceName") ?? []
        if faces.indices.contains(index),let name = faces[index].attributes["NameU"] { return name }
        return faces.first{$0.attributes["ID"] == value}?.attributes["Name"] ?? "Arial"
    }

    private static func pageSheetCells(_ element:XElement?) -> [String:ShapeSheetCell]? {
        guard let element else { return nil }
        let structural = Set(["pagewidth","pageheight","pagescale","drawingscale","drawingscaletype"])
        var result = element.cells.reduce(into:[String:ShapeSheetCell]()) { result,entry in
            guard !structural.contains(entry.key.lowercased()) else { return }
            result[entry.key] = ShapeSheetCell(value:entry.value.value,formula:entry.value.formula,unit:entry.value.unit)
        }
        for section in element.children(named:"Section") where ["User","Property"].contains(section.attributes["N"] ?? "") {
            let prefix = section.attributes["N"] == "Property" ? "Prop." : "User."
            for row in section.children(named:"Row") {
                guard let rowName = row.attributes["N"] else { continue }
                for (cellName,cell) in row.cells {
                    let key = cellName == "Value" ? prefix+rowName : prefix+rowName+"."+cellName
                    result[key] = ShapeSheetCell(value:cell.value,formula:cell.formula,unit:cell.unit)
                }
            }
        }
        return result.isEmpty ? nil : result
    }
    private static func pageSheetCells(_ element:XMLElement?) -> [String:ShapeSheetCell]? {
        guard let element else { return nil }
        var result = [String:ShapeSheetCell]()
        let structural = Set(["pagewidth","pageheight","pagescale","drawingscale","drawingscaletype"])
        for cell in element.elementsLocal("Cell") {
            guard let name = cell.attr("N"),let value = cell.attr("V") else { continue }
            guard !structural.contains(name.lowercased()) else { continue }
            result[name] = ShapeSheetCell(value:value,formula:cell.attr("F") ?? "",unit:cell.attr("U") ?? "")
        }
        for section in element.elementsLocal("Section") where ["User","Property"].contains(section.attr("N") ?? "") {
            let prefix = section.attr("N") == "Property" ? "Prop." : "User."
            for row in section.elementsLocal("Row") {
                guard let rowName = row.attr("N") else { continue }
                for cell in row.elementsLocal("Cell") {
                    guard let cellName = cell.attr("N"),let value = cell.attr("V") else { continue }
                    let key = cellName == "Value" ? prefix+rowName : prefix+rowName+"."+cellName
                    result[key] = ShapeSheetCell(value:value,formula:cell.attr("F") ?? "",unit:cell.attr("U") ?? "")
                }
            }
        }
        return result.isEmpty ? nil : result
    }

    private static func number(_ cell: XCell?) -> Double? {
        guard let value = cell?.value, let numeric = Double(value), numeric.isFinite else { return nil }
        return numeric
    }
    private static func finiteNumber(_ cells: [String: XCell], _ name: String, default fallback: Double) throws -> Double {
        guard let value = cells[name]?.value else { return fallback }
        if value.caseInsensitiveCompare("themed") == .orderedSame { return fallback }
        guard let number = Double(value), number.isFinite else { throw DiagramError.invalid("A shape has an invalid cached \(name) value.") }
        return number
    }
    private static func dimension(_ cells: [String: XCell], _ name: String, default fallback: Double,allowZero:Bool = false,factor:Double = 1,allowSigned:Bool = false) throws -> Double {
        let value = try finiteNumber(cells, name, default: fallback)
        if allowZero,value == 0 { return 0.000001 }
        guard (allowSigned ? value != 0 : value > 0),abs(value) * 72 <= 1e9,abs(value) * 72 * factor <= 20000 else { throw DiagramError.invalid("The Visio drawing contains unsupported \(name) dimensions.") }
        return value
    }

    private static func color(_ cell: XCell?, palette: [String: String], fallback: String) -> String {
        guard let cell else { return fallback }
        let value = palette[cell.value] ?? cell.value
        if value.hasPrefix("#"), value.count == 7, value.dropFirst().allSatisfy({ $0.isHexDigit }) { return value.uppercased() }
        let formula = cell.formula.uppercased().replacingOccurrences(of: " ", with: "")
        if let start = formula.range(of: "RGB("), let end = formula[start.upperBound...].firstIndex(of: ")") {
            let rgb = formula[start.upperBound..<end].split(separator: ",").compactMap { Int($0) }
            if rgb.count == 3, rgb.allSatisfy({ (0...255).contains($0) }) { return String(format: "#%02X%02X%02X", rgb[0], rgb[1], rgb[2]) }
        }
        return fallback
    }

    private static func geometryDefinitions(_ shape:XElement,master:XElement?) throws -> [ShapeGeometrySection] {
        let inherited = master?.children(named:"Section").filter{$0.attributes["N"] == "Geometry"} ?? [],own = shape.children(named:"Section").filter{$0.attributes["N"] == "Geometry"}
        var keys:[String] = [];for (i,s) in (inherited+own).enumerated() { let key = s.attributes["IX"] ?? String(i);if !keys.contains(key) { keys.append(key) } }
        var result:[ShapeGeometrySection] = []
        for key in keys {
            let base = inherited.first{$0.attributes["IX"] == key},local = own.first{$0.attributes["IX"] == key};if local?.attributes["Del"] == "1" || (local == nil && base?.attributes["Del"] == "1") { continue }
            guard let index = UInt32(key) else { throw DiagramError.invalid("Invalid geometry section index.") }
            var cells = base?.cells ?? [:];cells.merge(local?.cells ?? [:]){old,new in new.value == "Inh" ? old : new}
            let old = base?.children(named:"Row") ?? [],new = local?.children(named:"Row") ?? [];var rows:[ShapeGeometryRow] = [],rowKeys:[String] = []
            for (i,r) in (old+new).enumerated() { let key = r.attributes["IX"] ?? String(i);if !rowKeys.contains(key) { rowKeys.append(key) } }
            for key in rowKeys.sorted(by:{(UInt32($0) ?? 0)<(UInt32($1) ?? 0)}) {
                let original = old.first{$0.attributes["IX"] == key},override = new.first{$0.attributes["IX"] == key};if override?.attributes["Del"] == "1" || (override == nil && original?.attributes["Del"] == "1") { continue }
                guard let index = UInt32(key) else { throw DiagramError.invalid("Invalid geometry row index.") }
                var c = original?.cells ?? [:];c.merge(override?.cells ?? [:]){old,new in new.value == "Inh" ? old : new}
                rows.append(ShapeGeometryRow(index:Int(index),type:override?.attributes["T"] ?? original?.attributes["T"] ?? "",cells:c.mapValues{ShapeSheetCell(value:$0.value,formula:$0.formula,unit:$0.unit)}))
            }
            result.append(ShapeGeometrySection(index:Int(index),cells:cells.mapValues{ShapeSheetCell(value:$0.value,formula:$0.formula,unit:$0.unit)},rows:rows))
        };return result
    }
    struct GeometryIssue:Codable {
        var section:String;var row:String;var type:String;var start:DiagramPoint;var end:DiagramPoint;var cells:[String:ShapeSheetCell];var error:String
    }
    static func geometryPaths(_ definitions:[ShapeGeometrySection],width:Double,height:Double,onIssue:((GeometryIssue)->Void)? = nil) -> (paths:[VectorPath],warnings:[String]) {
        let shape = XElement(name:"Shape",attributes:[:])
        func append(_ cells:[String:ShapeSheetCell],to element:XElement) { for (key,c) in cells { element.elements.append(XElement(name:"Cell",attributes:["N":key,"V":c.value,"F":c.formula,"U":c.unit])) } }
        for definition in definitions { let section = XElement(name:"Section",attributes:["N":"Geometry","IX":String(definition.index)]);append(definition.cells,to:section)
            for definition in definition.rows { let row = XElement(name:"Row",attributes:["IX":String(definition.index),"T":definition.type]);append(definition.cells,to:row);section.elements.append(row) };shape.elements.append(section)
        }
        var warnings = Set<String>();let paths = geometry(shape,master:nil,width:width,height:height,warnings:&warnings,onIssue:onIssue);return (paths,warnings.sorted())
    }
    private static func geometry(_ shape:XElement,master:XElement?,width:Double,height:Double,warnings:inout Set<String>,onIssue:((GeometryIssue)->Void)? = nil) -> [VectorPath] {
        let inherited = master?.children(named:"Section").filter{$0.attributes["N"] == "Geometry"} ?? []
        let own = shape.children(named:"Section").filter{$0.attributes["N"] == "Geometry"}
        var keys: [String] = []
        for (i,s) in (inherited+own).enumerated() { let key = s.attributes["IX"] ?? String(i); if !keys.contains(key) { keys.append(key) } }
        var output: [VectorPath] = [],commandBudget = 100000
        for key in keys {
            guard commandBudget > 0 else { warnings.insert("Geometry path command limit exceeded; the native preview is partial.");break }
            let base = inherited.first{$0.attributes["IX"] == key},local = own.first{$0.attributes["IX"] == key}
            if local?.attributes["Del"] == "1" || (local == nil && base?.attributes["Del"] == "1") { continue }
            var sectionCells = base?.cells ?? [:]; sectionCells.merge(local?.cells ?? [:]) { old,new in new.value == "Inh" ? old : new }
            if number(sectionCells["NoShow"]) == 1 { continue }
            let oldRows = base?.children(named:"Row") ?? [],newRows = local?.children(named:"Row") ?? []
            var rowKeys: [String] = []
            for (i,row) in (oldRows+newRows).enumerated() { let key = row.attributes["IX"] ?? String(i); if !rowKeys.contains(key) { rowKeys.append(key) } }
            rowKeys.sort { (Int($0) ?? 0) < (Int($1) ?? 0) }
            var path = VectorPath(commands:[],fill:number(sectionCells["NoFill"]) != 1,stroke:number(sectionCells["NoLine"]) != 1)
            var current = CGPoint.zero, first = CGPoint.zero
            func normalized(_ p:CGPoint) -> CGPoint { CGPoint(x:(p.x-min(0,width))/abs(width),y:1-(p.y-min(0,height))/abs(height)) }
            func move(_ point:CGPoint) { guard commandBudget > 0 else { return };commandBudget -= 1;let n = normalized(point); path.commands.append(VectorCommand("M",n.x,n.y)); current = point; first = point }
            func line(_ point:CGPoint) { guard commandBudget > 0 else { return };commandBudget -= 1;let n = normalized(point); path.commands.append(VectorCommand("L",n.x,n.y)); current = point }
            func curve(_ a:CGPoint,_ b:CGPoint,_ end:CGPoint) { guard commandBudget > 0 else { return };commandBudget -= 1;let p = normalized(a),q = normalized(b),r = normalized(end); path.commands.append(VectorCommand("C",p.x,p.y,q.x,q.y,r.x,r.y)); current = end }
            var spline:[ShapeGeometryRow] = [],splineStart = CGPoint.zero,splineHasVertex = false
            func flushSpline() {
                guard !spline.isEmpty else { return };defer { spline.removeAll(keepingCapacity:true) }
                do {
                    guard splineHasVertex else { throw DiagramError.invalid("SplineStart must follow a geometry vertex.") }
                    let definition = try VisioSpline.definition(spline),segments = try VisioNURBS.cubics(definition.data,from:splineStart,to:definition.end,firstKnot:definition.firstKnot,penultimateKnot:definition.penultimateKnot,firstWeight:1,lastWeight:1,width:width,height:height)
                    for segment in segments { if hypot(current.x-segment.start.x,current.y-segment.start.y) > 1e-8 { line(segment.start) };curve(segment.a,segment.b,segment.end) }
                    if hypot(current.x-definition.end.x,current.y-definition.end.y) > 1e-8 { line(definition.end) }
                } catch {
                    let row = spline[0],end = spline.last!.cells
                    onIssue?(GeometryIssue(section:key,row:String(row.index),type:"SplineStart",start:DiagramPoint(splineStart),end:DiagramPoint(x:Double(end["X"]?.value ?? "") ?? 0,y:Double(end["Y"]?.value ?? "") ?? 0),cells:row.cells,error:error.localizedDescription))
                    warnings.insert("A spline sequence could not be rendered; its cached control polygon is shown.")
                    if path.commands.isEmpty { move(splineStart) }
                    for row in spline { line(CGPoint(x:Double(row.cells["X"]?.value ?? "") ?? 0,y:Double(row.cells["Y"]?.value ?? "") ?? 0)) }
                }
            }
            for (index,rowKey) in rowKeys.enumerated() {
                guard commandBudget > 0 else { warnings.insert("Geometry path command limit exceeded; the native preview is partial.");break }
                let old = oldRows.first{$0.attributes["IX"] == rowKey},new = newRows.first{$0.attributes["IX"] == rowKey}
                if new?.attributes["Del"] == "1" || (new == nil && old?.attributes["Del"] == "1") { continue }
                let type = new?.attributes["T"] ?? old?.attributes["T"] ?? ""
                if type != "SplineKnot" { flushSpline() }
                var c = old?.cells ?? [:]; c.merge(new?.cells ?? [:]) { old,new in new.value == "Inh" ? old : new }
                let relative = type.hasPrefix("Rel")
                func x(_ name:String) -> Double { (number(c[name]) ?? 0)*(relative ? width : 1) }
                func y(_ name:String) -> Double { (number(c[name]) ?? 0)*(relative ? height : 1) }
                let end = CGPoint(x:x("X"),y:y("Y"))
                func composite(_ key:String) throws -> CompositeGeometry {
                    func read(_ source:String,cached:Bool) throws -> CompositeGeometry { try CompositeGeometry.evaluate(source,numeric:{_ in throw DiagramError.invalid("A saved composite coordinate is unresolved.")},cached:cached) }
                    if let cached = c[key],let data = try? read(cached.value,cached:true) { return data }
                    return try read(c[key]?.formula ?? "",cached:false)
                }
                switch type {
                case "SplineStart":
                    splineStart = current;splineHasVertex = !path.commands.isEmpty
                    spline = [ShapeGeometryRow(index:Int(rowKey) ?? index,type:type,cells:c.mapValues{ShapeSheetCell(value:$0.value,formula:$0.formula,unit:$0.unit)})]
                case "SplineKnot":
                    if !spline.isEmpty { spline.append(ShapeGeometryRow(index:Int(rowKey) ?? index,type:type,cells:c.mapValues{ShapeSheetCell(value:$0.value,formula:$0.formula,unit:$0.unit)})) }
                    else {
                        onIssue?(GeometryIssue(section:key,row:rowKey,type:type,start:DiagramPoint(current),end:DiagramPoint(end),cells:c.mapValues{ShapeSheetCell(value:$0.value,formula:$0.formula,unit:$0.unit)},error:"SplineKnot has no preceding SplineStart."))
                        warnings.insert("An orphan spline knot retains its source and uses its cached coordinate.");if path.commands.isEmpty { move(current) };line(end)
                    }
                case "MoveTo","RelMoveTo": move(end)
                case "LineTo","RelLineTo": if path.commands.isEmpty { move(.zero) }; line(end)
                case "PolylineTo","PolyLineTo":
                    if path.commands.isEmpty { move(current) }
                    do { let data = try composite("A");guard data.name == "POLYLINE" else { throw DiagramError.invalid("Expected polyline data.") };for point in data.coordinates(width:width,height:height) { line(point) };line(end) }
                    catch {
                        onIssue?(GeometryIssue(section:key,row:rowKey,type:type,start:DiagramPoint(current),end:DiagramPoint(end),cells:c.mapValues{ShapeSheetCell(value:$0.value,formula:$0.formula,unit:$0.unit)},error:error.localizedDescription))
                        line(end);warnings.insert("A polyline expression could not be rendered; its cached endpoint is shown.")
                    }
                case "NURBSTo":
                    if path.commands.isEmpty { move(current) }
                    do {
                        let segments = try VisioNURBS.cubics(composite("E"),from:current,to:end,firstKnot:number(c["C"]) ?? 0,penultimateKnot:number(c["A"]) ?? 0,firstWeight:number(c["D"]) ?? 1,lastWeight:number(c["B"]) ?? 1,width:width,height:height)
                        for segment in segments { if hypot(current.x-segment.start.x,current.y-segment.start.y) > 1e-8 { line(segment.start) };curve(segment.a,segment.b,segment.end) }
                        if hypot(current.x-end.x,current.y-end.y) > 1e-8 { line(end) }
                    } catch {
                        onIssue?(GeometryIssue(section:key,row:rowKey,type:type,start:DiagramPoint(current),end:DiagramPoint(end),cells:c.mapValues{ShapeSheetCell(value:$0.value,formula:$0.formula,unit:$0.unit)},error:error.localizedDescription))
                        line(end);warnings.insert("A NURBS expression could not be rendered; its cached endpoint is shown.")
                    }
                case "CubBezTo","RelCubBezTo": curve(CGPoint(x:x("A"),y:y("B")),CGPoint(x:x("C"),y:y("D")),end)
                case "QuadBezTo","RelQuadBezTo":
                    let control = CGPoint(x:x("A"),y:y("B")),a = CGPoint(x:current.x+2*(control.x-current.x)/3,y:current.y+2*(control.y-current.y)/3),b = CGPoint(x:end.x+2*(control.x-end.x)/3,y:end.y+2*(control.y-end.y)/3); curve(a,b,end)
                case "EllipticalArcTo","RelEllipticalArcTo":
                    if let segments = VisioEllipticalArc.cubics(from:current,through:CGPoint(x:x("A"),y:y("B")),to:end,angle:number(c["C"]) ?? 0,ratio:number(c["D"]) ?? 1) {
                        for (a,b,end) in segments { curve(a,b,end) }
                    } else { line(end);warnings.insert("A degenerate elliptical arc uses its cached endpoint for the native preview.") }
                case "Ellipse":
                    let center = end,u = CGPoint(x:x("A")-end.x,y:y("B")-end.y),v = CGPoint(x:x("C")-end.x,y:y("D")-end.y)
                    func point(_ a:Double) -> CGPoint { CGPoint(x:center.x+u.x*cos(a)+v.x*sin(a),y:center.y+u.y*cos(a)+v.y*sin(a)) }
                    func tangent(_ a:Double) -> CGPoint { CGPoint(x:-u.x*sin(a)+v.x*cos(a),y:-u.y*sin(a)+v.y*cos(a)) }
                    move(point(0)); let k = 4.0/3*tan(Double.pi/8)
                    for i in 0..<4 { let a = Double(i)*Double.pi/2,b = Double(i+1)*Double.pi/2,p = point(a),q = point(b),t = tangent(a),r = tangent(b); curve(CGPoint(x:p.x+k*t.x,y:p.y+k*t.y),CGPoint(x:q.x-k*r.x,y:q.y-k*r.y),q) }
                    if commandBudget > 0 { path.commands.append(VectorCommand("Z"));commandBudget -= 1 }
                case "ArcTo":
                    // Visio's bow (A) bulges to the right of the travel direction in the shape's y-up
                    // coordinates: a Rounded Rectangle's positive bows make convex corners.
                    let sagitta = -(number(c["A"]) ?? 0),dx = end.x-current.x,dy = end.y-current.y,chord = hypot(dx,dy)
                    if abs(sagitta)<1e-10 || chord<1e-10 { line(end); continue }
                    let offset = chord*chord/(8*sagitta)-sagitta/2
                    let center = CGPoint(x:(current.x+end.x)/2+dy/chord*offset,y:(current.y+end.y)/2-dx/chord*offset)
                    let radius = hypot(current.x-center.x,current.y-center.y),start = atan2(current.y-center.y,current.x-center.x)
                    var sweep = atan2(end.y-center.y,end.x-center.x)-start
                    if sagitta > 0 { while sweep >= 0 { sweep -= 2 * .pi } } else { while sweep <= 0 { sweep += 2 * .pi } }
                    let pieces = max(1,Int(ceil(abs(sweep)/(.pi/2))))
                    for i in 0..<pieces {
                        let a = start+sweep*Double(i)/Double(pieces),b = start+sweep*Double(i+1)/Double(pieces),k = 4.0/3*tan((b-a)/4)
                        let p = CGPoint(x:center.x+radius*cos(a),y:center.y+radius*sin(a)),q = CGPoint(x:center.x+radius*cos(b),y:center.y+radius*sin(b))
                        curve(CGPoint(x:p.x-k*radius*sin(a),y:p.y+k*radius*cos(a)),CGPoint(x:q.x+k*radius*sin(b),y:q.y-k*radius*cos(b)),q)
                    }
                default:
                    if !type.isEmpty { warnings.insert("Unsupported geometry rows retain their source but have a partial native preview.") }
                    if index > 0 { line(end) }
                }
            }
            flushSpline()
            if !path.commands.isEmpty {
                if commandBudget > 0,hypot(current.x-first.x,current.y-first.y) < 1e-8 && path.commands.last?.kind != "Z" { path.commands.append(VectorCommand("Z"));commandBudget -= 1 }
                output.append(path)
            }
        }
        return output
    }

    private static func recognize(_ shape: XElement, master: MasterDefinition?, warnings: inout Set<String>) -> ShapeKind {
        let ownName = shape.attributes["NameU"] ?? ""
        if ownName.hasPrefix("MacVisio."), let kindName = ownName.split(separator: ".").dropFirst().first, let kind = ShapeKind(rawValue: String(kindName)) { return kind }
        let name = ((master?.name ?? "") + " " + ownName).lowercased()
        if name.contains("decision") || name.contains("diamond") { return .diamond }
        if name.contains("start") || name.contains("terminator") || name.contains("rounded") { return .roundedRectangle }
        if name.contains("database") || name.contains("cylinder") || name.contains("stored data") { return .cylinder }
        if name.contains("document") { return .document }
        if name.contains("parallelogram") || name.contains("data") && !name.contains("metadata") { return .parallelogram }
        if name.contains("preparation") || name.contains("hexagon") { return .hexagon }
        if name.contains("triangle") { return .triangle }
        if name.contains("cloud") { return .cloud }
        if name.contains("person") || name.contains("actor") { return .person }
        if name.contains("swimlane") || name.contains("functional band") { return .swimlane }
        let geometry = shape.children(named: "Section").filter { $0.attributes["N"] == "Geometry" }
        let inheritedGeometry = master?.shape.children(named: "Section").filter { $0.attributes["N"] == "Geometry" } ?? []
        let sections = geometry.isEmpty ? inheritedGeometry : geometry
        let rows = sections.flatMap { $0.children(named: "Row") }
        if rows.contains(where: { $0.attributes["T"] == "Ellipse" }) || name.contains("ellipse") || name.contains("circle") { return .ellipse }
        if sections.isEmpty && shape.child("Text") != nil { return .text }
        if !rows.isEmpty {
            let straight = rows.allSatisfy { ["MoveTo", "LineTo", "RelMoveTo", "RelLineTo"].contains($0.attributes["T"] ?? "") }
            let points = rows.compactMap { row -> CGPoint? in
                guard let x = number(row.cells["X"]), let y = number(row.cells["Y"]) else { return nil }
                return CGPoint(x: x, y: y)
            }
            if straight && points.count == 5 {
                let uniqueX = Set(points.map { $0.x }), uniqueY = Set(points.map { $0.y })
                if uniqueX.count == 2 && uniqueY.count == 2 { return .rectangle }
                if uniqueX.count == 3 && uniqueY.count == 3 { return .diamond }
            }
        }
        if name.contains("process") || name.contains("rectangle") || name.contains("square") { return .rectangle }
        if rows.isEmpty { warnings.insert("A shape without supported geometry is shown as a rectangle; its source is preserved.") }
        return .rectangle
    }

    private static func cell(_ name: String, _ value: Double, formula: String? = nil) -> String {
        "<Cell N=\"\(name)\" V=\"\(format(value))\"\(formula.map { " F=\"\(xml($0))\"" } ?? "")/>"
    }
    private static func stringCell(_ name: String, _ value: String) -> String { "<Cell N=\"\(name)\" V=\"\(xml(value))\"/>" }
    private static func format(_ value: Double) -> String { String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), value) }
    private static func xml(_ value: String) -> String {
        String(value.unicodeScalars.filter { $0.value == 9 || $0.value == 10 || $0.value == 13 || $0.value >= 32 && $0.value != 0xFFFE && $0.value != 0xFFFF }).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&apos;")
    }

    static func shapeXML(_ node: DiagramNode, id: Int, pageHeight: Double,paperScale:Double = 1) -> String {
        let w = node.sheetWidth / 72, h = node.sheetHeight / 72
        let invisibleFill = node.fill.count == 9 && node.fill.hasSuffix("00") || node.kind == .text
        let invisibleStroke = node.stroke.count == 9 && node.stroke.hasSuffix("00") || node.kind == .text
        let values = ShapeSheetEngine.defaults(node,page:DiagramPage(height:pageHeight))
        var contents = cell("PinX", values["PinX"]!) + cell("PinY",values["PinY"]!)
        contents += cell("Width", w) + cell("Height", h) + cell("LocPinX", w / 2, formula: "Width*0.5") + cell("LocPinY", h / 2, formula: "Height*0.5") + cell("Angle", -node.rotation * .pi / 180)
        contents += cell("LineWeight", node.strokeWidth / 72) + stringCell("LineColor", String(node.stroke.prefix(7))) + cell("LinePattern",invisibleStroke ? 0 : Double(node.formatting.linePattern))
        contents += stringCell("FillForegnd", String(node.fill.prefix(7))) + cell("FillPattern", invisibleFill ? 0 : 1) + cell("VerticalAlign",Double(node.formatting.textBox?.verticalAlignment ?? 1))
        if let alpha = alpha(node.fill) { contents += cell("FillForegndTrans", 1 - alpha) }
        if let alpha = alpha(node.stroke) { contents += cell("LineColorTrans", 1 - alpha) }
        contents += cell("LockMoveX", node.locked ? 1 : 0) + cell("LockMoveY", node.locked ? 1 : 0)
        var textWidth = max(1 / 72, abs(w) - 20 / (72*paperScale)), textHeight = max(1 / 72, abs(h) - 16 / (72*paperScale))
        var textX = w / 2, textY = h / 2
        if node.kind == .diamond { textWidth = w * 0.56; textHeight = h * 0.56 }
        if node.kind == .triangle { textHeight *= 0.7; textY -= (h - 16 / (72*paperScale)) * 0.15 }
        if node.kind == .person { textWidth = abs(w) + 60 / (72*paperScale); textHeight = 40 / (72*paperScale); textY = -25 / (72*paperScale) }
        if node.kind == .swimlane { textWidth = 94 / (72*paperScale); textHeight = max(1 / 72, abs(h) - 20 / (72*paperScale)); textX = 55 / (72*paperScale) }
        if let box = node.formatting.textBox { textWidth = box.width*abs(w);textHeight = box.height*abs(h);textX = box.centerX*abs(w)+min(0,w);textY = (1-box.centerY)*abs(h)+min(0,h) }
        contents += cell("TxtPinX", textX) + cell("TxtPinY", textY) + cell("TxtWidth", textWidth) + cell("TxtHeight", textHeight) + cell("TxtLocPinX", textWidth / 2) + cell("TxtLocPinY", textHeight / 2)
        contents += cell("LeftMargin",(node.formatting.textBox?.left ?? 0)/72)+cell("RightMargin",(node.formatting.textBox?.right ?? 0)/72)+cell("TopMargin",(node.formatting.textBox?.top ?? 0)/72)+cell("BottomMargin",(node.formatting.textBox?.bottom ?? 0)/72)
        if let box = node.formatting.textBox { contents += cell("TxtAngle",-box.rotation * .pi/180) }
        let font = node.formatting.fontName == "System" ? "Arial" : node.formatting.fontName
        let textStyle = (node.bold ? 1 : 0) | (node.formatting.italic ? 2 : 0) | (node.formatting.underline ? 4 : 0)
        contents += "<Section N=\"Character\"><Row IX=\"0\">" + cell("Font",0,formula:"FONT(\"\(font)\")") + stringCell("Color", String(node.textColor.prefix(7))) + cell("Size", node.fontSize / 72) + cell("Style",Double(textStyle)) + "</Row></Section><Section N=\"Paragraph\"><Row IX=\"0\">" + cell("HorzAlign",node.formatting.alignment == .left ? 0 : node.formatting.alignment == .right ? 2 : 1) + "</Row></Section>"
        contents += cell("FlipX",node.formatting.flipX ? 1 : 0) + cell("FlipY",node.formatting.flipY ? 1 : 0)
        if !node.formatting.paths.isEmpty {
            let paths = node.formatting.paths.map { path -> VectorPath in var path = path;for i in path.commands.indices { for j in path.commands[i].values.indices { if j.isMultiple(of:2) ? w < 0 : h < 0 { path.commands[i].values[j] = 1-path.commands[i].values[j] } } };return path }
            contents += customGeometry(paths)
        }
        else if !node.formatting.isGroup && node.formatting.image == nil { contents += shapeGeometry(node.kind, width: w, height: h) }
        if node.kind == .swimlane {
            let headerFraction = min(110 / node.width, 1)
            contents += geometrySection(index: 1, rows: [("RelMoveTo", ["X": headerFraction, "Y": 0]), ("RelLineTo", ["X": headerFraction, "Y": 1])], noFill: true)
        }
        contents += "<Text>\(xml(node.text))</Text>"
        let type = node.formatting.isGroup ? "Group" : node.formatting.image != nil ? "Foreign" : "Shape"
        let result = "<Shape ID=\"\(id)\" NameU=\"MacVisio.\(node.kind.rawValue).\(id)\" Name=\"\(xml(node.kind.title)).\(id)\" Type=\"\(type)\" LineStyle=\"0\" FillStyle=\"0\" TextStyle=\"0\">\(contents)</Shape>"
        if !node.formatting.data.isEmpty || !node.formatting.hyperlinks.isEmpty || !node.formatting.sheet.isEmpty || !node.formatting.connectionPoints.isEmpty || !node.formatting.controls.isEmpty || node.formatting.textRuns != nil || node.formatting.geometry != nil,let element = try? VisioXML.element(result) {
            VisioPreservation.patchData(node.formatting.data,element:element);VisioPreservation.patchHyperlinks(node.formatting.hyperlinks,element:element)
            if !node.formatting.connectionPoints.isEmpty { VisioPreservation.patchConnectionPoints(ConnectionGeometry.cached(node.formatting.connectionPoints,on:node),element:element) }
            let managed:Set<String> = ["FillForegnd","FillPattern","FillForegndTrans","LineColor","LinePattern","LineColorTrans","LockMoveX","LockMoveY","FlipX","FlipY"]
            var sheet = node.formatting.sheet
            let values = ShapeSheetEngine.defaults(node,page:DiagramPage(height:pageHeight))
            for key in ShapeSheetEngine.geometryKeys where sheet[key] != nil { if let value = values[key] { sheet[key]?.value = format(value) } }
            VisioPreservation.patchSheet(sheet.filter{!managed.contains($0.key)},old:[:],element:element)
            if node.formatting.textRuns != nil { ShapeRichText.patch(node,element:element,fresh:true) }
            if let fields = node.formatting.textFields { TextFieldEngine.patch(fields,element:element) }
            if let geometry = node.formatting.geometry {
                for section in element.elementsLocal("Section") where section.attr("N") == "Geometry" { section.detach() }
                GeometrySheet.patch(geometry.isEmpty ? [ShapeGeometrySection(index:0,cells:["NoShow":ShapeSheetCell(value:"1")],rows:[])] : geometry,element:element)
            }
            if !node.formatting.controls.isEmpty { ControlGeometry.patch(node.formatting.controls,on:element) };return element.xmlString
        }
        return result
    }

    private static func customGeometry(_ paths:[VectorPath]) -> String {
        paths.enumerated().map { index,path in
            var rows: [(String,[String:Double])] = [], first = CGPoint.zero, current = CGPoint.zero
            for command in path.commands {
                let v = command.values
                switch command.kind {
                case "M": first = CGPoint(x:v[0],y:v[1]); current = first; rows.append(("RelMoveTo",["X":v[0],"Y":1-v[1]]))
                case "L": current = CGPoint(x:v[0],y:v[1]); rows.append(("RelLineTo",["X":v[0],"Y":1-v[1]]))
                case "C": current = CGPoint(x:v[4],y:v[5]); rows.append(("RelCubBezTo",["X":v[4],"Y":1-v[5],"A":v[0],"B":1-v[1],"C":v[2],"D":1-v[3]]))
                case "Q":
                    let c1 = CGPoint(x:current.x+2*(v[0]-current.x)/3,y:current.y+2*(v[1]-current.y)/3)
                    let c2 = CGPoint(x:v[2]+2*(v[0]-v[2])/3,y:v[3]+2*(v[1]-v[3])/3)
                    current = CGPoint(x:v[2],y:v[3]); rows.append(("RelCubBezTo",["X":v[2],"Y":1-v[3],"A":c1.x,"B":1-c1.y,"C":c2.x,"D":1-c2.y]))
                case "Z": current = first; rows.append(("RelLineTo",["X":first.x,"Y":1-first.y]))
                default: break
                }
            }
            var xml = geometrySection(index:index,rows:rows,noFill:!path.fill)
            if !path.stroke { xml = xml.replacingOccurrences(of:cell("NoLine",0),with:cell("NoLine",1)) }
            return xml
        }.joined()
    }

    private static func geometrySection(index: Int = 0, rows: [(String, [String: Double])], noFill: Bool = false) -> String {
        var xml = "<Section N=\"Geometry\" IX=\"\(index)\">" + cell("NoFill", noFill ? 1 : 0) + cell("NoLine", 0) + cell("NoShow", 0)
        for (index, row) in rows.enumerated() {
            xml += "<Row T=\"\(row.0)\" IX=\"\(index + 1)\">" + row.1.keys.sorted().map { cell($0, row.1[$0]!) }.joined() + "</Row>"
        }
        return xml + "</Section>"
    }
    private static func alpha(_ color: String) -> Double? {
        guard color.count == 9, color.hasPrefix("#"), let value = UInt8(color.suffix(2), radix: 16) else { return nil }
        return Double(value) / 255
    }
    private static func withTransparency(_ color: String, value: Double?) -> String {
        guard let value, value > 0 else { return color }
        return color + String(format: "%02X", Int(((1 - min(value, 1)) * 255).rounded()))
    }
    private static func shapeGeometry(_ kind: ShapeKind, width: Double, height: Double) -> String {
        func polygon(_ points: [(Double, Double)]) -> String {
            geometrySection(rows: points.enumerated().map { ($0.offset == 0 ? "RelMoveTo" : "RelLineTo", ["X": $0.element.0, "Y": $0.element.1]) })
        }
        func move(_ x: Double, _ y: Double) -> (String, [String: Double]) { ("RelMoveTo", ["X": x, "Y": y]) }
        func line(_ x: Double, _ y: Double) -> (String, [String: Double]) { ("RelLineTo", ["X": x, "Y": y]) }
        func curve(_ x: Double, _ y: Double, _ a: Double, _ b: Double, _ c: Double, _ d: Double) -> (String, [String: Double]) { ("RelCubBezTo", ["X": x, "Y": y, "A": a, "B": b, "C": c, "D": d]) }
        switch kind {
        case .ellipse:
            return geometrySection(rows: [("Ellipse", ["X": width / 2, "Y": height / 2, "A": width, "B": height / 2, "C": width / 2, "D": height])])
        case .diamond: return polygon([(0.5,0),(1,0.5),(0.5,1),(0,0.5),(0.5,0)])
        case .parallelogram: return polygon([(0,0),(0.84,0),(1,1),(0.16,1),(0,0)])
        case .triangle: return polygon([(0,0),(1,0),(0.5,1),(0,0)])
        case .hexagon: return polygon([(0.17,0),(0.83,0),(1,0.5),(0.83,1),(0.17,1),(0,0.5),(0.17,0)])
        case .roundedRectangle:
            let radius = min(width / 2, height / 2, 22.0 / 72), rx = radius / width, ry = radius / height, k = 0.552284749831
            return geometrySection(rows: [move(rx,0),line(1-rx,0),curve(1,ry,1-rx+k*rx,0,1,ry-k*ry),line(1,1-ry),curve(1-rx,1,1,1-ry+k*ry,1-rx+k*rx,1),line(rx,1),curve(0,1-ry,rx-k*rx,1,0,1-ry+k*ry),line(0,ry),curve(rx,0,0,ry-k*ry,rx-k*rx,0)])
        case .document:
            return geometrySection(rows: [move(0,1),line(1,1),line(1,0.16),curve(0,0.1,0.7,0.35,0.3,-0.14),line(0,1)])
        case .cylinder:
            return geometrySection(rows: [move(0,0.87),curve(1,0.87,0,1.045,1,1.045),line(1,0.13),curve(0,0.13,1,-0.045,0,-0.045),line(0,0.87)]) + geometrySection(index: 1, rows: [("Ellipse", ["X": width / 2, "Y": height * 0.87, "A": width, "B": height * 0.87, "C": width / 2, "D": height])], noFill: true)
        case .cloud:
            return geometrySection(rows: [move(0.18,0.2),curve(0.1,0.66,-0.07,0.2,-0.02,0.65),curve(0.43,0.82,0.06,0.97,0.3,1.04),curve(0.82,0.75,0.6,1.06,0.85,0.97),curve(0.84,0.17,1.1,0.8,1.1,0.12),curve(0.18,0.2,0.62,-0.05,0.35,0.02)])
        case .person:
            let head = geometrySection(rows: [("Ellipse", ["X": width / 2, "Y": height * 0.875, "A": width * 0.68, "B": height * 0.875, "C": width / 2, "D": height])])
            return head + geometrySection(index: 1, rows: [move(0.5,0.73),line(0.5,0.35),move(0.12,0.54),line(0.88,0.54),move(0.5,0.35),line(0.15,0),move(0.5,0.35),line(0.85,0)], noFill: true)
        default: return polygon([(0,0),(1,0),(1,1),(0,1),(0,0)])
        }
    }

    static func connectorXML(_ edge: DiagramEdge, id: Int, page: DiagramPage, sourceID: Int?, targetID: Int?,sourceCells:(String,String) = ("PinX","PinY"),targetCells:(String,String) = ("PinX","PinY")) -> String {
        let points = DiagramGeometry.route(edge, in: page).map { CGPoint(x: $0.x / 72, y: (page.height - $0.y) / 72) }
        guard let begin = points.first, let end = points.last else { return "" }
        // Keep local geometry axis aligned while endpoint cells carry the page positions.
        let originX = points.map(\.x).min()!, originY = points.map(\.y).min()!
        let w = max(0.001, points.map(\.x).max()! - originX), h = max(0.001, points.map(\.y).max()! - originY)
        var contents = cell("ObjType", 2) + cell("PinX", originX + w / 2) + cell("PinY", originY + h / 2) + cell("Width", w) + cell("Height", h) + cell("LocPinX", w / 2) + cell("LocPinY", h / 2) + cell("Angle", 0)
        // Visio registers glue only through these formulas: whole-shape (dynamic) glue walks with
        // _WALKGLUE, point glue follows the connection point, and both need a trigger on the target's
        // EventXFMod. Without the triggers Visio treats the endpoints as unglued and drops the Connects.
        func endpoint(_ sheet: Int?, cells: (String, String), trigger: String, other: String) -> (x: String?, y: String?, trigger: String?) {
            guard let sheet else { return (nil, nil, nil) }
            let follow = cells == ("PinX", "PinY") ? "_WALKGLUE(\(trigger),\(other),WalkPreference)"
                : "PAR(PNT(Sheet.\(sheet)!\(cells.0),Sheet.\(sheet)!\(cells.1)))"
            return (follow, follow, "_XFTRIGGER(Sheet.\(sheet)!EventXFMod)")
        }
        let start = endpoint(sourceID, cells: sourceCells, trigger: "BegTrigger", other: "EndTrigger")
        let finish = endpoint(targetID, cells: targetCells, trigger: "EndTrigger", other: "BegTrigger")
        contents += cell("BeginX", begin.x, formula: start.x) + cell("BeginY", begin.y, formula: start.y)
            + cell("EndX", end.x, formula: finish.x) + cell("EndY", end.y, formula: finish.y)
        if let trigger = start.trigger { contents += cell("BegTrigger", 2, formula: trigger) }
        if let trigger = finish.trigger { contents += cell("EndTrigger", 2, formula: trigger) }
        contents += cell("LineWeight", edge.width / 72) + stringCell("LineColor", String(edge.color.prefix(7))) + cell("LinePattern", Double(edge.dash ?? 1)) + cell("FillPattern", 0) + cell("BeginArrow", edge.startArrow == true ? 4 : 0) + cell("BeginArrowSize", 2) + cell("EndArrow", edge.arrow ? 4 : 0) + cell("EndArrowSize", 2) + cell("ShapeRouteStyle", edge.style == .orthogonal ? 1 : 2)
        contents += "<Section N=\"Character\"><Row IX=\"0\">" + stringCell("Font", "Arial") + cell("Size", 12 / 72) + stringCell("Color", String(edge.color.prefix(7))) + "</Row></Section><Section N=\"Paragraph\"><Row IX=\"0\">" + cell("HorzAlign", 1) + "</Row></Section>"
        contents += geometrySection(rows: points.enumerated().map { ($0.offset == 0 ? "MoveTo" : "LineTo", ["X": $0.element.x - originX, "Y": $0.element.y - originY]) }, noFill: true)
        contents += "<Text>\(xml(edge.label))</Text>"
        let result = "<Shape ID=\"\(id)\" NameU=\"MacVisio.Connector.\(id)\" Type=\"Shape\" LineStyle=\"0\" FillStyle=\"0\" TextStyle=\"0\">\(contents)</Shape>"
        guard edge.details != nil,let element = try? VisioXML.element(result) else { return result }
        VisioPreservation.patchData(edge.formatting.data,element:element)
        VisioPreservation.patchHyperlinks(edge.formatting.hyperlinks,element:element)
        // A fresh route owns its geometry. Supported line formulas retain their
        // public authored cells as well as their calculated presentation.
        let managed:Set<String> = ["ObjType","PinX","PinY","Width","Height","LocPinX","LocPinY","Angle","BeginX","BeginY","EndX","EndY","ShapeRouteStyle","LineWeight","LineColor","LinePattern","BeginArrow","EndArrow","FillPattern"]
        VisioPreservation.patchSheet(edge.formatting.sheet.filter { key, cell in
            if !managed.contains(key) { return true }
            let formula = cell.formula.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return ConnectorSheetCalculation.lineKeys.contains(key) && !formula.isEmpty && !["INH", "NO FORMULA"].contains(formula)
        },old:[:],element:element)
        if edge.formatting.textRuns != nil { ShapeRichText.patch(edge.textNode,element:element,fresh:true) }
        else {
            let character = VisioXML.row(element,"Character")
            VisioXML.set(character,"Font",edge.formatting.fontName == "System" ? "Arial" : edge.formatting.fontName)
            VisioXML.set(character,"Style",(edge.formatting.italic ? 2 : 0)+(edge.formatting.underline ? 4 : 0))
            VisioXML.set(VisioXML.row(element,"Paragraph"),"HorzAlign",edge.formatting.alignment == .left ? 0 : edge.formatting.alignment == .right ? 2 : 1)
        }
        if let fields = edge.formatting.textFields { TextFieldEngine.patch(fields,element:element) }
        return element.xmlString
    }

    /// stdout is read in chunks with a hard cap; no archive entry is ever extracted.
    private static func run(_ executable: String, arguments: [String], directory: URL? = nil, limit: Int) throws -> Data {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.currentDirectoryURL = directory; process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        defer { timeout.cancel(); try? output.fileHandleForReading.close() }
        var data = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
            guard data.count + chunk.count <= limit else {
                process.terminate(); try? output.fileHandleForReading.close(); process.waitUntilExit()
                throw DiagramError.invalid("A VSDX package part exceeds the safe size limit.")
            }
            data.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DiagramError.invalid("The Visio archive is damaged, encrypted, or could not be processed.") }
        return data
    }

    private final class PackageReader {
        static let partLimit = VisioPackage.partLimit
        static let totalLimit = VisioPackage.totalLimit
        let parts: [String: Data]
        var names: Set<String> { Set(parts.keys) }
        init(url: URL) throws { parts = try VisioPackage.read(url) }
        init(parts: [String: Data]) throws {
            guard parts.count <= 10000, parts.values.allSatisfy({ $0.count <= Self.partLimit }),
                  parts.values.reduce(0, { $0 + $1.count }) <= Self.totalLimit else {
                throw DiagramError.invalid("The public definition package exceeds its resource limits.")
            }
            for name in parts.keys { try VisioPackage.validatePath(name) }
            self.parts = parts
        }
        func data(_ name: String) throws -> Data {
            guard let data = parts[name] else { throw DiagramError.invalid("The Visio package is missing \(name).") }
            return data
        }
        func xml(_ name: String, expectedRoot: String) throws -> XElement {
            let data = try data(name)
            guard let text = String(data: data, encoding: .utf8), !text.localizedCaseInsensitiveContains("<!DOCTYPE"), !text.localizedCaseInsensitiveContains("<!ENTITY") else { throw DiagramError.invalid("Only UTF-8 XML without DTDs or entity declarations is supported.") }
            let builder = XMLTreeBuilder(), parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false; parser.delegate = builder
            guard parser.parse(), let root = builder.root, root.name == expectedRoot else { throw DiagramError.invalid("Invalid \(expectedRoot) XML in \(name).") }
            return root
        }
    }

    private struct XCell { let value: String; let formula: String;var unit:String = "" }
    private struct XTextRun { var text:String;var character:Int;var paragraph:Int;var field:Int? = nil }
    private final class XElement {
        let name: String
        let attributes: [String: String]
        var elements: [XElement] = [] {
            didSet { cachedCells = nil;childrenByName = nil }
        }
        // XML is queried repeatedly during master expansion. Synthetic element edits
        // invalidate these indexes through elements.didSet.
        private var cachedCells:[String:XCell]?
        private var childrenByName:[String:[XElement]]?
        // Ordered text includes nested cp/pp/fld runs without losing whitespace.
        var textFragments: [String] = []
        var runs:[XTextRun] = []
        var characterIndex = 0
        var paragraphIndex = 0
        var fieldIndex:Int?
        init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }
        func children(named name: String) -> [XElement] {
            if childrenByName == nil {
                var index:[String:[XElement]] = [:]
                for element in elements { index[element.name,default:[]].append(element) }
                childrenByName = index
            }
            return childrenByName?[name] ?? []
        }
        func child(_ name: String) -> XElement? { children(named:name).first }
        func attribute(local: String) -> String? { attributes.first { $0.key.split(separator: ":").last.map(String.init) == local }?.value }
        var allText: String { textFragments.joined() }
        /// Shape text without the terminal paragraph mark Visio writes after the last paragraph
        /// (CR LF, which XML parsing reads as LF). Visio's own Text property excludes it.
        var shapeText: String { ShapeRichText.droppingTerminalMark(allText) }
        var cells: [String: XCell] {
            if let cachedCells { return cachedCells }
            var values: [String: XCell] = [:]
            for cell in children(named: "Cell") {
                if let name = cell.attributes["N"], let value = cell.attributes["V"] { values[name] = XCell(value: value, formula: cell.attributes["F"] ?? "",unit:cell.attributes["U"] ?? "") }
            }
            cachedCells = values
            return values
        }
    }
    private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
        var root: XElement?
        private var stack: [XElement] = []
        private var count = 0
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            count += 1
            guard count <= 500000, stack.count < 100 else { parser.abortParsing(); return }
            let element = XElement(name: elementName.split(separator: ":").last.map(String.init) ?? elementName, attributes: attributeDict)
            if let text = stack.last(where:{$0.name == "Text"}) {
                if element.name == "cp" { text.characterIndex = Int(attributeDict["IX"] ?? "0") ?? -1 }
                if element.name == "pp" { text.paragraphIndex = Int(attributeDict["IX"] ?? "0") ?? -1 }
                if element.name == "fld" { text.fieldIndex = Int(attributeDict["IX"] ?? "0") ?? -1;text.runs.append(XTextRun(text:"",character:text.characterIndex,paragraph:text.paragraphIndex,field:text.fieldIndex)) }
            }
            if let parent = stack.last { parent.elements.append(element) } else { root = element }
            stack.append(element)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { for element in stack where element.name == "Text" {
            element.textFragments.append(string)
            if let last = element.runs.last,last.character == element.characterIndex,last.paragraph == element.paragraphIndex,last.field == element.fieldIndex { element.runs[element.runs.count-1].text += string }
            else { element.runs.append(XTextRun(text:string,character:element.characterIndex,paragraph:element.paragraphIndex,field:element.fieldIndex)) }
        } }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { if let string = String(data: CDATABlock, encoding: .utf8) { self.parser(parser, foundCharacters: string) } }
        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if elementName.split(separator:":").last == "fld" { stack.last(where:{$0.name == "Text"})?.fieldIndex = nil }
            if !stack.isEmpty { stack.removeLast() }
        }
        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
    }
}
