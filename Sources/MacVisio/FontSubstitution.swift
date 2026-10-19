import Foundation

/// Rendering choices only. Requested names, run cells and source indices are
/// never rewritten. The native renderer must supply its installed-font catalog.
enum FontSubstitution {
    struct Catalog {
        var installedNames: [String]
        var preferredFallbacks: [String] = ["Arial", "Helvetica"]
        /// Explicit product/user policy; no fuzzy name or network lookup.
        var aliases: [String: [String]] = [:]
    }

    enum Reason: Equatable { case installed, alias, fallback, system }
    struct Resolution: Equatable {
        var requestedName: String
        /// `System` is a renderer sentinel, not a font name written to the file.
        var renderingName: String
        var reason: Reason
        var isSubstituted: Bool { reason != .installed && normalized(requestedName) != "system" }
    }
    struct Use: Equatable {
        enum Owner: Equatable { case shape(UUID), connector(UUID) }
        var pageID: UUID
        var owner: Owner
        /// nil means the owner's base style; empty/field runs still count.
        var runIndex: Int?

        init(pageID: UUID, nodeID: UUID, runIndex: Int?) {
            self.pageID = pageID; owner = .shape(nodeID); self.runIndex = runIndex
        }
        init(pageID: UUID, connectorID: UUID, runIndex: Int?) {
            self.pageID = pageID; owner = .connector(connectorID); self.runIndex = runIndex
        }
    }
    struct InventoryEntry: Equatable {
        var resolution: Resolution
        var uses: [Use]
    }

    static func resolve(_ requested: String, using catalog: Catalog) -> Resolution {
        var seen = Set<Data>()
        let names = catalog.installedNames.filter { seen.insert(Data($0.utf8)).inserted }.sorted(by: byteOrder)
        func installed(_ name: String) -> String? {
            names.first { $0.utf8.elementsEqual(name.utf8) } ?? names.first { normalized($0) == normalized(name) }
        }
        if normalized(requested) == "system" {
            return Resolution(requestedName: requested, renderingName: "System", reason: .system)
        }
        if let name = installed(requested) {
            return Resolution(requestedName: requested, renderingName: name, reason: .installed)
        }
        // Sorting keys also makes conflicting case variants in policy stable.
        for key in catalog.aliases.keys.sorted(by: byteOrder) where normalized(key) == normalized(requested) {
            for candidate in catalog.aliases[key] ?? [] {
                if let name = installed(candidate) {
                    return Resolution(requestedName: requested, renderingName: name, reason: .alias)
                }
            }
        }
        for candidate in catalog.preferredFallbacks {
            if normalized(candidate) == "system" {
                return Resolution(requestedName: requested, renderingName: "System", reason: .system)
            }
            if let name = installed(candidate) {
                return Resolution(requestedName: requested, renderingName: name, reason: .fallback)
            }
        }
        return Resolution(requestedName: requested, renderingName: "System", reason: .system)
    }

    /// Includes shape and connector base styles and every stored run. Exact UTF-8
    /// keys retain even canonically equivalent spellings as separate requests.
    static func inventory(in diagram: Diagram, using catalog: Catalog) -> [InventoryEntry] {
        var entries: [InventoryEntry] = []
        var indices: [Data: Int] = [:]
        func add(_ name: String, use: Use) {
            let key = Data(name.utf8)
            if let index = indices[key] { entries[index].uses.append(use) }
            else {
                indices[key] = entries.count
                entries.append(InventoryEntry(resolution: resolve(name, using: catalog), uses: [use]))
            }
        }
        for page in diagram.pages {
            for node in page.nodes {
                add(node.formatting.fontName, use: Use(pageID: page.id, nodeID: node.id, runIndex: nil))
                for (index, run) in (node.formatting.textRuns ?? []).enumerated() {
                    add(run.character.fontName, use: Use(pageID: page.id, nodeID: node.id, runIndex: index))
                }
            }
            for edge in page.edges {
                add(edge.formatting.fontName, use: Use(pageID: page.id, connectorID: edge.id, runIndex: nil))
                for (index, run) in (edge.formatting.textRuns ?? []).enumerated() {
                    add(run.character.fontName, use: Use(pageID: page.id, connectorID: edge.id, runIndex: index))
                }
            }
        }
        return entries.sorted { byteOrder($0.resolution.requestedName, $1.resolution.requestedName) }
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func byteOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}
