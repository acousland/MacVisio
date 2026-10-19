import Foundation
import MacVisioInfrastructure

/// Definition edits are immutable proposals. Public parts produce the updated
/// instance projection; native IDs, local overrides and the original save
/// baseline remain owned by the document transaction.
enum DefinitionEditing {
    static func settingCell(in input: Diagram, sheetID: UUID, address: DefinitionCellAddress,
                            value: ShapeSheetCell?) throws -> Diagram {
        if address.section == nil, let reason = DiagramMemberships.managedCellReason(address.cell) { throw DiagramError.invalid(reason) }
        guard var registry = input.definitions, input.visioArchive != nil else {
            throw DiagramError.invalid("This drawing has no public definition source.")
        }
        try registry.editSheet(sheetID) { $0.set(address, to: value) }
        try registry.validate()
        guard registry != input.definitions else { return input }
        return try applying(registry, to: input)
    }

    static func editingRow(in input: Diagram, sheetID: UUID, edit: DefinitionRowEdit) throws -> Diagram {
        guard let registry = input.definitions, input.visioArchive != nil else {
            throw DiagramError.invalid("This drawing has no public definition source.")
        }
        if let sheet = registry.editableSheets.first(where: { $0.id == sheetID }) {
            let name: String?, section: String?, editingID: UUID?
            switch edit {
            case .insert(let kind, let proposed): name = proposed;section = kind;editingID = nil
            case .rename(let id, let proposed): name = proposed;section = sheet.rows.first { $0.id == id }?.section;editingID = id
            case .insertSection(let proposed): name = nil;section = proposed;editingID = nil
            default: name = nil;section = nil;editingID = nil
            }
            if let section, input.visioArchive?.definitionRows?.contains(where: { source in
                source.sheetID == sheetID && source.rowID != editingID && source.address.section == section
                    && source.address.sectionIndex == nil && source.address.rowIndex == nil
                    && (name.map { proposed in source.address.rowName?.caseInsensitiveCompare(proposed) == .orderedSame } ?? (source.isSection == true))
                    && !sheet.rows.contains(where: { row in row.id == source.rowID })
                    && !(sheet.sections ?? []).contains(where: { section in section.id == source.rowID })
            }) == true {
                throw DiagramError.invalid("Choose a different name; this name is retained by the current source or undo history.")
            }
        }
        let next = try DefinitionRowEditing.proposal(edit, sheetID: sheetID, registry: registry)
        guard next != registry else { return input }
        return try applying(next, to: input)
    }

    private static func applying(_ proposed: DefinitionRegistry, to input: Diagram) throws -> Diagram {
        var registry = proposed
        // Capture unsaved instance edits before changing their inherited source.
        let prepared = try VisioPreservation.prepared(input)
        let parts = try patchedParts(registry, in: prepared.parts, sourceRows: prepared.definitionRows, bindings: prepared.pages)
        // Reference rewriting changes authored formulas as well as XML. Keep the
        // native registry and public projection in the same undo transaction.
        var valuesBySheet: [UUID: [DefinitionCellAddress: ShapeSheetCell]] = [:]
        _ = try DefinitionRowEditing.elements(registry, parts: parts) { sheet, element, _ in
            valuesBySheet[sheet.id] = Dictionary(DefinitionRegistry.sheet(element, scope: sheet.id, publicID: sheet.publicID).cells.map { ($0.address, $0.value) }, uniquingKeysWith: { a, _ in a })
        }
        registry.forEachEditableSheet { target in
            guard let values = valuesBySheet[target.id] else { return }
            for i in target.cells.indices { if let value = values[target.cells[i].address] { target.cells[i].value = value } }
        }
        var projectionInput = input
        projectionInput.visioArchive = prepared
        projectionInput.definitions = registry
        var projected = try project(parts, onto: projectionInput)
        projected.definitions = registry
        projected.visioArchive = input.visioArchive
        projected.legacySource = input.legacySource
        return try projected.validated()
    }

    static func patchedParts(_ registry: DefinitionRegistry?, in original: [String: Data],
                             sourceRows: [DefinitionSourceRow]? = nil, bindings: [VisioPageBinding] = [], checkingDeletedReferences: Bool = true) throws -> [String: Data] {
        guard let registry else { return original }
        let sources = sourceRows ?? DefinitionSourceRow.index(registry)
        try DefinitionSourceRow.validate(sources)
        var parts = try DefinitionRowEditing.patchRows(registry, parts: original, sources: sources)
        var documents: [String: XMLDocument] = [:]
        var masterSheets: [String: [String: XMLElement]] = [:]
        var styleSheets: [String: [String: XMLElement]] = [:]
        var changed = Set<String>()
        func document(_ part: String) throws -> XMLDocument {
            if let value = documents[part] { return value }
            guard let data = parts[part] else { throw DiagramError.invalid("A definition source part is missing: \(part).") }
            let value = try VisioXML.document(data); documents[part] = value; return value
        }
        func patch(_ sheet: DefinitionSheet, element: XMLElement, part: String) throws {
            let old = DefinitionRegistry.sheet(element, scope: sheet.id, publicID: sheet.publicID)
            let current = Dictionary(sheet.cells.map { ($0.address, $0.value) }, uniquingKeysWith: { first, _ in first })
            let prior = Dictionary(old.cells.map { ($0.address, $0.value) }, uniquingKeysWith: { first, _ in first })
            for address in Set(current.keys).union(prior.keys) where current[address] != prior[address] {
                guard !address.cell.isEmpty, address.cell.utf8.count <= 256 else { throw DiagramError.invalid("Invalid definition cell address.") }
                let owner = try cellOwner(address, in: element, create: current[address] != nil)
                let matches = owner?.elementsLocal("Cell").filter { $0.attr("N") == address.cell } ?? []
                guard matches.count <= 1 else { throw DiagramError.invalid("This definition contains an ambiguous cell address.") }
                if let value = current[address], let owner {
                    let cell = matches.first ?? XMLElement(name: "Cell")
                    if cell.parent == nil { owner.addChild(cell) }
                    cell.setAttr("N", address.cell); cell.setAttr("V", value.value)
                    cell.setAttr("F", value.formula.isEmpty ? nil : value.formula)
                    cell.setAttr("U", value.unit.isEmpty ? nil : value.unit)
                } else { matches.first?.detach() }
                changed.insert(part)
            }
        }
        if let sheet = registry.documentSheet,
           let root = try document(registry.documentPart).rootElement()?.firstLocal("DocumentSheet") {
            try patch(sheet, element: root, part: registry.documentPart)
        }
        for definition in registry.styles + registry.masters {
            try LifecycleJobContext.current?.checkpoint()
            guard let root = try document(definition.part).rootElement() else { throw DiagramError.invalid("A definition part has no root.") }
            if definition.kind == .style, styleSheets[definition.part] == nil {
                styleSheets[definition.part] = Dictionary((root.firstLocal("StyleSheets")?.elementsLocal("StyleSheet") ?? []).compactMap {
                    element in element.attr("ID").map { ($0, element) }
                }, uniquingKeysWith: { first, _ in first })
            } else if definition.kind == .master, masterSheets[definition.part] == nil {
                masterSheets[definition.part] = Dictionary((root.firstLocal("Shapes")?.allShapes ?? []).compactMap {
                    element in element.attr("ID").map { ($0, element) }
                }, uniquingKeysWith: { first, _ in first })
            }
            for sheet in definition.sheets {
                try LifecycleJobContext.current?.checkpoint()
                let element: XMLElement?
                if definition.kind == .style {
                    element = styleSheets[definition.part]?[definition.publicID]
                } else {
                    element = masterSheets[definition.part]?[sheet.publicID]
                }
                guard let element else { throw DiagramError.invalid("The public definition sheet is missing.") }
                try patch(sheet, element: element, part: definition.part)
            }
        }
        for part in changed { parts[part] = documents[part]!.xmlData(options: .nodePreserveAll) }
        return try DefinitionReferenceEditing.patch(registry, parts: parts, sources: sources, bindings: bindings, checkingDeletedReferences: checkingDeletedReferences)
    }

    private static func cellOwner(_ address: DefinitionCellAddress, in element: XMLElement,
                                  create: Bool) throws -> XMLElement? {
        guard let name = address.section else { return element }
        var section = element.elementsLocal("Section").first {
            $0.attr("N") == name && $0.attr("IX") == address.sectionIndex
        }
        if section == nil && create {
            let value = XMLElement(name: "Section"); value.setAttr("N", name)
            value.setAttr("IX", address.sectionIndex); element.addChild(value); section = value
        }
        guard let section else { return nil }
        guard address.rowName != nil || address.rowIndex != nil else { return section }
        var row = section.elementsLocal("Row").first {
            $0.attr("N") == address.rowName && $0.attr("IX") == address.rowIndex
        }
        if row == nil && create {
            let value = XMLElement(name: "Row"); value.setAttr("N", address.rowName)
            value.setAttr("IX", address.rowIndex); section.addChild(value); row = value
        }
        return row
    }

    /// Reconcile the importer's disposable identities with the current document's
    /// public page/sheet mappings. A projection never turns an unrelated object
    /// into a new native object merely because a definition changed.
    static func project(_ parts: [String: Data], onto input: Diagram, evaluate: Bool = true) throws -> Diagram {
        let imported = try VisioFormat.readPublic(parts: parts, title: input.title).diagram
        guard let oldArchive = input.visioArchive, var archive = imported.visioArchive else {
            throw DiagramError.invalid("Definition projection requires public page bindings.")
        }
        let oldBindings = Dictionary(oldArchive.pages.map { ($0.visioID, $0) }, uniquingKeysWith: { first, _ in first })
        var pages: [UUID: UUID] = [:]
        var objects: [UUID: UUID] = [:]
        for binding in archive.pages {
            guard let old = oldBindings[binding.visioID] else { continue }
            pages[binding.pageID] = old.pageID
            let nodeIDs = Dictionary(old.nodeIDs.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
            let edgeIDs = Dictionary(old.edgeIDs.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
            for (id, publicID) in binding.nodeIDs { if let prior = nodeIDs[publicID] { objects[id] = prior } }
            for (id, publicID) in binding.edgeIDs { if let prior = edgeIDs[publicID] { objects[id] = prior } }
        }
        let previousEdges = Dictionary(input.pages.flatMap(\.edges).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previousNodes = Dictionary(input.pages.flatMap(\.nodes).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previousPages = Dictionary(input.pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func fieldTokens(_ runs: [ShapeTextRun]?, from previous: [ShapeTextRun]?) -> [ShapeTextRun]? {
            var prior: [Int: [UUID]] = [:], seen = Set<UUID>()
            for run in previous ?? [] {
                if let field = run.fieldIndex, let token = run.fieldToken, seen.insert(token).inserted {
                    prior[field, default: []].append(token)
                }
            }
            var replacements: [UUID: UUID] = [:], positions: [Int: Int] = [:]
            return runs?.map { run in
                var run = run
                if let field = run.fieldIndex, let token = run.fieldToken {
                    if replacements[token] == nil {
                        let position = positions[field, default: 0]
                        if let tokens = prior[field], tokens.indices.contains(position) { replacements[token] = tokens[position] }
                        else { replacements[token] = token }
                        positions[field] = position + 1
                    }
                    run.fieldToken = replacements[token]
                }
                return run
            }
        }
        func remap(_ page: DiagramPage) -> DiagramPage {
            var value = page
            value.id = pages[page.id] ?? page.id
            value.backgroundPageID = page.backgroundPageID.map { pages[$0] ?? $0 }
            // Definition-cell changes do not alter the page's layer rows. The
            // prepared package preserves their order, including unsaved edits.
            if let prior = previousPages[value.id]?.layers, var layers = value.layers, prior.count == layers.count {
                for i in layers.indices { layers[i].id = prior[i].id }
                value.layers = layers
            }
            for i in value.nodes.indices {
                value.nodes[i].id = objects[value.nodes[i].id] ?? value.nodes[i].id
                value.nodes[i].parentID = value.nodes[i].parentID.map { objects[$0] ?? $0 }
                value.nodes[i].formatting.textRuns = fieldTokens(value.nodes[i].formatting.textRuns,
                    from: previousNodes[value.nodes[i].id]?.formatting.textRuns)
            }
            for i in value.edges.indices {
                value.edges[i].id = objects[value.edges[i].id] ?? value.edges[i].id
                let prior = previousEdges[value.edges[i].id]
                value.edges[i].source = objects[value.edges[i].source] ?? prior?.source ?? value.edges[i].source
                value.edges[i].target = objects[value.edges[i].target] ?? prior?.target ?? value.edges[i].target
                value.edges[i].parentID = value.edges[i].parentID.map { objects[$0] ?? $0 }
                if value.edges[i].formatting.textRuns != nil {
                    value.edges[i].formatting.textRuns = fieldTokens(value.edges[i].formatting.textRuns,
                        from: prior?.formatting.textRuns)
                }
            }
            return value
        }
        var result = imported
        result.pages = imported.pages.map(remap)
        result.activePageID = result.pages.contains(where: { $0.id == input.activePageID }) ? input.activePageID : result.pages[0].id
        result.title = input.title; result.definitions = input.definitions; result.legacySource = input.legacySource
        for index in archive.pages.indices {
            let old = archive.pages[index]
            archive.pages[index].pageID = pages[old.pageID] ?? old.pageID
            archive.pages[index].original = remap(old.original)
            archive.pages[index].nodeIDs = Dictionary(old.nodeIDs.map { (objects[$0.key] ?? $0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
            archive.pages[index].edgeIDs = Dictionary(old.edgeIDs.map { (objects[$0.key] ?? $0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
            if let inherited = old.inheritedShapes {
                archive.pages[index].inheritedShapes = Dictionary(inherited.map { id, entry in
                    var entry = entry; entry.parentID = objects[entry.parentID] ?? entry.parentID
                    return (objects[id] ?? id, entry)
                }, uniquingKeysWith: { first, _ in first })
            }
        }
        result.visioArchive = archive
        return evaluate ? try evaluated(result) : result
    }

    /// Undo can restore an untouched imported cache snapshot. Preserve that
    /// exact public projection as well as the editor's recalculated projection.
    static func baseline(_ parts: [String: Data], onto input: Diagram, matching pages: [DiagramPage]) throws -> Diagram {
        let cached = try project(parts, onto: input, evaluate: false)
        if cached.pages == pages { return cached }
        var result = try evaluated(cached)
        // Inherited caches belong to the new definition projection, while
        // authored instance caches still belong to the actual public package.
        // Comparing both as evaluated would omit local Value/Text cache updates
        // after TheDoc or another definition changes.
        let bindings = cached.visioArchive?.pages ?? []
        for pageIndex in result.pages.indices {
            let page = cached.pages[pageIndex]
            guard let binding = bindings.first(where: { $0.pageID == page.id }),
                  let data = parts[binding.part], let root = try VisioXML.document(data).rootElement() else { continue }
            let elements = Dictionary((root.firstLocal("Shapes")?.allShapes ?? []).compactMap { element in
                element.attr("ID").map { ($0, element) }
            }, uniquingKeysWith: { first,_ in first })
            func restore(_ detail: ShapeDetails, cached: ShapeDetails, element: XMLElement) -> ShapeDetails {
                var detail = detail
                let local = DefinitionRegistry.sheet(element, scope: input.pages[0].id, publicID: "")
                let aliases = local.cells.flatMap { cell in DefinitionSheetReferences.aliases(cell.address).map { ($0, cell.value) } }
                let localCells = Dictionary(aliases, uniquingKeysWith: { first,_ in first })
                for (key, cell) in cached.sheet {
                    if let authored = localCells[key], authored.formula == cell.formula,
                       let evaluated = detail.sheet[key], evaluated.hasSameAuthoredFormula(as: cell) {
                        detail.sheet[key] = cell
                    }
                }
                let localFieldCells = Dictionary(grouping: local.cells.filter { $0.address.section == "Field" },
                    by: { $0.address.rowIndex.flatMap(Int.init) })
                for index in (detail.textFields ?? []).indices {
                    if var field = detail.textFields?[index],
                       let original = cached.textFields?.first(where: { $0.index == field.index }) {
                        for authored in localFieldCells[field.index] ?? [] {
                            let key = authored.address.cell
                            if let raw = original.cells[key], let evaluated = field.cells[key],
                               authored.value.formula == raw.formula, evaluated.hasSameAuthoredFormula(as: raw) {
                                field.cells[key] = raw
                            }
                        }
                        detail.textFields?[index] = field
                    }
                }
                if element.firstLocal("Text") != nil { detail.textRuns = cached.textRuns }
                return detail
            }
            for index in result.pages[pageIndex].nodes.indices {
                let id = page.nodes[index].id
                guard result.pages[pageIndex].nodes[index].details != nil || page.nodes[index].details != nil else { continue }
                guard let source = binding.nodeIDs[id].flatMap({ elements[$0] }) else { continue }
                result.pages[pageIndex].nodes[index].details = restore(result.pages[pageIndex].nodes[index].formatting,
                    cached: page.nodes[index].formatting, element: source)
                if source.firstLocal("Text") != nil { result.pages[pageIndex].nodes[index].text = page.nodes[index].text }
            }
            for index in result.pages[pageIndex].edges.indices {
                let id = page.edges[index].id
                guard result.pages[pageIndex].edges[index].details != nil || page.edges[index].details != nil else { continue }
                guard let source = binding.edgeIDs[id].flatMap({ elements[$0] }) else { continue }
                let details = restore(result.pages[pageIndex].edges[index].formatting, cached: page.edges[index].formatting, element: source)
                if source.firstLocal("Text") != nil { result.pages[pageIndex].edges[index].label = page.edges[index].label }
                result.pages[pageIndex].edges[index].details = details
            }
        }
        return result
    }

    private static func evaluated(_ result: Diagram) throws -> Diagram {
        // Use the same evaluated inheritance baseline as the editor. Otherwise
        // recalculated inherited caches would be written back as local cells.
        try LifecycleJobContext.current?.checkpoint()
        guard let calculation = DiagramCalculation.calculate(result, cancellation: LifecycleJobContext.current?.cancellation) else {
            throw LifecycleJobError.cancelled
        }
        try LifecycleJobContext.current?.checkpoint()
        return calculation.diagram
    }
}
