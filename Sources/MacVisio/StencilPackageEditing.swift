import Foundation
import MacVisioInfrastructure

struct StencilPackageCell: Equatable {
    var shapeID: String
    var address: DefinitionCellAddress
    var value: ShapeSheetCell
    var refusal: String?
    var title: String {
        (["Sheet.\(shapeID)", address.section, address.rowName ?? address.rowIndex, address.cell].compactMap { $0 }).joined(separator: ".")
    }
}

struct StencilPackageMaster: Equatable, Identifiable {
    var id: UInt32
    var sourceID: String
    var part: String
    var relationshipID: String
    var name: String
    var universalName: String
    var baseID: String?
    var uniqueID: String?
    var cells: [StencilPackageCell]
}

/// An imported package is the authority. Masters are projections for inspection;
/// saves retain every original part, including parts no longer in the master list.
struct StencilPackageSnapshot: Equatable {
    fileprivate let store: StencilPackageParts
    let sourceURL: URL
    let lineageID: UUID
    let documentPart: String
    let mastersPart: String
    let masters: [StencilPackageMaster]
    fileprivate let reservedIDs: Set<UInt32>
    var parts: [String: Data] { store.parts }
    var resourceID: UUID { store.id }
    var byteCount: Int { store.byteCount }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.store === rhs.store || (lhs.sourceURL == rhs.sourceURL && lhs.lineageID == rhs.lineageID
            && lhs.reservedIDs == rhs.reservedIDs && lhs.parts == rhs.parts)
    }
}

fileprivate final class StencilPackageParts {
    let id = UUID()
    let parts: [String: Data]
    let byteCount: Int
    init(_ parts: [String: Data]) { self.parts = parts; byteCount = parts.values.reduce(0) { $0 + $1.count } }
}

enum StencilPackageEdit {
    case rename(masterID: UInt32, name: String)
    case duplicate(masterID: UInt32, name: String)
    case move(masterID: UInt32, toIndex: Int)
    case delete(masterID: UInt32)
    case literal(masterID: UInt32, shapeID: String, address: DefinitionCellAddress, expected: ShapeSheetCell, value: String)
}

enum StencilPackageEditing {
    static let namespace = "http://schemas.microsoft.com/office/visio/2012/main"
    static let maximumCells = 100_000
    static let maximumShapes = 20_000
    private static let relationship = VisioReusableFormat.relationship
    private static let relationNamespace = "http://schemas.openxmlformats.org/package/2006/relationships"
    private static let referenceNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

    static func read(from url: URL) throws -> StencilPackageSnapshot {
        guard url.isFileURL, url.pathExtension.lowercased() == "vssx" else {
            throw DiagramError.invalid("Choose a public .vssx stencil. Binary VSS editing is unavailable.")
        }
        return try snapshot(parts: VisioPackage.read(url), sourceURL: url)
    }

    static func snapshot(parts: [String: Data], sourceURL: URL, lineageID: UUID = UUID(),
                         reservedIDs: Set<UInt32> = []) throws -> StencilPackageSnapshot {
        try checkpoint()
        guard sourceURL.isFileURL, sourceURL.pathExtension.lowercased() == "vssx" else {
            throw DiagramError.invalid("The source stencil must be a local .vssx file.")
        }
        guard parts.count <= 10_000, parts.values.allSatisfy({ $0.count <= VisioPackage.partLimit }),
              parts.values.reduce(0, { $0 + $1.count }) <= VisioPackage.totalLimit else {
            throw DiagramError.invalid("This stencil exceeds the supported package budget.")
        }
        for name in parts.keys { try checkpoint(); try VisioPackage.validatePath(name) }
        let topRelations = try relationships("_rels/.rels", in: parts).filter { $0.attr("Type") == relationship + "document" }
        guard topRelations.count == 1, let topRelation = topRelations.first, topRelation.attr("TargetMode") != "External",
              let documentTarget = topRelation.attr("Target") else { throw DiagramError.invalid("The package document ownership is ambiguous.") }
        let documentPart = try VisioFormat.resolve(documentTarget, relativeTo: "")
        let types = try xml("[Content_Types].xml", in: parts)
        let typeNamespace = "http://schemas.openxmlformats.org/package/2006/content-types"
        guard let typeRoot = types.rootElement(), typeRoot.localTag == "Types", typeRoot.uri == typeNamespace else {
            throw DiagramError.invalid("The package content type owner is invalid.")
        }
        var overrides: [String: String] = [:]
        for entry in typeRoot.elementsLocal("Override") where entry.uri == typeNamespace {
            try checkpoint()
            guard let name = entry.attr("PartName"), name.hasPrefix("/"), let type = entry.attr("ContentType") else {
                throw DiagramError.invalid("A package content type identity is invalid.")
            }
            let part = try VisioFormat.resolve(name, relativeTo: "").lowercased()
            guard overrides.updateValue(type, forKey: part) == nil else { throw DiagramError.invalid("The package has ambiguous content type identities.") }
        }
        guard overrides[documentPart.lowercased()] == "application/vnd.ms-visio.stencil.main+xml" else {
            throw DiagramError.invalid("This package is not a public VSSX stencil.")
        }
        let docRelations = try relationships(VisioXML.relationshipPart(documentPart), in: parts)
        let masterRelations = docRelations.filter { $0.attr("Type") == relationship + "masters" }
        guard masterRelations.count == 1, let masterRelation = masterRelations.first,
              masterRelation.attr("TargetMode") != "External", let target = masterRelation.attr("Target") else {
            throw DiagramError.invalid("The stencil has an ambiguous or missing master index.")
        }
        let mastersPart = try VisioFormat.resolve(target, relativeTo: documentPart)
        guard overrides[mastersPart.lowercased()] == "application/vnd.ms-visio.masters+xml" else {
            throw DiagramError.invalid("The master index content type is missing or ambiguous.")
        }
        let index = try xml(mastersPart, in: parts)
        guard let root = index.rootElement(), root.localTag == "Masters", root.uri == namespace else {
            throw DiagramError.invalid("The stencil master index has an unsupported owner.")
        }
        let relations = try relationships(VisioXML.relationshipPart(mastersPart), in: parts)
        let relationByID = Dictionary(uniqueKeysWithValues: relations.map { ($0.attr("Id")!, $0) })
        let document = try xml(documentPart, in: parts)
        var styles: [String: XMLElement] = [:]
        guard let documentRoot = document.rootElement(), documentRoot.localTag == "VisioDocument", documentRoot.uri == namespace else {
            throw DiagramError.invalid("The public stencil document has an unsupported namespace.")
        }
        let styleOwners = core(documentRoot, "StyleSheets")
        guard styleOwners.count <= 1 else { throw DiagramError.invalid("The public style owner is ambiguous.") }
        for style in styleOwners.first.map({ core($0, "StyleSheet") }) ?? [] {
            guard let raw = style.attr("ID"), let id = UInt32(raw), styles.updateValue(style, forKey: String(id)) == nil else {
                throw DiagramError.invalid("The public style identities are invalid or ambiguous.")
            }
        }
        let elements = core(root, "Master")
        var sourceReserved = Set<UInt32>(), shortcutIDs = Set<UInt32>()
        for shortcut in core(root, "MasterShortcut") {
            guard let raw = shortcut.attr("ID"), let id = UInt32(raw), shortcutIDs.insert(id).inserted else {
                throw DiagramError.invalid("The stencil shortcut identities are invalid or ambiguous.")
            }
            sourceReserved.insert(id)
            if let source = shortcut.attr("SourceMaster") {
                guard let id = UInt32(source) else { throw DiagramError.invalid("The shortcut source identity cannot be proven safe for allocation.") }; sourceReserved.insert(id)
            }
        }
        guard !elements.isEmpty, elements.count <= 1000 else { throw DiagramError.invalid("A custom stencil needs 1–1000 masters.") }
        var masters: [StencilPackageMaster] = [], ids = Set<UInt32>(), cellCount = 0, shapeCount = 0
        for element in elements {
            try checkpoint()
            guard let sourceID = element.attr("ID"), let id = UInt32(sourceID), ids.insert(id).inserted, !shortcutIDs.contains(id),
                  let rid = relationID(element), let relation = relationByID[rid],
                  relation.attr("Type") == relationship + "master", relation.attr("TargetMode") != "External",
                  let target = relation.attr("Target") else { throw DiagramError.invalid("The stencil has an invalid or ambiguous master identity.") }
            let part = try VisioFormat.resolve(target, relativeTo: mastersPart)
            guard overrides[part.lowercased()] == "application/vnd.ms-visio.master+xml" else {
                throw DiagramError.invalid("A master content type is missing or ambiguous.")
            }
            let contents = try xml(part, in: parts)
            guard let contentRoot = contents.rootElement(), contentRoot.localTag == "MasterContents", contentRoot.uri == namespace else {
                throw DiagramError.invalid("A master content part has an unsupported owner.")
            }
            var cells: [StencilPackageCell] = [], shapeIDs = Set<UInt32>()
            var stack = (core(contentRoot, "Shapes").first.map { core($0, "Shape") } ?? []).reversed().map { ($0, false) }
            while let (shape, inheritedParent) = stack.popLast() {
                if shapeCount % 128 == 0 { try checkpoint() }; shapeCount += 1
                guard shapeCount <= maximumShapes else { throw DiagramError.invalid("The custom stencil editor supports up to 20,000 source shapes.") }
                if ["1", "true"].contains(shape.attr("Del") ?? "") { continue }
                guard let shapeID = shape.attr("ID"), let numeric = UInt32(shapeID), shapeIDs.insert(numeric).inserted else {
                    throw DiagramError.invalid("A master has duplicate or invalid source shape identities.")
                }
                let inherited = inheritedParent || shape.attr("Master") != nil || shape.attr("MasterShape") != nil
                let sourceCells = try publicCells(shape)
                var addresses = Set<DefinitionCellAddress>()
                for (address, value, deleted) in sourceCells {
                    let cell = DefinitionCell(id: UUID(), address: address, value: value)
                    if cellCount % 128 == 0 { try checkpoint() }; cellCount += 1
                    guard cellCount <= maximumCells, addresses.insert(cell.address).inserted else {
                        throw DiagramError.invalid("This stencil has ambiguous cells or exceeds the 100,000-cell editing budget.")
                    }
                    var refusal = literalRefusal(cell.value)
                    if inherited { refusal = "This shape inherits from a master; its cell ownership is not proven for literal editing." }
                    if deleted { refusal = "Deleted source rows cannot be edited here." }
                    if refusal == nil { refusal = try styleRefusal(cell.address, on: shape, styles: styles) }
                    cells.append(StencilPackageCell(shapeID: shapeID, address: cell.address, value: cell.value, refusal: refusal))
                }
                for child in (core(shape, "Shapes").first.map { core($0, "Shape") } ?? []).reversed() { stack.append((child, inherited)) }
            }
            masters.append(StencilPackageMaster(id: id, sourceID: sourceID, part: part, relationshipID: rid,
                name: element.attr("Name") ?? element.attr("NameU") ?? sourceID, universalName: element.attr("NameU") ?? "",
                baseID: element.attr("BaseID"), uniqueID: element.attr("UniqueID"), cells: cells))
        }
        return StencilPackageSnapshot(store: StencilPackageParts(parts), sourceURL: sourceURL.standardizedFileURL.resolvingSymlinksInPath(),
            lineageID: lineageID, documentPart: documentPart, mastersPart: mastersPart, masters: masters, reservedIDs: reservedIDs.union(sourceReserved).union(ids))
    }

    static func applying(_ edit: StencilPackageEdit, to input: StencilPackageSnapshot) throws -> StencilPackageSnapshot {
        try checkpoint()
        var parts = input.parts, reserved = input.reservedIDs
        let index = try xml(input.mastersPart, in: parts), root = index.rootElement()!
        let relationPart = VisioXML.relationshipPart(input.mastersPart)
        let relationDocument = try xml(relationPart, in: parts), relationRoot = relationDocument.rootElement()!
        let byID = Dictionary(uniqueKeysWithValues: core(root, "Master").map { (UInt32($0.attr("ID")!)!, $0) })
        func master(_ id: UInt32) throws -> (StencilPackageMaster, XMLElement) {
            guard let record = input.masters.first(where: { $0.id == id }), let element = byID[id] else {
                throw DiagramError.invalid("The selected master no longer exists. Reload the stencil.")
            }; return (record, element)
        }
        switch edit {
        case .rename(let id, let name):
            let (record, element) = try master(id); try validateName(name)
            guard record.name != name else { return input }
            element.setAttr("Name", name)
        case .move(let id, let destination):
            let (_, element) = try master(id)
            guard input.masters.indices.contains(destination), let prior = input.masters.firstIndex(where: { $0.id == id }) else {
                throw DiagramError.invalid("Choose an existing master position.")
            }
            guard prior != destination else { return input }
            var ordered = core(root, "Master")
            ordered.remove(at: prior); ordered.insert(element, at: destination)
            let slots = (root.children ?? []).enumerated().compactMap { ($0.element as? XMLElement).map { $0.localTag == "Master" && $0.uri == namespace } == true ? $0.offset : nil }
            for child in core(root, "Master") { child.detach() }
            for (slot, child) in zip(slots, ordered) { root.insertChild(child, at: slot) }
        case .duplicate(let id, let name):
            let (record, element) = try master(id); try validateName(name)
            try preflightDuplicate(record, in: input)
            guard input.masters.count < 1000, let highest = reserved.max(), highest < UInt32.max - 1 else {
                throw DiagramError.invalid("This stencil has no available master identity within the editing budget.")
            }
            let newID = highest + 1; reserved.insert(newID)
            let folder = (record.part as NSString).deletingLastPathComponent
            var number = 1, newPart = ""
            let typeEntries = try xml("[Content_Types].xml", in: parts).rootElement()?.elementsLocal("Override") ?? []
            let occupied = Set(parts.keys.map { $0.lowercased() } + typeEntries.compactMap { $0.attr("PartName").map { String($0.drop(while: { $0 == "/" })).lowercased() } })
            repeat {
                try checkpoint()
                newPart = (folder.isEmpty ? "" : folder + "/") + "macvisio-master-\(newID)-\(number).xml"; number += 1
            } while occupied.contains(newPart.lowercased()) || occupied.contains(VisioXML.relationshipPart(newPart).lowercased())
            try VisioPackage.validatePath(newPart)
            // Keeping the containing directory preserves every relative resource
            // target. Shared styles, media and referenced masters stay in place.
            parts[newPart] = parts[record.part]
            if let data = parts[VisioXML.relationshipPart(record.part)] { parts[VisioXML.relationshipPart(newPart)] = data }
            let copy = element.copy() as! XMLElement
            copy.setAttr("ID", String(newID)); copy.setAttr("Name", name)
            copy.setAttr("NameU", "MacVisioMaster.\(UUID().uuidString)")
            copy.setAttr("BaseID", "{\(UUID().uuidString)}"); copy.setAttr("UniqueID", "{\(UUID().uuidString)}")
            let used = Set(relationRoot.elementsLocal("Relationship").filter { $0.uri == relationNamespace }.compactMap { $0.attr("Id") })
            var rid = "MacVisioMaster\(newID)"
            while used.contains(rid) { try checkpoint(); rid += "x" }
            guard let reference = core(copy, "Rel").first else { throw DiagramError.invalid("The selected master has no public relationship owner.") }
            let attribute = reference.attributes?.first { $0.localName == "id" && $0.uri == referenceNamespace }
            guard let attribute else { throw DiagramError.invalid("The selected master relationship is ambiguous.") }
            attribute.stringValue = rid; root.addChild(copy)
            let relation = XMLElement(name: "Relationship", uri: relationNamespace)
            relation.setAttr("Id", rid); relation.setAttr("Type", relationship + "master"); relation.setAttr("Target", "/" + newPart)
            relationRoot.addChild(relation)
            parts[relationPart] = relationDocument.xmlData(options: .nodePreserveAll)
            let types = try xml("[Content_Types].xml", in: parts)
            let sourceTypes = types.rootElement()?.elementsLocal("Override").filter { $0.attr("PartName") == "/" + record.part } ?? []
            guard sourceTypes.count == 1, let type = sourceTypes.first?.copy() as? XMLElement else {
                throw DiagramError.invalid("The master content type is missing or ambiguous.")
            }
            type.setAttr("PartName", "/" + newPart); types.rootElement()!.addChild(type)
            parts["[Content_Types].xml"] = types.xmlData(options: .nodePreserveAll)
        case .delete(let id):
            let (record, element) = try master(id)
            guard input.masters.count > 1 else { throw DiagramError.invalid("Keep at least one master in the stencil.") }
            try preflightDeletion(record, in: input)
            element.detach()
            let relations = relationRoot.elementsLocal("Relationship").filter { $0.uri == relationNamespace }.filter { $0.attr("Id") == record.relationshipID }
            guard relations.count == 1 else { throw DiagramError.invalid("The master relationship has ambiguous ownership.") }
            relations[0].detach(); parts[relationPart] = relationDocument.xmlData(options: .nodePreserveAll)
            // No garbage collection: orphaned content, relationships, media and
            // opaque parts are retained so deletion cannot erase shared payloads.
        case .literal(let id, let shapeID, let address, let expected, let value):
            let (record, _) = try master(id)
            guard input.masters.filter({ $0.part == record.part }).count == 1 else {
                throw DiagramError.invalid("Several masters share this content part. Duplicate a master before editing its cells.")
            }
            guard let selected = record.cells.first(where: { $0.shapeID == shapeID && $0.address == address }), selected.value == expected else {
                throw DiagramError.invalid("The selected source cell changed. Reload it before applying the draft.")
            }
            if let reason = selected.refusal { throw DiagramError.invalid(reason) }
            guard value.utf8.count <= 65_536, !value.contains("\0"), value.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Inh") != .orderedSame else {
                throw DiagramError.invalid("Enter a literal value within the supported size; inherited values cannot be edited here.")
            }
            if expected.unit.uppercased() != "STR", Double(expected.value) != nil, Double(value)?.isFinite != true {
                throw DiagramError.invalid("This source cell contains a numeric literal. Enter a finite number.")
            }
            guard value != expected.value else { return input }
            let content = try xml(record.part, in: parts)
            guard let shape = try shapeElements(content.rootElement()!).first(where: { $0.attr("ID") == shapeID }),
                  let cell = try exactCell(address, in: shape), literalRefusal(ShapeSheetCell(value: cell.attr("V") ?? "", formula: cell.attr("F") ?? "", unit: cell.attr("U") ?? "")) == nil else {
                throw DiagramError.invalid("The authoritative literal cell is unavailable.")
            }
            cell.setAttr("V", value)
            parts[record.part] = content.xmlData(options: .nodePreserveAll)
            return try snapshot(parts: parts, sourceURL: input.sourceURL, lineageID: input.lineageID, reservedIDs: reserved)
        }
        parts[input.mastersPart] = index.xmlData(options: .nodePreserveAll)
        return try snapshot(parts: parts, sourceURL: input.sourceURL, lineageID: input.lineageID, reservedIDs: reserved)
    }

    static func preflightDeletion(_ master: StencilPackageMaster, in input: StencilPackageSnapshot) throws {
        guard input.masters.filter({ $0.part == master.part }).count == 1,
              input.masters.filter({ $0.relationshipID == master.relationshipID }).count == 1 else {
            throw DiagramError.invalid("The selected master shares a content part or relationship; deletion is unsafe.")
        }
        let index = try xml(input.mastersPart, in: input.parts)
        if let root = index.rootElement(), !core(root, "MasterShortcut").isEmpty {
            throw DiagramError.invalid("This stencil contains master shortcuts. Their source dependencies cannot be proven safe for deletion.")
        }
        let allowedNamespaces: Set<String> = [namespace, relationNamespace,
            "http://schemas.openxmlformats.org/package/2006/content-types",
            "http://schemas.openxmlformats.org/package/2006/metadata/core-properties", "http://purl.org/dc/elements/1.1/",
            "http://purl.org/dc/terms/", "http://www.w3.org/2001/XMLSchema-instance",
            "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties",
            "http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"]
        let knownXML = Set([input.documentPart, input.mastersPart, "[Content_Types].xml", "docProps/core.xml", "docProps/app.xml"] + input.masters.map(\.part))
        let contentTypes = try xml("[Content_Types].xml", in: input.parts).rootElement()
        let safeImages: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/bmp", "image/tiff"]
        for name in input.parts.keys.sorted() {
            try checkpoint()
            if name.hasSuffix(".rels") {
                let source = try relationshipOwner(name)
                let relationshipDocument = try xml(name, in: input.parts)
                guard let relationshipRoot = relationshipDocument.rootElement() else {
                    throw DiagramError.invalid("An opaque relationship extension prevents proving master deletion safe.")
                }
                try proveRelationshipOwnerForDeletion(relationshipRoot)
                for relation in try relationships(name, in: input.parts) {
                    let supportedTypes: Set<String> = Set(["document", "masters", "master", "image", "theme", "hyperlink"].map { relationship + $0 })
                        .union([referenceNamespace + "/image", referenceNamespace + "/theme", referenceNamespace + "/hyperlink",
                            referenceNamespace + "/extended-properties", "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties"])
                    guard relation.attr("Type").map({ supportedTypes.contains($0) }) == true else {
                        throw DiagramError.invalid("An unsupported relationship may contain master dependencies. Deletion is unavailable.")
                    }
                    guard relation.attr("TargetMode") != "External", let target = relation.attr("Target") else { continue }
                    let resolved = try VisioFormat.resolve(target, relativeTo: source)
                    guard input.parts[resolved] != nil else { throw DiagramError.invalid("A source relationship is unresolved; deletion cannot be proven safe.") }
                    if resolved == master.part, !(name == VisioXML.relationshipPart(input.mastersPart) && relation.attr("Id") == master.relationshipID) {
                        throw DiagramError.invalid("Another package relationship references this master content part.")
                    }
                }
            } else if name.hasSuffix(".xml") {
                guard let root = try xml(name, in: input.parts).rootElement() else { continue }
                guard knownXML.contains(name) || (root.localTag == "MasterContents" && root.uri == namespace) else {
                    throw DiagramError.invalid("An opaque XML part may contain master dependencies. Deletion is unavailable for this stencil.")
                }
                var stack = [root], count = 0
                while let element = stack.popLast() {
                    if count % 128 == 0 { try checkpoint() }; count += 1
                    guard let uri = element.uri, allowedNamespaces.contains(uri),
                          (element.attributes ?? []).allSatisfy({ $0.kind == .namespace || $0.name == "xmlns" || $0.name?.hasPrefix("xmlns:") == true || ($0.uri ?? "").isEmpty || [referenceNamespace, "http://www.w3.org/XML/1998/namespace", "http://www.w3.org/2001/XMLSchema-instance"].contains($0.uri ?? "") }) else {
                        throw DiagramError.invalid("An opaque XML extension may contain master dependencies. Deletion is unavailable for this stencil.")
                    }
                    try proveSourceElementForDeletion(element)
                    if element.uri == namespace, element.localTag == "Shape", let reference = element.attr("Master") {
                        guard let id = UInt32(reference) else { throw DiagramError.invalid("A source master reference is invalid; deletion cannot be proven safe.") }
                        if id == master.id { throw DiagramError.invalid("Another source shape still references Master \(master.sourceID).") }
                    }
                    if element.uri == namespace,
                       element.attr("SourceMaster") != nil || element.attr("MasterID") != nil || element.attr("MasterId") != nil
                        || (element.localTag != "Shape" && element.attr("Master") != nil) {
                        throw DiagramError.invalid("A source master identity carrier has unsupported ownership; deletion cannot be proven safe.")
                    }
                    stack.append(contentsOf: (element.children ?? []).compactMap { $0 as? XMLElement })
                }
            } else {
                let type = contentTypes?.elementsLocal("Override").first { $0.attr("PartName") == "/" + name }?.attr("ContentType")
                    ?? contentTypes?.elementsLocal("Default").first { $0.attr("Extension")?.lowercased() == (name as NSString).pathExtension.lowercased() }?.attr("ContentType")
                guard type.map({ safeImages.contains($0) }) == true else {
                    throw DiagramError.invalid("An opaque binary part may contain master dependencies. Deletion is unavailable for this stencil.")
                }
            }
        }
    }

    private static func preflightDuplicate(_ master: StencilPackageMaster, in input: StencilPackageSnapshot) throws {
        let part = VisioXML.relationshipPart(master.part)
        let relations: [XMLElement]
        if input.parts[part] != nil { relations = try relationships(part, in: input.parts) }
        else { relations = [] }
        let byID = Dictionary(uniqueKeysWithValues: relations.map { ($0.attr("Id")!, $0) })
        for relation in relations where relation.attr("TargetMode") != "External" {
            try checkpoint()
            guard let target = relation.attr("Target"), input.parts[try VisioFormat.resolve(target, relativeTo: master.part)] != nil else {
                throw DiagramError.invalid("A master resource relationship is unresolved; duplication is unsafe.")
            }
        }
        let root = try xml(master.part, in: input.parts).rootElement()!
        var stack = [root], count = 0
        while let element = stack.popLast() {
            if count % 128 == 0 { try checkpoint() }; count += 1
            if element.uri == namespace, element.localTag == "Rel" {
                let attrs = element.attributes?.filter { $0.localName == "id" && $0.uri == referenceNamespace } ?? []
                guard attrs.count == 1, let rid = attrs[0].stringValue, byID[rid] != nil else {
                    throw DiagramError.invalid("A master resource reference has no proven relationship owner.")
                }
            }
            if element.uri == namespace, element.localTag == "Shape", let raw = element.attr("Master") {
                guard let id = UInt32(raw), input.masters.contains(where: { $0.id == id }) else {
                    throw DiagramError.invalid("A source master dependency is unresolved; duplication is unavailable.")
                }
            }
            stack.append(contentsOf: (element.children ?? []).compactMap { $0 as? XMLElement })
        }
    }

    /// OPC relationships have a closed set of owners and attributes. Unknown
    /// payloads remain intact for ordinary edits, but cannot prove independence
    /// from an index identity during deletion.
    private static func proveRelationshipOwnerForDeletion(_ root: XMLElement) throws {
        func declaration(_ node: XMLNode) -> Bool {
            node.kind == .namespace || node.name == "xmlns" || node.name?.hasPrefix("xmlns:") == true
        }
        func whitespaceOrComment(_ node: XMLNode) -> Bool {
            node.kind == .comment || (node.kind == .text && (node.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        guard root.localTag == "Relationships", root.uri == relationNamespace,
              (root.attributes ?? []).allSatisfy(declaration) else {
            throw DiagramError.invalid("An unknown relationship-root attribute prevents proving master deletion safe.")
        }
        let attributes: Set<String> = ["Id", "Type", "Target", "TargetMode"]
        for child in root.children ?? [] {
            try checkpoint()
            guard let relation = child as? XMLElement else {
                guard whitespaceOrComment(child) else { throw DiagramError.invalid("An opaque relationship-root payload prevents proving master deletion safe.") }
                continue
            }
            guard relation.localTag == "Relationship", relation.uri == relationNamespace,
                  (relation.attributes ?? []).allSatisfy({ declaration($0) || (($0.uri ?? "").isEmpty && $0.name.map { attributes.contains($0) } == true) }),
                  (relation.children ?? []).allSatisfy(whitespaceOrComment) else {
                throw DiagramError.invalid("An opaque relationship attribute or nested payload prevents proving master deletion safe.")
            }
        }
    }

    private struct DeletionOwner {
        var attributes: Set<String>
        var children: Set<String>
        var text: Bool
    }
    /// Deletion deliberately supports a closed source subset. A standard
    /// namespace is not proof that an unfamiliar owner or attribute is safe.
    private static let deletionOwners: [String: DeletionOwner] = {
        var result: [String: DeletionOwner] = [:]
        func add(_ uri: String, _ names: String, attributes: String = "", children: String = "", text: Bool = false) {
            let allowed = Set(children.split(separator: " ").map { child in child.contains("#") ? String(child) : uri + "#" + String(child) })
            for name in names.split(separator: " ") {
                result[uri + "#" + String(name)] = DeletionOwner(attributes: Set(attributes.split(separator: " ").map(String.init)), children: allowed, text: text)
            }
        }
        add(namespace, "VisioDocument", children: "DocumentSettings Colors FaceNames StyleSheets DocumentSheet")
        add(namespace, "DocumentSettings", children: "GlueSettings SnapSettings")
        add(namespace, "GlueSettings SnapSettings", text: true)
        add(namespace, "Colors", children: "ColorEntry")
        add(namespace, "ColorEntry", attributes: "IX RGB Name")
        add(namespace, "FaceNames", children: "FaceName")
        add(namespace, "FaceName", attributes: "Name NameU")
        add(namespace, "StyleSheets", children: "StyleSheet")
        add(namespace, "StyleSheet", attributes: "ID Name NameU LineStyle FillStyle TextStyle IsCustomName IsCustomNameU", children: "Cell Section")
        add(namespace, "DocumentSheet PageSheet", attributes: "ID Name NameU LineStyle FillStyle TextStyle", children: "Cell Section")
        add(namespace, "Masters", children: "Master")
        add(namespace, "Master", attributes: "ID Name NameU BaseID UniqueID MatchByName IconUpdate", children: "PageSheet Rel")
        add(namespace, "MasterContents", children: "Shapes Connects")
        add(namespace, "Shapes", children: "Shape")
        add(namespace, "Shape", attributes: "ID Name NameU Type Master MasterShape LineStyle FillStyle TextStyle Del IsCustomName IsCustomNameU UniqueID", children: "Cell Section Shapes Text ForeignData")
        add(namespace, "Cell", attributes: "N V F U Error")
        add(namespace, "Section", attributes: "N IX Del", children: "Cell Row")
        add(namespace, "Row", attributes: "N IX T Del", children: "Cell")
        add(namespace, "Text", children: "cp pp tp fld", text: true)
        add(namespace, "cp pp tp", attributes: "IX")
        add(namespace, "fld", attributes: "IX", text: true)
        add(namespace, "ForeignData", attributes: "ForeignType", children: "Rel", text: true)
        add(namespace, "Rel")
        add(namespace, "Connects", children: "Connect")
        add(namespace, "Connect", attributes: "FromSheet FromCell FromPart ToSheet ToCell ToPart")
        let types = "http://schemas.openxmlformats.org/package/2006/content-types"
        add(types, "Types", children: "Default Override")
        add(types, "Default", attributes: "Extension ContentType")
        add(types, "Override", attributes: "PartName ContentType")
        let coreProperties = "http://schemas.openxmlformats.org/package/2006/metadata/core-properties"
        let dc = "http://purl.org/dc/elements/1.1/", terms = "http://purl.org/dc/terms/"
        add(coreProperties, "coreProperties", children: "\(dc)#title \(dc)#creator \(dc)#subject \(dc)#description \(dc)#language \(coreProperties)#keywords \(coreProperties)#lastModifiedBy \(coreProperties)#revision \(terms)#created \(terms)#modified")
        add(coreProperties, "keywords lastModifiedBy revision", text: true)
        add(dc, "title creator subject description language", text: true)
        add(terms, "created modified", text: true)
        let app = "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"
        add(app, "Properties", children: "Application AppVersion Company Template Manager")
        add(app, "Application AppVersion Company Template Manager", text: true)
        return result
    }()

    private static func proveSourceElementForDeletion(_ element: XMLElement) throws {
        let uri = element.uri ?? "", key = uri + "#" + element.localTag
        guard let owner = deletionOwners[key] else {
            throw DiagramError.invalid("An unsupported XML source owner may contain master dependencies. Deletion is unavailable.")
        }
        for attribute in element.attributes ?? [] {
            let name = attribute.name ?? "", attributeURI = attribute.uri ?? ""
            if attribute.kind == .namespace || name == "xmlns" || name.hasPrefix("xmlns:") { continue }
            if attributeURI == "http://www.w3.org/XML/1998/namespace", attribute.localName == "space",
               ["default", "preserve"].contains(attribute.stringValue ?? "") { continue }
            if uri == namespace, element.localTag == "Rel", attributeURI == referenceNamespace, attribute.localName == "id" { continue }
            if uri == "http://purl.org/dc/terms/", ["created", "modified"].contains(element.localTag),
               attributeURI == "http://www.w3.org/2001/XMLSchema-instance", attribute.localName == "type" { continue }
            guard attributeURI.isEmpty, owner.attributes.contains(name) else {
                throw DiagramError.invalid("An unsupported XML source attribute may contain master dependencies. Deletion is unavailable.")
            }
        }
        for child in element.children ?? [] {
            if let child = child as? XMLElement {
                guard owner.children.contains((child.uri ?? "") + "#" + child.localTag) else {
                    throw DiagramError.invalid("An unsupported XML child owner may contain master dependencies. Deletion is unavailable.")
                }
            } else if child.kind != .comment {
                guard child.kind == .text, owner.text || (child.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw DiagramError.invalid("An opaque XML source payload prevents proving master deletion safe.")
                }
            }
        }
        if uri == namespace, element.localTag == "Section", let name = element.attr("N"),
           !["User", "Property", "Geometry", "Character", "Paragraph", "Control", "Controls", "Connection", "Connections", "Hyperlink", "Layer"].contains(name) {
            throw DiagramError.invalid("This source section is outside the supported deletion proof.")
        }
        if uri == namespace, element.localTag == "Row", let type = element.attr("T"),
           !["MoveTo", "LineTo", "RelMoveTo", "RelLineTo"].contains(type) {
            throw DiagramError.invalid("This source row type is outside the supported deletion proof.")
        }
        if uri == namespace, element.localTag == "ForeignData", element.attr("ForeignType") != "Bitmap" {
            throw DiagramError.invalid("This embedded source payload is outside the supported deletion proof.")
        }
        if uri == namespace, element.localTag == "Cell", let authored = element.attr("F") {
            try proveFormulaForDeletion(authored)
        }
    }

    private static func proveFormulaForDeletion(_ authored: String) throws {
        let formula = authored.trimmingCharacters(in: .whitespacesAndNewlines)
        if formula.isEmpty || ["INH", "NO FORMULA"].contains(formula.uppercased()) { return }
        // Inspect the existing bounded parser's tree; never execute a formula
        // or interpret a quoted argument as an identity-bearing expression.
        let pure: Set<String> = ["GUARD", "ABS", "MIN", "MAX", "SUM", "IF", "IFERROR", "AND", "OR", "NOT", "RGB"]
        var expressions = [try ShapeSheet.parse(formula)], count = 0
        while let expression = expressions.popLast() {
            if count % 128 == 0 { try checkpoint() }; count += 1
            guard count <= 10_000 else { throw DiagramError.invalid("The source formula exceeds the supported deletion proof budget.") }
            switch expression {
            case .number, .measure, .string: break
            case .omitted: throw DiagramError.invalid("An omitted source argument has unproven deletion semantics.")
            case .unary(_, let child): expressions.append(child)
            case .binary(_, let left, let right): expressions.append(left); expressions.append(right)
            case .call(let name, let arguments):
                guard pure.contains(name.uppercased()) else {
                    throw DiagramError.invalid("The source function \(name) has unproven master dependencies. Deletion is unavailable.")
                }
                expressions.append(contentsOf: arguments)
            case .reference(let reference):
                let pieces = reference.uppercased().split(separator: "!", omittingEmptySubsequences: false).map(String.init)
                guard pieces.count <= 2, let cell = pieces.last, !cell.isEmpty,
                      !cell.hasPrefix("MASTER."), !cell.hasPrefix("MASTERS[") else {
                    throw DiagramError.invalid("A source reference has unproven master ownership. Deletion is unavailable.")
                }
                if pieces.count == 2 {
                    let owner = pieces[0]
                    guard ["THEDOC", "THEPAGE", "PARENTSHAPE"].contains(owner)
                        || (owner.hasPrefix("SHEET.") && UInt32(owner.dropFirst(6)) != nil) else {
                        throw DiagramError.invalid("A source reference has unsupported scope. Deletion is unavailable.")
                    }
                }
            }
        }
    }

    private static func core(_ element: XMLElement, _ name: String) -> [XMLElement] {
        element.elementsLocal(name).filter { $0.uri == namespace }
    }
    private static func publicCells(_ shape: XMLElement) throws -> [(DefinitionCellAddress, ShapeSheetCell, Bool)] {
        var result: [(DefinitionCellAddress, ShapeSheetCell, Bool)] = []
        func append(_ owner: XMLElement, address: DefinitionCellAddress, deleted: Bool) throws {
            for cell in core(owner, "Cell") {
                if result.count % 128 == 0 { try checkpoint() }
                guard let name = cell.attr("N"), !name.isEmpty else { throw DiagramError.invalid("A public source cell has no identity.") }
                var target = address; target.cell = name
                result.append((target, ShapeSheetCell(value: cell.attr("V") ?? "", formula: cell.attr("F") ?? "", unit: cell.attr("U") ?? ""), deleted))
            }
        }
        try append(shape, address: DefinitionCellAddress(cell: ""), deleted: false)
        for section in core(shape, "Section") {
            guard let name = section.attr("N") else { throw DiagramError.invalid("A public source section has no identity.") }
            let address = DefinitionCellAddress(cell: "", section: name, sectionIndex: section.attr("IX"))
            let deleted = ["1", "true"].contains(section.attr("Del") ?? "")
            try append(section, address: address, deleted: deleted)
            for row in core(section, "Row") {
                var target = address; target.rowName = row.attr("N"); target.rowIndex = row.attr("IX")
                try append(row, address: target, deleted: deleted || ["1", "true"].contains(row.attr("Del") ?? ""))
            }
        }; return result
    }

    private static func literalRefusal(_ value: ShapeSheetCell) -> String? {
        let formula = value.formula.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.value.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("Inh") == .orderedSame || formula == "INH" {
            return "This cell inherits a value or formula. Edit its authoritative definition instead."
        }
        return formula.isEmpty || formula == "NO FORMULA" ? nil : "This cell has an authored formula. Editing its cached value is unavailable here."
    }
    private static func styleRefusal(_ address: DefinitionCellAddress, on shape: XMLElement, styles: [String: XMLElement]) throws -> String? {
        var current: XMLElement? = shape, visited = Set<ObjectIdentifier>()
        while let owner = current {
            try checkpoint()
            for attribute in ["LineStyle", "FillStyle", "TextStyle"] {
                var next = owner.attr(attribute), seen = Set<String>()
                while let raw = next {
                    guard let numeric = UInt32(raw), seen.insert(String(numeric)).inserted, let style = styles[String(numeric)] else {
                        return "The inherited style owner is unresolved; literal editing is unavailable."
                    }
                    if let cell = try exactCell(address, in: style), let refusal = literalRefusal(ShapeSheetCell(value: cell.attr("V") ?? "", formula: cell.attr("F") ?? "", unit: cell.attr("U") ?? "")) { return refusal }
                    next = style.attr(attribute)
                }
            }
            guard visited.insert(ObjectIdentifier(owner)).inserted else { return "The source style ownership is cyclic." }
            current = (owner.parent as? XMLElement)?.parent as? XMLElement
            if current?.localTag != "Shape" { current = nil }
        }
        return nil
    }
    private static func exactCell(_ address: DefinitionCellAddress, in shape: XMLElement) throws -> XMLElement? {
        var owners = [shape]
        if let section = address.section { owners = core(shape, "Section").filter { $0.attr("N") == section && $0.attr("IX") == address.sectionIndex } }
        if address.rowName != nil || address.rowIndex != nil {
            owners = owners.flatMap { core($0, "Row") }.filter { $0.attr("N") == address.rowName && $0.attr("IX") == address.rowIndex }
        }
        guard owners.count <= 1 else { throw DiagramError.invalid("The cell section or row has ambiguous source ownership.") }
        let matches = owners.flatMap { core($0, "Cell") }.filter { $0.attr("N") == address.cell }
        guard matches.count <= 1 else { throw DiagramError.invalid("The source cell address is ambiguous.") }; return matches.first
    }
    private static func shapeElements(_ root: XMLElement) throws -> [XMLElement] {
        var result: [XMLElement] = [], stack = core(root, "Shapes").first.map { core($0, "Shape") } ?? []
        while let shape = stack.popLast() {
            if result.count % 128 == 0 { try checkpoint() }; result.append(shape)
            stack.append(contentsOf: core(shape, "Shapes").first.map { core($0, "Shape") } ?? [])
        }; return result
    }
    private static func validateName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256,
              !name.unicodeScalars.contains(where: { $0.value < 32 }) else { throw DiagramError.invalid("Enter a master name of 1–256 bytes without control characters.") }
    }
    private static func relationID(_ element: XMLElement) -> String? {
        let references = core(element, "Rel")
        guard references.count == 1 else { return nil }
        let attrs = references[0].attributes?.filter { $0.localName == "id" && $0.uri == referenceNamespace } ?? []
        return attrs.count == 1 ? attrs[0].stringValue : nil
    }
    private static func relationships(_ part: String, in parts: [String: Data]) throws -> [XMLElement] {
        let document = try xml(part, in: parts)
        guard let root = document.rootElement(), root.localTag == "Relationships", root.uri == relationNamespace else { throw DiagramError.invalid("A package relationship owner is invalid.") }
        let relations = root.elementsLocal("Relationship").filter { $0.uri == relationNamespace }; var ids = Set<String>()
        for relation in relations {
            try checkpoint()
            guard let id = relation.attr("Id"), !id.isEmpty, ids.insert(id).inserted,
                  relation.attr("Target") != nil, relation.attr("Type") != nil else { throw DiagramError.invalid("Package relationships are missing or ambiguous.") }
        }; return relations
    }
    private static func relationshipOwner(_ part: String) throws -> String {
        if part == "_rels/.rels" { return "" }
        guard let range = part.range(of: "/_rels/", options: .backwards), part.hasSuffix(".rels") else {
            throw DiagramError.invalid("A package relationship has an unsupported source owner.")
        }
        return String(part[..<range.lowerBound]) + "/" + String(part[range.upperBound...].dropLast(5))
    }
    private static func xml(_ part: String, in parts: [String: Data]) throws -> XMLDocument {
        guard let data = parts[part] else { throw DiagramError.invalid("A stencil source part is missing: \(part).") }
        return try VisioXML.document(data)
    }
    private static func checkpoint() throws { try LifecycleJobContext.current?.checkpoint() }
}
