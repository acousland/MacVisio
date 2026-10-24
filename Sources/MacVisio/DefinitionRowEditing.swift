import Foundation
import MacVisioInfrastructure

/// Source addresses advance only with the saved archive, independently of the
/// authored row identities in undo snapshots. Removed XML supports undo after save.
struct DefinitionSourceRow: Codable, Equatable {
    var sheetID: UUID
    var rowID: UUID
    var address: DefinitionCellAddress
    var removedXML: Data? = nil
    var isSection: Bool? = nil
    var identityAddress: DefinitionCellAddress? = nil

    static func index(_ registry: DefinitionRegistry) -> [Self] {
        registry.editableSheets.flatMap { sheet in
            sheet.rows.map { Self(sheetID: sheet.id, rowID: $0.id, address: $0.address, identityAddress: $0.identityAddress) }
                + (sheet.sections ?? []).map { Self(sheetID: sheet.id, rowID: $0.id, address: $0.address, isSection: true) }
        }
    }

    static func validate(_ records: [Self], registry: DefinitionRegistry? = nil) throws {
        guard records.count <= 100000, Set(records.map(\.rowID)).count == records.count,
              records.reduce(0, { $0 + ($1.removedXML?.count ?? 0) }) <= VisioPackage.totalLimit else {
            throw DiagramError.invalid("Invalid retained definition row sources.")
        }
        let sheets = registry.map { Set($0.editableSheets.map(\.id)) }
        var activeAddresses = Set<String>()
        func valid(_ address: DefinitionCellAddress) -> Bool {
            address.cell.isEmpty && address.section.map { !$0.isEmpty && $0.utf8.count <= 256 } == true
                && address.rowName.map { !$0.isEmpty && $0.utf8.count <= 256 } != false
                && address.sectionIndex.map { UInt32($0) != nil } != false && address.rowIndex.map { UInt32($0) != nil } != false
        }
        for (position, record) in records.enumerated() {
            if position % 128 == 0 { try LifecycleJobContext.current?.checkpoint() }
            let identity = record.identityAddress ?? record.address
            let section = record.isSection == true
            let key = record.sheetID.uuidString + (section ? ":section:" : ":row:") + record.address.key
            guard valid(record.address), valid(identity), sheets?.contains(record.sheetID) != false,
                  identity.section == record.address.section, identity.sectionIndex == record.address.sectionIndex,
                  identity.rowIndex == record.address.rowIndex, (identity.rowName == nil) == (record.address.rowName == nil),
                  (!section || (record.address.rowName == nil && record.address.rowIndex == nil && record.identityAddress == nil)),
                  record.rowID == DefinitionRegistry.stableID(record.sheetID, (section ? "section:" : "") + identity.key),
                  (record.removedXML != nil || activeAddresses.insert(key).inserted),
                  (record.removedXML?.count ?? 0) <= VisioPackage.partLimit else {
                throw DiagramError.invalid("Invalid retained definition row ownership or address.")
            }
            if let data = record.removedXML {
                guard let root = try VisioXML.document(data).rootElement(), root.localTag == (section ? "Section" : "Row"),
                      root.uri == nil || root.uri == "http://schemas.microsoft.com/office/visio/2012/main",
                      root.attr("N") == (section ? record.address.section : record.address.rowName),
                      root.attr("IX") == (section ? record.address.sectionIndex : record.address.rowIndex) else {
                    throw DiagramError.invalid("The retained definition XML does not match its row or section address.")
                }
            }
        }
    }

    private static let validationCache: NSCache<NSString, NSObject> = {
        let cache = NSCache<NSString, NSObject>();cache.countLimit = 32;return cache
    }()

    static func validateArchive(_ archive: VisioDocumentArchive, registry: DefinitionRegistry) throws {
        guard let records = archive.definitionRows else { return }
        let key = "\(archive.sourceResourceID):\(archive.definitionRowsResourceID):\(registry.sourceDocumentID)" as NSString
        // Both stores have fresh resource IDs after decoding or mutation. A
        // validated immutable source never requires a new XML scan per edit.
        let owners = Set(registry.editableSheets.map(\.id))
        guard records.allSatisfy({ owners.contains($0.sheetID) }) else { throw DiagramError.invalid("A retained row belongs to an unavailable definition sheet.") }
        if validationCache.object(forKey:key) != nil { return }
        try validate(records, registry:registry)
        let bySheet = Dictionary(grouping:records.filter{$0.removedXML == nil},by: \.sheetID)
        _ = try DefinitionRowEditing.elements(registry,parts:archive.parts) { sheet,element,_ in
            var rows: [DefinitionCellAddress:Int] = [:], sections: [DefinitionCellAddress:Int] = [:]
            for section in element.elementsLocal("Section") {
                guard let name = section.attr("N") else { continue }
                let address = DefinitionCellAddress(cell:"",section:name,sectionIndex:section.attr("IX"))
                sections[address,default:0] += 1
                for row in section.elementsLocal("Row") {
                    var address = address;address.rowName = row.attr("N");address.rowIndex = row.attr("IX")
                    rows[address,default:0] += 1
                }
            }
            let source = bySheet[sheet.id] ?? []
            guard source.filter({$0.isSection == true}).count == sections.count,
                  source.filter({$0.isSection != true}).count == rows.count,
                  source.allSatisfy({ ($0.isSection == true ? sections[$0.address] : rows[$0.address]) == 1 }) else {
                throw DiagramError.invalid("The retained definition sources do not match the public row and section addresses.")
            }
        }
        validationCache.setObject(NSObject(),forKey:key)
    }

}

extension DefinitionRegistry {
    var editableSheets: [DefinitionSheet] { (documentSheet.map { [$0] } ?? []) + (masters + styles).flatMap(\.sheets) }

    mutating func forEachEditableSheet(_ edit: (inout DefinitionSheet) throws -> Void) rethrows {
        if documentSheet != nil { try edit(&documentSheet!) }
        for i in masters.indices { for j in masters[i].sheets.indices { try edit(&masters[i].sheets[j]) } }
        for i in styles.indices { for j in styles[i].sheets.indices { try edit(&styles[i].sheets[j]) } }
    }

    mutating func editSheet(_ id: UUID, _ edit: (inout DefinitionSheet) throws -> Void) throws {
        if documentSheet?.id == id { try edit(&documentSheet!); return }
        for i in masters.indices {
            if let j = masters[i].sheets.firstIndex(where: { $0.id == id }) { try edit(&masters[i].sheets[j]); return }
        }
        for i in styles.indices {
            if let j = styles[i].sheets.firstIndex(where: { $0.id == id }) { try edit(&styles[i].sheets[j]); return }
        }
        throw DiagramError.invalid("The definition sheet is no longer available.")
    }
}

enum DefinitionRowEdit: Equatable {
    case insert(section: String, name: String)
    case rename(rowID: UUID, name: String)
    case remove(rowID: UUID)
    case insertSection(name: String)
    case removeSection(sectionID: UUID)
}

enum DefinitionRowEditing {
    static func proposal(_ edit: DefinitionRowEdit, sheetID: UUID, registry: DefinitionRegistry) throws -> DefinitionRegistry {
        var result = registry
        try result.editSheet(sheetID) { sheet in
            func checkName(_ name: String, section: String, except: UUID? = nil) throws {
                guard name.utf8.count <= 128, let first = name.first, first.isLetter || first == "_",
                      name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
                    throw DiagramError.invalid("Use a row name beginning with a letter or underscore, followed by letters, digits or underscores.")
                }
                guard !sheet.rows.contains(where: { $0.id != except && $0.section == section && $0.sectionIndex == nil && $0.name?.caseInsensitiveCompare(name) == .orderedSame }) else {
                    throw DiagramError.invalid("That section already contains a row with this name.")
                }
                // A previously renamed row retains this native identity. Reusing
                // it would make public references and undo ownership ambiguous.
                let address = DefinitionCellAddress(cell: "", section: section, rowName: name)
                let id = DefinitionRegistry.stableID(sheet.id, address.key)
                guard !sheet.rows.contains(where: { $0.id != except && $0.id == id }) else {
                    throw DiagramError.invalid("This row name is retained by another renamed row.")
                }
            }
            func addSection(_ name: String) throws {
                guard ["User", "Property"].contains(name), sheet.sections != nil else { throw DiagramError.invalid("Reload the public section metadata before editing sections.") }
                let address = DefinitionCellAddress(cell: "", section: name)
                sheet.sections?.append(DefinitionSection(id: DefinitionRegistry.stableID(sheet.id, "section:" + address.key), name: name, index: nil, attributes: ["N": name]))
            }
            switch edit {
            case .insert(let section, let name):
                guard ["User", "Property"].contains(section) else { throw DiagramError.invalid("Choose User or Property for a named row.") }
                try checkName(name, section: section)
                if sheet.sections != nil, sheet.sections?.contains(where: { $0.name == section && $0.index == nil }) == false { try addSection(section) }
                let address = DefinitionCellAddress(cell: "", section: section, rowName: name)
                sheet.rows.append(DefinitionRow(id: DefinitionRegistry.stableID(sheet.id, address.key), section: section,
                    sectionIndex: nil, name: name, index: nil, type: nil, deleted: false))
                for (column, value) in (section == "Property" ? [("Label", name), ("Type", "0"), ("Value", "0")] : [("Value", "0")]) {
                    var cell = address; cell.cell = column; sheet.set(cell, to: ShapeSheetCell(value: value))
                }
            case .rename(let rowID, let name):
                guard let i = sheet.rows.firstIndex(where: { $0.id == rowID }),
                      ["User", "Property"].contains(sheet.rows[i].section), sheet.rows[i].sectionIndex == nil,
                      sheet.rows[i].name != nil, sheet.rows[i].index == nil, !sheet.rows[i].deleted else {
                    throw DiagramError.invalid("Select an active named User or Property row.")
                }
                let old = sheet.rows[i].address
                try checkName(name, section: sheet.rows[i].section, except: rowID)
                if sheet.rows[i].name == name { return }
                sheet.rows[i].identityAddress = sheet.rows[i].identityAddress ?? old
                sheet.rows[i].name = name
                for j in sheet.cells.indices {
                    var address = sheet.cells[j].address; address.cell = ""
                    if address == old {
                        sheet.cells[j].identityAddress = sheet.cells[j].identityAddress ?? sheet.cells[j].address
                        sheet.cells[j].address.rowName = name
                    }
                }
            case .insertSection(let name):
                guard sheet.sections?.contains(where: { $0.name == name && $0.index == nil }) == false else { throw DiagramError.invalid("That local section already exists.") }
                try addSection(name)
            case .removeSection(let sectionID):
                guard let section = sheet.sections?.first(where: { $0.id == sectionID }), ["User", "Property"].contains(section.name), section.index == nil else {
                    throw DiagramError.invalid("Select a local User or Property section.")
                }
                sheet.sections?.removeAll { $0.id == sectionID }
                sheet.rows.removeAll { $0.section == section.name && $0.sectionIndex == section.index }
                sheet.cells.removeAll { $0.address.section == section.name && $0.address.sectionIndex == section.index }
            case .remove(let rowID):
                guard let row = sheet.rows.first(where: { $0.id == rowID }), ["User", "Property"].contains(row.section),
                      row.sectionIndex == nil, row.name != nil, row.index == nil, !row.deleted else {
                    throw DiagramError.invalid("Select an active named User or Property row.")
                }
                sheet.rows.removeAll { $0.id == rowID }
                sheet.cells.removeAll { var address = $0.address; address.cell = ""; return address == row.address }
            }
        }
        guard result != registry else { return registry }
        result.version = 2
        try result.validate()
        return result
    }

    /// Locate the public owners without relying on display names or global Sheet.N IDs.
    static func elements(_ registry: DefinitionRegistry, parts: [String: Data],
                         _ body: (DefinitionSheet, XMLElement, String) throws -> Void) throws -> [String: XMLDocument] {
        var documents: [String: XMLDocument] = [:]
        var stylesByPart: [String: [String: XMLElement]] = [:]
        var mastersByPart: [String: [String: XMLElement]] = [:]
        var work = 0
        func root(_ part: String) throws -> XMLElement {
            if documents[part] == nil {
                guard let data = parts[part] else { throw DiagramError.invalid("A definition source part is missing.") }
                documents[part] = try VisioXML.document(data)
            }
            guard let root = documents[part]?.rootElement() else { throw DiagramError.invalid("A definition source has no root.") }
            return root
        }
        try checkpoint(&work)
        if let sheet = registry.documentSheet, let element = try root(registry.documentPart).firstLocal("DocumentSheet") {
            try body(sheet, element, registry.documentPart)
        }
        for owner in registry.styles + registry.masters {
            try checkpoint(&work)
            let root = try root(owner.part)
            let byID: [String: XMLElement]
            if owner.kind == .style {
                if let cached = stylesByPart[owner.part] { byID = cached }
                else {
                    var indexed: [String: XMLElement] = [:]
                    for element in root.firstLocal("StyleSheets")?.elementsLocal("StyleSheet") ?? [] {
                        try checkpoint(&work)
                        if let id = element.attr("ID"), indexed[id] == nil { indexed[id] = element }
                    }
                    stylesByPart[owner.part] = indexed; byID = indexed
                }
            } else if let cached = mastersByPart[owner.part] { byID = cached }
            else {
                var indexed: [String: XMLElement] = [:]
                var pending = Array((root.firstLocal("Shapes")?.elementsLocal("Shape") ?? []).reversed())
                while let element = pending.popLast() {
                    try checkpoint(&work)
                    if let id = element.attr("ID"), indexed[id] == nil { indexed[id] = element }
                    for child in (element.firstLocal("Shapes")?.elementsLocal("Shape") ?? []).reversed() {
                        try checkpoint(&work); pending.append(child)
                    }
                }
                mastersByPart[owner.part] = indexed; byID = indexed
            }
            for sheet in owner.sheets {
                try checkpoint(&work)
                guard let element = byID[sheet.publicID] else { throw DiagramError.invalid("The public definition sheet is missing.") }
                try body(sheet, element, owner.part)
            }
        }
        try LifecycleJobContext.current?.checkpoint()
        return documents
    }

    static func row(_ address: DefinitionCellAddress, in sheet: XMLElement) -> XMLElement? {
        sheet.elementsLocal("Section").first { $0.attr("N") == address.section && $0.attr("IX") == address.sectionIndex }?
            .elementsLocal("Row").first { $0.attr("N") == address.rowName && $0.attr("IX") == address.rowIndex }
    }

    static func patchRows(_ registry: DefinitionRegistry, parts: [String: Data], sources: [DefinitionSourceRow]) throws -> [String: Data] {
        let live = DefinitionSourceRow.index(registry)
        var work = 0
        var active: [DefinitionSourceRow] = []
        var bySheet: [UUID: [DefinitionSourceRow]] = [:]
        for source in sources {
            try checkpoint(&work)
            if source.removedXML == nil { active.append(source) }
            bySheet[source.sheetID, default: []].append(source)
        }
        try LifecycleJobContext.current?.checkpoint()
        if live == active { return parts }
        var changed = Set<String>()
        let documents = try elements(registry, parts: parts) { sheet, element, part in
            let allRecords = bySheet[sheet.id] ?? []
            var records: [DefinitionSourceRow] = []
            var sourceRowsByID: [UUID: DefinitionSourceRow] = [:]
            var sourceSectionsByID: [UUID: DefinitionSourceRow] = [:]
            for record in allRecords {
                try checkpoint(&work)
                if record.isSection == true { sourceSectionsByID[record.rowID] = record }
                else { records.append(record); sourceRowsByID[record.rowID] = record }
            }
            var targets: [UUID: DefinitionRow] = [:]
            for target in sheet.rows { try checkpoint(&work); targets[target.id] = target }
            var indexed = try AddressIndex(element, work: &work)
            if let sections = sheet.sections {
                var targetSectionIDs = Set<UUID>()
                for section in sections { try checkpoint(&work); targetSectionIDs.insert(section.id) }
                for record in allRecords {
                    try checkpoint(&work)
                    guard record.isSection == true, record.removedXML == nil, !targetSectionIDs.contains(record.rowID) else { continue }
                    if let source = indexed.removeSection(record.address) {
                        source.detach(); changed.insert(part)
                    }
                }
                for target in sections {
                    try checkpoint(&work)
                    guard indexed.section(target.address) == nil else { continue }
                    let section: XMLElement
                    if let data = sourceSectionsByID[target.id]?.removedXML,
                       let original = try VisioXML.document(data).rootElement()?.copy() as? XMLElement {
                        section = original
                        // Rows have their own identities and retained payloads.
                        for row in section.elementsLocal("Row") { try checkpoint(&work); row.detach() }
                    } else {
                        section = XMLElement(name: "Section")
                        for (name, value) in target.attributes { try checkpoint(&work); section.setAttr(name, value) }
                    }
                    element.addChild(section); indexed.addSection(section, at: target.address); changed.insert(part)
                }
            }
            // Detach all renamed/deleted rows first, permitting name swaps without
            // resolving a newly moved row as another row's original source.
            var retained: [UUID: XMLElement] = [:]
            for record in records {
                try checkpoint(&work)
                let target = targets[record.rowID]
                if target?.address == record.address, record.removedXML == nil { continue }
                if record.removedXML == nil, let source = indexed.removeRow(record.address) {
                    if targets[record.rowID] != nil { retained[record.rowID] = source }
                    source.detach(); changed.insert(part)
                } else if let data = record.removedXML, let source = try VisioXML.document(data).rootElement() {
                    retained[record.rowID] = source.copy() as? XMLElement
                }
            }
            for target in sheet.rows {
                try checkpoint(&work)
                let source = sourceRowsByID[target.id]
                let existing = retained[target.id] ?? indexed.row(target.address)
                if existing != nil, source?.address == target.address, source?.removedXML == nil { continue }
                var section = indexed.section(target.address)
                if section == nil {
                    let created = XMLElement(name: "Section"); created.setAttr("N", target.section); created.setAttr("IX", target.sectionIndex)
                    element.addChild(created); indexed.addSection(created, at: target.address); section = created
                }
                let value = existing ?? XMLElement(name: "Row")
                value.setAttr("N", target.name); value.setAttr("IX", target.index); value.setAttr("T", target.type)
                value.setAttr("Del", target.deleted ? "1" : nil)
                if value.parent == nil { section?.addChild(value) }
                indexed.addRow(value, at: target.address)
                changed.insert(part)
            }
        }
        var result = parts
        for part in changed { try LifecycleJobContext.current?.checkpoint(); result[part] = documents[part]?.xmlData(options: .nodePreserveAll) }
        return result
    }

    static func advancedSources(_ registry: DefinitionRegistry?, original: [String: Data], sources: [DefinitionSourceRow]?) throws -> [DefinitionSourceRow]? {
        guard let registry else { return sources }
        let prior = sources ?? DefinitionSourceRow.index(registry)
        var work = 0
        var missing: [UUID: DefinitionSourceRow] = [:]
        for record in prior { try checkpoint(&work); if missing[record.rowID] == nil { missing[record.rowID] = record } }
        let live = DefinitionSourceRow.index(registry)
        for record in live { try checkpoint(&work); missing.removeValue(forKey: record.rowID) }
        var bySheet: [UUID: [DefinitionSourceRow]] = [:]
        for record in prior {
            try checkpoint(&work)
            if let missing = missing[record.rowID], missing.removedXML == nil { bySheet[record.sheetID, default: []].append(record) }
        }
        if !bySheet.isEmpty {
            _ = try elements(registry, parts: original) { sheet, element, _ in
                guard let records = bySheet[sheet.id] else { return }
                let indexed = try AddressIndex(element, work: &work)
                for record in records {
                    try checkpoint(&work)
                    let retained = record.isSection == true ? indexed.section(record.address) : indexed.row(record.address)
                    if let retained { missing[record.rowID]?.removedXML = try retainedXML(retained, work: &work) }
                }
            }
        }
        let result = live + missing.values.sorted { $0.rowID.uuidString < $1.rowID.uuidString }
        try LifecycleJobContext.current?.checkpoint()
        try DefinitionSourceRow.validate(result)
        return result
    }

    private static func checkpoint(_ work: inout Int) throws {
        if work.isMultiple(of: 128) { try LifecycleJobContext.current?.checkpoint() }
        work += 1
    }

    /// DOM indexes retain the first matching section/row, matching `row` lookup.
    /// Per-section row maps avoid scanning unrelated rows on section removal.
    private struct AddressIndex {
        private var sections: [DefinitionCellAddress: XMLElement] = [:]
        private var rows: [DefinitionCellAddress: [DefinitionCellAddress: XMLElement]] = [:]

        private static func sectionAddress(_ address: DefinitionCellAddress) -> DefinitionCellAddress {
            DefinitionCellAddress(cell: "", section: address.section, sectionIndex: address.sectionIndex)
        }
        init(_ element: XMLElement, work: inout Int) throws {
            for section in element.elementsLocal("Section") {
                try DefinitionRowEditing.checkpoint(&work)
                let address = DefinitionCellAddress(cell: "", section: section.attr("N"), sectionIndex: section.attr("IX"))
                guard sections[address] == nil else { continue }
                sections[address] = section
                var indexed: [DefinitionCellAddress: XMLElement] = [:]
                for row in section.elementsLocal("Row") {
                    try DefinitionRowEditing.checkpoint(&work)
                    var key = address; key.rowName = row.attr("N"); key.rowIndex = row.attr("IX")
                    if indexed[key] == nil { indexed[key] = row }
                }
                rows[address] = indexed
            }
        }
        func section(_ address: DefinitionCellAddress) -> XMLElement? { sections[Self.sectionAddress(address)] }
        func row(_ address: DefinitionCellAddress) -> XMLElement? { rows[Self.sectionAddress(address)]?[address] }
        mutating func removeSection(_ address: DefinitionCellAddress) -> XMLElement? {
            let key = Self.sectionAddress(address); rows.removeValue(forKey: key)
            return sections.removeValue(forKey: key)
        }
        mutating func addSection(_ element: XMLElement, at address: DefinitionCellAddress) {
            let key = Self.sectionAddress(address); sections[key] = element; rows[key] = [:]
        }
        mutating func removeRow(_ address: DefinitionCellAddress) -> XMLElement? {
            rows[Self.sectionAddress(address)]?.removeValue(forKey: address)
        }
        mutating func addRow(_ element: XMLElement, at address: DefinitionCellAddress) {
            rows[Self.sectionAddress(address), default: [:]][address] = element
        }
    }

    /// A retained fragment must remain parseable without its original part root.
    /// Preserve in-scope bindings; declarations nearest the retained node win.
    private static func retainedXML(_ element: XMLElement, work: inout Int) throws -> Data {
        let copy = element.copy() as! XMLElement
        var prefixes = Set((copy.namespaces ?? []).map { $0.name ?? "" })
        var ancestor: XMLNode? = element
        while let owner = ancestor as? XMLElement {
            try checkpoint(&work)
            for namespace in owner.namespaces ?? [] {
                try checkpoint(&work)
                if prefixes.insert(namespace.name ?? "").inserted { copy.addNamespace(namespace.copy() as! XMLNode) }
            }
            ancestor = owner.parent
        }
        return Data(copy.xmlString(options: .nodePreserveAll).utf8)
    }
}
