import Foundation
import MacVisioInfrastructure

/// Rewrite resolved named-row references, preserving strings and unrelated owners.
/// The source row index supplies old addresses even after a saved rename is undone.
enum DefinitionReferenceEditing {
    private struct Change {
        var sheetID: UUID
        var section: String
        var old: String
        var new: String?
    }
    private struct Host {
        var sheetID: UUID?
        var inheritedSheetID: UUID?
        var localRows: Set<String>
        var parent: String?
    }

    static func patch(_ registry: DefinitionRegistry, parts: [String: Data], sources: [DefinitionSourceRow],
                      bindings: [VisioPageBinding], checkingDeletedReferences: Bool = true, rewritingRenames: Bool = true) throws -> [String: Data] {
        let targets = Dictionary(registry.editableSheets.flatMap { sheet in sheet.rows.map { ($0.id, (sheet.id, $0)) } }, uniquingKeysWith: { a, _ in a })
        let changes: [Change] = sources.compactMap { source in
            guard source.removedXML == nil, let name = source.address.rowName, source.address.rowIndex == nil,
                  source.address.sectionIndex == nil, let section = source.address.section,
                  ["User", "Property"].contains(section) else { return nil }
            let target = targets[source.rowID]?.1
            guard target?.name != name else { return nil }
            return Change(sheetID: source.sheetID, section: section == "Property" ? "Prop" : section, old: name, new: target?.name)
        }
        guard !changes.isEmpty else { return parts }
        let bySheet = Dictionary(grouping: changes, by: \.sheetID)
        let indexed = bySheet.mapValues { Dictionary($0.map { (($0.section + "." + $0.old).lowercased(), $0) }, uniquingKeysWith: { a, _ in a }) }
        var result = parts
        var documents: [String: XMLDocument] = [:]
        var touched = Set<String>()
        func document(_ part: String) throws -> XMLDocument {
            if let value = documents[part] { return value }
            guard let data = parts[part] else { throw DiagramError.invalid("A reference source part is missing.") }
            let value = try VisioXML.document(data); documents[part] = value; return value
        }
        func localRows(_ element: XMLElement) -> Set<String> {
            Set(element.elementsLocal("Section").flatMap { section in
                section.elementsLocal("Row").compactMap { row in
                    guard let name = row.attr("N"), let section = section.attr("N") else { return nil }
                    return ((section == "Property" ? "Prop" : section) + "." + name).lowercased()
                }
            })
        }
        func rewrite(_ element: XMLElement, host: Host, scope: [String: Host], part: String) throws {
            // Only Cell formula attributes are executable. Text, arbitrary XML
            // attributes and quoted formula literals are never search-replaced.
            func visit(_ owner: XMLElement) throws {
                for cell in owner.elementsLocal("Cell") {
                    guard let formula = cell.attr("F"), !formula.isEmpty else { continue }
                    let updated = try replacingIdentifiers(in: formula) { token in
                        let pieces = token.split(separator: "!", omittingEmptySubsequences: false).map(String.init)
                        guard pieces.count <= 2, let local = pieces.last else { return token }
                        let reference = local.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
                        guard reference.count >= 2 else { return token }
                        let key = (reference[0] + "." + reference[1]).lowercased()
                        let target: UUID?
                        let targetHost: Host?
                        if pieces.count == 1 { targetHost = host; target = nil }
                        else if pieces[0].caseInsensitiveCompare("TheDoc") == .orderedSame { targetHost = nil; target = registry.documentSheet?.id }
                        else if pieces[0].caseInsensitiveCompare("ParentShape") == .orderedSame { targetHost = host.parent.flatMap { scope[$0] }; target = nil }
                        else if pieces[0].lowercased().hasPrefix("sheet.") { targetHost = UInt32(pieces[0].dropFirst(6)).flatMap { scope[String($0)] }; target = nil }
                        else { return token }
                        let resolved = target ?? targetHost?.sheetID ?? (targetHost?.localRows.contains(key) == true ? nil : targetHost?.inheritedSheetID)
                        guard let resolved, let change = indexed[resolved]?[key] else { return token }
                        guard let name = change.new else {
                            guard checkingDeletedReferences else { return token }
                            throw DiagramError.invalid("The row \(change.section).\(change.old) is still referenced by a formula in \(part). Remove its references before deleting it.")
                        }
                        guard rewritingRenames else { return token }
                        var renamed = reference; renamed[1] = name
                        return (pieces.count == 2 ? pieces[0] + "!" : "") + renamed.joined(separator: ".")
                    }
                    if updated != formula { cell.setAttr("F", updated); touched.insert(part) }
                }
                for child in (owner.children ?? []).compactMap({ $0 as? XMLElement }) where child.localName != "Shapes" && child.localName != "Shape" {
                    try visit(child)
                }
            }
            try visit(element)
        }
        let root = try document(registry.documentPart).rootElement()
        if let sheet = registry.documentSheet, let element = root?.firstLocal("DocumentSheet") {
            try rewrite(element, host: Host(sheetID: sheet.id, localRows: [], parent: nil), scope: [:], part: registry.documentPart)
        }
        for style in registry.styles {
            if let sheet = style.sheets.first, let element = root?.firstLocal("StyleSheets")?.elementsLocal("StyleSheet").first(where: { $0.attr("ID") == style.publicID }) {
                try rewrite(element, host: Host(sheetID: sheet.id, localRows: [], parent: nil), scope: [:], part: style.part)
            }
        }
        for master in registry.masters {
            let elements = try document(master.part).rootElement()?.firstLocal("Shapes")?.allShapes ?? []
            let byID = Dictionary(master.sheets.map { ($0.publicID, $0) }, uniquingKeysWith: { a, _ in a })
            let scope = Dictionary(elements.compactMap { element -> (String, Host)? in
                guard let id = element.attr("ID"), let sheet = byID[id] else { return nil }
                return (id, Host(sheetID: sheet.id, localRows: [], parent: sheet.parentID.flatMap { parent in master.sheets.first { $0.id == parent }?.publicID }))
            }, uniquingKeysWith: { a, _ in a })
            for element in elements {
                if let host = element.attr("ID").flatMap({ scope[$0] }) { try rewrite(element, host: host, scope: scope, part: master.part) }
            }
        }
        let masterSheets = Dictionary(registry.masters.map { master in
            (master.id, Dictionary(master.sheets.map { ($0.publicID, $0.id) }, uniquingKeysWith: { a, _ in a }))
        }, uniquingKeysWith: { a, _ in a })
        let uses = Dictionary(grouping: registry.uses, by: \.pageID)
        for binding in bindings {
            try LifecycleJobContext.current?.checkpoint()
            let elements = try document(binding.part).rootElement()?.firstLocal("Shapes")?.allShapes ?? []
            let publicIDs = binding.nodeIDs.merging(binding.edgeIDs, uniquingKeysWith: { a, _ in a })
            var scope: [String: Host] = [:]
            for use in uses[binding.pageID] ?? [] {
                guard let id = publicIDs[use.objectID] else { continue }
                scope[id] = Host(inheritedSheetID: use.masterID.flatMap { owner in use.masterShapeID.flatMap { masterSheets[owner]?[$0] } },
                    localRows: Set(use.localSheet.rows.compactMap { row in row.name.map { ((row.section == "Property" ? "Prop" : row.section) + "." + $0).lowercased() } }), parent: nil)
            }
            for element in elements {
                guard let id = element.attr("ID") else { continue }
                var host = scope[id] ?? Host(localRows: [], parent: nil)
                host.localRows = localRows(element)
                if checkingDeletedReferences, let inherited = host.inheritedSheetID {
                    for section in element.elementsLocal("Section") where section.attr("IX") == nil {
                        guard let name = section.attr("N") else { continue }
                        let prefix = name == "Property" ? "Prop" : name
                        for override in section.elementsLocal("Row") where override.attr("IX") == nil {
                            guard let name = override.attr("N"), let change = indexed[inherited]?[(prefix + "." + name).lowercased()] else { continue }
                            let value = override.elementsLocal("Cell").first { $0.attr("N")?.caseInsensitiveCompare("Value") == .orderedSame }
                            let inheritedValue = value == nil || value?.attr("V")?.caseInsensitiveCompare("Inh") == .orderedSame || value?.attr("F")?.caseInsensitiveCompare("Inh") == .orderedSame
                            if inheritedValue || ["1","true"].contains(override.attr("Del") ?? "") {
                                throw DiagramError.invalid("Instance Sheet.\(id) has an inherited or suppressed override of \(change.section).\(change.old). Review that override before renaming or deleting the definition row.")
                            }
                        }
                    }
                }
                host.parent = (element.parent?.parent as? XMLElement)?.attr("ID")
                scope[id] = host
            }
            for element in elements {
                if let host = element.attr("ID").flatMap({ scope[$0] }) { try rewrite(element, host: host, scope: scope, part: binding.part) }
            }
            // Page-sheet formulas can refer to TheDoc and page-local Sheet.N.
            if let page = try document(registryDocumentPagesPart(bindings, registry: registry, parts: parts)).rootElement()?.elementsLocal("Page").first(where: { $0.attr("ID") == binding.visioID })?.firstLocal("PageSheet") {
                let indexPart = registryDocumentPagesPart(bindings, registry: registry, parts: parts)
                try rewrite(page, host: Host(localRows: [], parent: nil), scope: scope, part: indexPart)
            }
        }
        for part in touched { result[part] = documents[part]?.xmlData(options: .nodePreserveAll) }
        return result
    }

    private static func registryDocumentPagesPart(_ bindings: [VisioPageBinding], registry: DefinitionRegistry, parts: [String: Data]) -> String {
        // The relationship, rather than a conventional filename, owns this path.
        (try? DefinitionRegistry.relatedPart(parts, source: registry.documentPart, type: "pages")) ?? "visio/pages/pages.xml"
    }

    static func replacingIdentifiers(in formula: String, transform: (String) throws -> String) rethrows -> String {
        let characters = Array(formula)
        var result = "", index = 0
        while index < characters.count {
            if characters[index] == "\"" {
                result.append(characters[index]); index += 1
                while index < characters.count {
                    let character = characters[index]; result.append(character); index += 1
                    if character == "\"" {
                        if index < characters.count, characters[index] == "\"" { result.append(characters[index]); index += 1 }
                        else { break }
                    }
                }
            } else if characters[index].isLetter || characters[index] == "_" {
                let start = index; index += 1
                while index < characters.count {
                    let character = characters[index]
                    if character.isLetter || character.isNumber || "_.[]".contains(character) || (character == "!" && (index + 1 == characters.count || characters[index + 1] != "=")) { index += 1 }
                    else { break }
                }
                result += try transform(String(characters[start..<index]))
            } else { result.append(characters[index]); index += 1 }
        }
        return result
    }
}
