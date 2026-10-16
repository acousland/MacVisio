import Foundation
import MacVisioInfrastructure

/// Definition edits are immutable proposals. Public parts produce the updated
/// instance projection; native IDs, local overrides and the original save
/// baseline remain owned by the document transaction.
enum DefinitionEditing {
    static func settingCell(in input: Diagram, sheetID: UUID, address: DefinitionCellAddress,
                            value: ShapeSheetCell?) throws -> Diagram {
        guard var registry = input.definitions, input.visioArchive != nil else {
            throw DiagramError.invalid("This drawing has no public definition source.")
        }
        var found = false
        if registry.documentSheet?.id == sheetID {
            registry.documentSheet?.set(address, to: value)
            found = true
        }
        for index in registry.masters.indices {
            if let sheet = registry.masters[index].sheets.firstIndex(where: { $0.id == sheetID }) {
                registry.masters[index].sheets[sheet].set(address, to: value); found = true
            }
        }
        for index in registry.styles.indices {
            if let sheet = registry.styles[index].sheets.firstIndex(where: { $0.id == sheetID }) {
                registry.styles[index].sheets[sheet].set(address, to: value); found = true
            }
        }
        guard found else { throw DiagramError.invalid("The definition sheet is no longer available.") }
        try registry.validate()
        guard registry != input.definitions else { return input }
        // Capture unsaved instance edits before changing their inherited source.
        let prepared = try VisioPreservation.prepared(input)
        let parts = try patchedParts(registry, in: prepared.parts)
        var projectionInput = input
        projectionInput.visioArchive = prepared
        var projected = try project(parts, onto: projectionInput)
        projected.definitions = registry
        projected.visioArchive = input.visioArchive
        projected.legacySource = input.legacySource
        return try projected.validated()
    }

    static func patchedParts(_ registry: DefinitionRegistry?, in original: [String: Data]) throws -> [String: Data] {
        guard let registry else { return original }
        var parts = original
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
        return parts
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
        let previousPages = Dictionary(input.pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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
            }
            for i in value.edges.indices {
                value.edges[i].id = objects[value.edges[i].id] ?? value.edges[i].id
                let prior = previousEdges[value.edges[i].id]
                value.edges[i].source = objects[value.edges[i].source] ?? prior?.source ?? value.edges[i].source
                value.edges[i].target = objects[value.edges[i].target] ?? prior?.target ?? value.edges[i].target
                value.edges[i].parentID = value.edges[i].parentID.map { objects[$0] ?? $0 }
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
        return try evaluated(cached)
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
