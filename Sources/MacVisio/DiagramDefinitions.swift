import Foundation
import CryptoKit

/// Public identities are scoped by document, definition part and sheet. Display
/// names are labels and never participate in reference matching.
struct DefinitionCellAddress: Codable, Equatable, Hashable {
    var cell: String
    var section: String? = nil
    var sectionIndex: String? = nil
    var rowName: String? = nil
    var rowIndex: String? = nil

    var key: String {
        [section ?? "", sectionIndex ?? "", rowName ?? "", rowIndex ?? "", cell]
            .map { "\($0.utf8.count):\($0)" }.joined()
    }
}

struct DefinitionCell: Codable, Equatable, Identifiable {
    var id: UUID
    var address: DefinitionCellAddress
    var value: ShapeSheetCell
    /// The original public address anchors identity across an authored row rename.
    var identityAddress: DefinitionCellAddress? = nil
    var inherits: Bool { value.value.caseInsensitiveCompare("Inh") == .orderedSame || value.formula.uppercased() == "INH" }
}

struct DefinitionRow: Codable, Equatable, Identifiable {
    var id: UUID
    var section: String
    var sectionIndex: String?
    var name: String?
    var index: String?
    var type: String?
    var deleted: Bool
    var identityAddress: DefinitionCellAddress? = nil

    var address: DefinitionCellAddress {
        DefinitionCellAddress(cell: "", section: section, sectionIndex: sectionIndex, rowName: name, rowIndex: index)
    }
}

struct DefinitionSection: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var index: String?
    var attributes: [String: String]
    var address: DefinitionCellAddress { DefinitionCellAddress(cell: "", section: name, sectionIndex: index) }
}

struct DefinitionSheet: Codable, Equatable, Identifiable {
    var id: UUID
    var publicID: String
    var parentID: UUID?
    var attributes: [String: String]
    var cells: [DefinitionCell]
    var rows: [DefinitionRow]
    var sections: [DefinitionSection]? = nil
    var text: String?

    func cell(_ address: DefinitionCellAddress) -> ShapeSheetCell? {
        cells.first { $0.address == address }?.value
    }

    mutating func set(_ address: DefinitionCellAddress, to value: ShapeSheetCell?) {
        if value != nil, let section = address.section {
            let sectionAddress = DefinitionCellAddress(cell: "", section: section, sectionIndex: address.sectionIndex)
            if sections != nil, sections?.contains(where: { $0.address == sectionAddress }) == false {
                var attributes = ["N": section];attributes["IX"] = address.sectionIndex
                sections?.append(DefinitionSection(id: DefinitionRegistry.stableID(id, "section:" + sectionAddress.key), name: section, index: address.sectionIndex, attributes: attributes))
            }
            var rowAddress = address;rowAddress.cell = ""
            if address.rowName != nil || address.rowIndex != nil, !rows.contains(where: { $0.address == rowAddress }) {
                rows.append(DefinitionRow(id: DefinitionRegistry.stableID(id,rowAddress.key),section:section,sectionIndex:address.sectionIndex,
                    name:address.rowName,index:address.rowIndex,type:nil,deleted:false))
            }
        }
        if let index = cells.firstIndex(where: { $0.address == address }) {
            if let value { cells[index].value = value } else { cells.remove(at: index) }
        } else if let value {
            cells.append(DefinitionCell(id: DefinitionRegistry.stableID(id, address.key), address: address, value: value))
        }
    }
}

struct DiagramDefinition: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case master, style }
    var id: UUID
    var kind: Kind
    var publicID: String
    var part: String
    var name: String
    var universalName: String
    var sheets: [DefinitionSheet]
}

struct ShapeDefinitionUse: Codable, Equatable {
    var pageID: UUID
    var objectID: UUID
    var masterID: UUID?
    var masterShapeID: String?
    var styles: [String: UUID]
    /// Retained source provenance, distinct from the live drawing's membership
    /// and the importer's expanded projection. Ordinary copy/delete operations
    /// need not keep an object with this ID in the current pages.
    var localSheet: DefinitionSheet
    /// Style-only uses retain a source binding rather than duplicating potentially
    /// multi-megabyte ordinary shape payloads already present in native content.
    var localSheetIncludesCells = true
}

struct DefinitionRegistry: Codable, Equatable {
    var version = 1
    var sourceDocumentID: UUID
    var documentPart: String
    var documentSheet: DefinitionSheet?
    var masters: [DiagramDefinition]
    var styles: [DiagramDefinition]
    var uses: [ShapeDefinitionUse]

    static func stableID(_ scope: UUID, _ key: String) -> UUID {
        let b = Array(SHA256.hash(data: Data((scope.uuidString + ":" + key).utf8)))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    static func hydrate(_ diagram: Diagram) throws -> Diagram {
        guard diagram.definitions == nil, let archive = diagram.visioArchive else { return diagram }
        var result = diagram
        let scope = archive.sourceLineageID
        let documentPart = try VisioReusableFormat.documentPart(archive.parts)
        guard let data = archive.parts[documentPart], let document = try VisioXML.document(data).rootElement() else {
            throw DiagramError.invalid("The public document sheet is unavailable.")
        }
        let styles = (document.firstLocal("StyleSheets")?.elementsLocal("StyleSheet") ?? []).map { style in
            let publicID = style.attr("ID") ?? ""
            let id = stableID(scope, "style:\(documentPart):\(publicID)")
            return DiagramDefinition(id: id, kind: .style, publicID: publicID, part: documentPart,
                name: style.attr("Name") ?? style.attr("NameU") ?? publicID,
                universalName: style.attr("NameU") ?? publicID,
                sheets: [sheet(style, scope: id, publicID: publicID)])
        }
        var masters: [DiagramDefinition] = []
        if let indexPart = try relatedPart(archive.parts, source: documentPart, type: "masters"),
           let indexData = archive.parts[indexPart] {
            let index = try VisioXML.document(indexData)
            let relations = try relationshipElements(archive.parts, source: indexPart)
            for master in index.rootElement()?.elementsLocal("Master") ?? [] {
                let publicID = master.attr("ID") ?? ""
                let rid = master.firstLocal("Rel")?.attributes?.first { $0.localName == "id" || $0.name == "r:id" }?.stringValue
                guard let relation = relations.first(where: { $0.attr("Id") == rid }),
                      relation.attr("TargetMode") != "External", let target = relation.attr("Target") else { continue }
                let part = try VisioFormat.resolve(target, relativeTo: indexPart)
                guard let data = archive.parts[part], let root = try VisioXML.document(data).rootElement() else { continue }
                let id = stableID(scope, "master:\(part):\(publicID)")
                var sheets: [DefinitionSheet] = []
                func visit(_ element: XMLElement, parent: UUID?) {
                    let value = sheet(element, scope: id, publicID: element.attr("ID") ?? "", parent: parent)
                    sheets.append(value)
                    for child in element.firstLocal("Shapes")?.elementsLocal("Shape") ?? [] { visit(child, parent: value.id) }
                }
                for element in root.firstLocal("Shapes")?.elementsLocal("Shape") ?? [] { visit(element, parent: nil) }
                masters.append(DiagramDefinition(id: id, kind: .master, publicID: publicID, part: part,
                    name: master.attr("Name") ?? master.attr("NameU") ?? publicID,
                    universalName: master.attr("NameU") ?? publicID, sheets: sheets))
            }
        }
        let mastersByID = Dictionary(masters.map { ($0.publicID, $0) }, uniquingKeysWith: { first, _ in first })
        let stylesByID = Dictionary(styles.map { ($0.publicID, $0.id) }, uniquingKeysWith: { first, _ in first })
        let masterSheetIDs = Dictionary(masters.map { ($0.id, Set($0.sheets.map(\.publicID))) }, uniquingKeysWith: { first, _ in first })
        var singleRoots: [UUID: String] = [:]
        for master in masters {
            let roots = master.sheets.filter { $0.parentID == nil }
            if roots.count == 1 { singleRoots[master.id] = roots[0].publicID }
        }
        var uses: [ShapeDefinitionUse] = []
        for binding in archive.pages {
            guard let data = archive.parts[binding.part], let root = try VisioXML.document(data).rootElement() else { continue }
            let objects = Dictionary((Array(binding.nodeIDs) + Array(binding.edgeIDs)).map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
            var useIndices: [UUID: Int] = [:]
            var pending: [UUID] = []
            func append(_ use: ShapeDefinitionUse) {
                useIndices[use.objectID] = uses.count
                uses.append(use)
                pending.append(use.objectID)
            }
            func visit(_ element: XMLElement, inheritedMaster: String?) {
                let master = element.attr("Master") ?? inheritedMaster
                if let sourceID = element.attr("ID"), let objectID = objects[sourceID] {
                    let definition = master.flatMap { mastersByID[$0] }
                    var styleUses: [String: UUID] = [:]
                    for role in ["LineStyle", "FillStyle", "TextStyle"] {
                        if let value = element.attr(role).flatMap({ stylesByID[$0] }) { styleUses[role] = value }
                    }
                    let masterShape: String?
                    if let explicit = element.attr("MasterShape") {
                        // Unresolved source references remain in attributes;
                        // the resolved registry must not claim a dangling target.
                        masterShape = definition.flatMap { masterSheetIDs[$0.id]?.contains(explicit) == true ? explicit : nil }
                    } else {
                        // Multi-root masters import through a synthetic group,
                        // which does not represent just their first real root.
                        masterShape = definition.flatMap { singleRoots[$0.id] }
                    }
                    if definition != nil || !styleUses.isEmpty { append(ShapeDefinitionUse(pageID: binding.pageID, objectID: objectID,
                        masterID: definition?.id,
                        masterShapeID: masterShape,
                        styles: styleUses, localSheet: sheet(element, scope: objectID, publicID: sourceID, includeContents: definition != nil),
                        localSheetIncludesCells: definition != nil)) }
                }
                for child in element.firstLocal("Shapes")?.elementsLocal("Shape") ?? [] { visit(child, inheritedMaster: master) }
            }
            for element in root.firstLocal("Shapes")?.elementsLocal("Shape") ?? [] { visit(element, inheritedMaster: nil) }
            let inheritance = binding.inheritedShapes ?? [:]
            var children: [UUID: [UUID]] = [:]
            // The retained source order gives deterministic sibling order in
            // linear work; dictionary order cannot put a grandchild first.
            for objectID in binding.original.nodes.map(\.id) + binding.original.edges.map(\.id) {
                if let entry = inheritance[objectID], useIndices[objectID] == nil {
                    children[entry.parentID, default: []].append(objectID)
                }
            }
            var cursor = 0
            while cursor < pending.count {
                let parentID = pending[cursor]
                cursor += 1
                guard let parentIndex = useIndices[parentID] else { continue }
                let parent = uses[parentIndex]
                for objectID in children[parentID] ?? [] where useIndices[objectID] == nil {
                    guard let entry = inheritance[objectID],
                          let publicID = binding.nodeIDs[objectID] ?? binding.edgeIDs[objectID],
                          let masterID = parent.masterID,
                          masterSheetIDs[masterID]?.contains(entry.masterShapeID) == true else { continue }
                    append(ShapeDefinitionUse(pageID: binding.pageID, objectID: objectID, masterID: masterID,
                        masterShapeID: entry.masterShapeID, styles: [:],
                        localSheet: DefinitionSheet(id: stableID(objectID, "sheet:\(publicID)"), publicID: publicID,
                            parentID: nil, attributes: [:], cells: [], rows: [], text: nil)))
                }
            }
        }
        result.definitions = DefinitionRegistry(sourceDocumentID: scope, documentPart: documentPart,
            documentSheet: document.firstLocal("DocumentSheet").map { sheet($0, scope: scope, publicID: "TheDoc") },
            masters: masters, styles: styles, uses: uses)
        result.visioArchive?.definitionRows = result.definitions.map(DefinitionSourceRow.index)
        return result
    }

    /// Fetch style-only provenance from the preserved source when inspected.
    /// Call from an owned worker for large packages.
    func sourceSheet(for use: ShapeDefinitionUse, archive: VisioDocumentArchive) throws -> DefinitionSheet? {
        if use.localSheetIncludesCells { return use.localSheet }
        guard let binding = archive.pages.first(where: { $0.pageID == use.pageID }),
              let data = archive.parts[binding.part],
              let element = try VisioXML.document(data).rootElement()?.firstLocal("Shapes")?.allShapes.first(where: { $0.attr("ID") == use.localSheet.publicID }) else { return nil }
        return Self.sheet(element, scope: use.objectID, publicID: use.localSheet.publicID)
    }

    static func sheet(_ element: XMLElement, scope: UUID, publicID: String, parent: UUID? = nil, includeContents: Bool = true) -> DefinitionSheet {
        let id = stableID(scope, "sheet:\(publicID)")
        let attributes = Dictionary((element.attributes ?? []).compactMap { node -> (String, String)? in
            guard let name = node.name, let value = node.stringValue else { return nil }; return (name, value)
        }, uniquingKeysWith: { first, _ in first })
        if !includeContents {
            return DefinitionSheet(id: id, publicID: publicID, parentID: parent, attributes: attributes, cells: [], rows: [], text: nil)
        }
        var cells: [DefinitionCell] = []
        var rows: [DefinitionRow] = []
        var sections: [DefinitionSection] = []
        func appendCells(_ owner: XMLElement, section: String? = nil, sectionIndex: String? = nil, rowName: String? = nil, rowIndex: String? = nil) {
            for element in owner.elementsLocal("Cell") {
                guard let name = element.attr("N") else { continue }
                let address = DefinitionCellAddress(cell: name, section: section, sectionIndex: sectionIndex, rowName: rowName, rowIndex: rowIndex)
                cells.append(DefinitionCell(id: stableID(id, address.key), address: address,
                    value: ShapeSheetCell(value: element.attr("V") ?? "", formula: element.attr("F") ?? "", unit: element.attr("U") ?? "")))
            }
        }
        appendCells(element)
        for section in element.elementsLocal("Section") {
            guard let name = section.attr("N") else { continue }
            let index = section.attr("IX")
            let address = DefinitionCellAddress(cell: "", section: name, sectionIndex: index)
            sections.append(DefinitionSection(id: stableID(id, "section:" + address.key), name: name, index: index,
                attributes: Dictionary((section.attributes ?? []).compactMap { attribute in
                    attribute.name.flatMap { key in attribute.stringValue.map { (key, $0) } }
                }, uniquingKeysWith: { a, _ in a })))
            appendCells(section, section: name, sectionIndex: index)
            for row in section.elementsLocal("Row") {
                let rowName = row.attr("N"), rowIndex = row.attr("IX")
                let key = DefinitionCellAddress(cell: "", section: name, sectionIndex: index, rowName: rowName, rowIndex: rowIndex).key
                rows.append(DefinitionRow(id: stableID(id, key), section: name, sectionIndex: index,
                    name: rowName, index: rowIndex, type: row.attr("T"),
                    deleted: ["1", "true"].contains(row.attr("Del") ?? "") || ["1", "true"].contains(section.attr("Del") ?? "")))
                appendCells(row, section: name, sectionIndex: index, rowName: rowName, rowIndex: rowIndex)
            }
        }
        return DefinitionSheet(id: id, publicID: publicID, parentID: parent, attributes: attributes,
            cells: cells, rows: rows, sections: sections, text: element.firstLocal("Text")?.stringValue)
    }

    private static func relationshipElements(_ parts: [String: Data], source: String) throws -> [XMLElement] {
        guard let data = parts[VisioXML.relationshipPart(source)] else { return [] }
        return try VisioXML.document(data).rootElement()?.elementsLocal("Relationship") ?? []
    }

    static func relatedPart(_ parts: [String: Data], source: String, type: String) throws -> String? {
        guard let relation = try relationshipElements(parts, source: source).first(where: {
            $0.attr("Type") == VisioReusableFormat.relationship + type && $0.attr("TargetMode") != "External"
        }), let target = relation.attr("Target") else { return nil }
        return try VisioFormat.resolve(target, relativeTo: source)
    }

    func validate() throws {
        let definitions = masters + styles
        guard (1...2).contains(version), definitions.count <= 10000, Set(definitions.map(\.id)).count == definitions.count,
              Set(masters.compactMap { UInt32($0.publicID) }).count == masters.count,
              Set(styles.compactMap { UInt32($0.publicID) }).count == styles.count,
              uses.count <= 1_000_000,
              masters.allSatisfy({ $0.kind == .master }), styles.allSatisfy({ $0.kind == .style }) else {
            throw DiagramError.invalid("Invalid definition registry.")
        }
        try VisioPackage.validatePath(documentPart)
        var editableSheetIDs: Set<UUID> = []
        if let documentSheet {
            guard documentSheet.publicID == "TheDoc", documentSheet.parentID == nil,
                  documentSheet.id == Self.stableID(sourceDocumentID, "sheet:TheDoc"),
                  editableSheetIDs.insert(documentSheet.id).inserted else { throw DiagramError.invalid("Invalid document sheet identity.") }
            try Self.validateSheet(documentSheet, version: version)
        }
        for definition in definitions {
            try VisioPackage.validatePath(definition.part)
            guard UInt32(definition.publicID) != nil, definition.sheets.count <= 50000,
                  definition.id == Self.stableID(sourceDocumentID, "\(definition.kind.rawValue):\(definition.part):\(definition.publicID)"),
                  Set(definition.sheets.map(\.id)).count == definition.sheets.count,
                  Set(definition.sheets.compactMap { UInt32($0.publicID) }).count == definition.sheets.count,
                  definition.name.utf8.count <= 1024, definition.universalName.utf8.count <= 1024 else { throw DiagramError.invalid("Invalid definition identity.") }
            if definition.kind == .style {
                guard definition.part == documentPart, definition.sheets.count == 1,
                      definition.sheets[0].publicID == definition.publicID else { throw DiagramError.invalid("Invalid style sheet identity.") }
            }
            let parents = Dictionary(uniqueKeysWithValues: definition.sheets.map { ($0.id, $0.parentID) })
            for sheet in definition.sheets {
                guard sheet.id == Self.stableID(definition.id, "sheet:\(sheet.publicID)"),
                      editableSheetIDs.insert(sheet.id).inserted else { throw DiagramError.invalid("Duplicate or invalid definition sheet identity.") }
                var seen: Set<UUID> = [sheet.id]
                var parent = sheet.parentID
                while let id = parent {
                    guard seen.insert(id).inserted, seen.count <= 64, let next = parents[id] else { throw DiagramError.invalid("Invalid definition sheet hierarchy.") }
                    parent = next
                }
                try Self.validateSheet(sheet, version: version)
            }
        }
        let masterTargets = Dictionary(masters.map { ($0.id, Set($0.sheets.map(\.publicID))) }, uniquingKeysWith: { first, _ in first })
        let styleTargets = Set(styles.map(\.id))
        var objectsByPage: [UUID: Set<UUID>] = [:]
        var publicIDsByPage: [UUID: Set<UInt32>] = [:]
        for use in uses {
            guard use.localSheetIncludesCells || (use.localSheet.cells.isEmpty && use.localSheet.rows.isEmpty && use.localSheet.text == nil) else {
                throw DiagramError.invalid("A source-only binding cannot claim retained cell contents.")
            }
            guard objectsByPage[use.pageID, default: []].insert(use.objectID).inserted,
                  let publicID = UInt32(use.localSheet.publicID),
                  publicIDsByPage[use.pageID, default: []].insert(publicID).inserted,
                  use.localSheet.parentID == nil,
                  use.localSheet.id == Self.stableID(use.objectID, "sheet:\(use.localSheet.publicID)"),
                  use.styles.allSatisfy({ ["LineStyle", "FillStyle", "TextStyle"].contains($0.key) && styleTargets.contains($0.value) }) else {
                throw DiagramError.invalid("Invalid source definition use.")
            }
            if let masterID = use.masterID {
                guard let targets = masterTargets[masterID], use.masterShapeID.map({ targets.contains($0) }) != false else {
                    throw DiagramError.invalid("Invalid source master target.")
                }
            } else if use.masterShapeID != nil { throw DiagramError.invalid("A master shape requires a master owner.") }
            try Self.validateSheet(use.localSheet, version: version)
        }
    }

    private static func validateSheet(_ sheet: DefinitionSheet, version: Int) throws {
        func name(_ value: String?) -> Bool { value.map { !$0.isEmpty && $0.utf8.count <= 256 } ?? true }
        func index(_ value: String?) -> Bool { value.map { UInt32($0) != nil } ?? true }
        func address(_ value: DefinitionCellAddress) -> Bool {
            guard !value.cell.isEmpty, value.cell.utf8.count <= 256,
                  name(value.section), name(value.rowName), index(value.sectionIndex), index(value.rowIndex) else { return false }
            return value.section != nil || (value.sectionIndex == nil && value.rowName == nil && value.rowIndex == nil)
        }
        guard sheet.cells.count <= 100000, sheet.rows.count <= 100000,
              sheet.attributes.count <= 256, (sheet.text?.utf8.count ?? 0) <= VisioPackage.partLimit,
              sheet.attributes.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 256 && $0.value.utf8.count <= VisioPackage.partLimit }),
              sheet.attributes["ID"].map({ $0 == sheet.publicID }) != false,
              Set(sheet.cells.map(\.id)).count == sheet.cells.count,
              Set(sheet.cells.map(\.address)).count == sheet.cells.count,
              Set(sheet.rows.map(\.id)).count == sheet.rows.count else { throw DiagramError.invalid("Invalid definition sheet.") }
        let sections = sheet.sections ?? []
        guard sections.count <= 10000, Set(sections.map(\.id)).count == sections.count else { throw DiagramError.invalid("Invalid definition sections.") }
        for section in sections {
            guard name(section.name), index(section.index), section.id == stableID(sheet.id, "section:" + section.address.key),
                  section.attributes.count <= 256, section.attributes["N"] == section.name,
                  section.attributes["IX"] == section.index,
                  section.attributes.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 256 && $0.value.utf8.count <= VisioPackage.partLimit }) else {
                throw DiagramError.invalid("Invalid definition section identity or attributes.")
            }
        }
        for cell in sheet.cells {
            let identity = cell.identityAddress ?? cell.address
            guard address(cell.address), address(identity),
                  (cell.identityAddress == nil || version == 2),
                  identity.section == cell.address.section, identity.sectionIndex == cell.address.sectionIndex,
                  identity.rowIndex == cell.address.rowIndex, identity.cell == cell.address.cell,
                  (identity.rowName == nil) == (cell.address.rowName == nil),
                  cell.id == stableID(sheet.id, identity.key),
                  cell.value.value.utf8.count <= VisioPackage.partLimit,
                  cell.value.formula.utf8.count <= 16384, cell.value.unit.utf8.count <= 64 else {
                throw DiagramError.invalid("Invalid definition cell identity or value.")
            }
        }
        var rows: Set<String> = []
        for row in sheet.rows {
            let key = row.address.key
            let identity = row.identityAddress ?? row.address
            guard name(row.section), name(row.name), index(row.sectionIndex), index(row.index),
                  (row.type?.utf8.count ?? 0) <= 256, rows.insert(key).inserted,
                  (row.identityAddress == nil || version == 2), identity.cell.isEmpty,
                  identity.section == row.section, identity.sectionIndex == row.sectionIndex,
                  identity.rowIndex == row.index, name(identity.rowName), (identity.rowName == nil) == (row.name == nil),
                  row.id == stableID(sheet.id, identity.key) else { throw DiagramError.invalid("Invalid definition row identity.") }
        }
    }
}
