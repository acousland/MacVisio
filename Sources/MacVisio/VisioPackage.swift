import MacVisioInfrastructure
import Foundation
import ZIPFoundation

/// An OPC package kept in memory. Files are never extracted into the user's filesystem.
enum VisioPackage {
    static let partLimit = 16 * 1024 * 1024
    static let totalLimit = 128 * 1024 * 1024
    static func validatePath(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
              !name.contains("\0"), !name.contains("\r"), !name.contains("\n"), name.utf8.count <= 1024,
              !name.split(separator: "/").contains(".."), !name.split(separator: "/").contains(".") else {
            throw DiagramError.invalid("The package contains an unsafe part name.")
        }
    }
    static func read(_ url: URL) throws -> [String: Data] {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 100 * 1024 * 1024 else { throw DiagramError.invalid("The Visio archive exceeds the 100 MB import limit.") }
        let archive = try Archive(url: url, accessMode: .read)
        var parts: [String: Data] = [:], seen = Set<String>(), total = 0
        for entry in archive {
            try LifecycleJobContext.current?.checkpoint()
            let name = entry.path
            try validatePath(name)
            guard seen.insert(name).inserted, seen.count <= 10000, entry.type != .symlink else { throw DiagramError.invalid("The archive contains duplicate, linked or too many entries.") }
            if entry.type == .directory { continue }
            guard entry.type == .file, entry.uncompressedSize <= UInt64(partLimit) else { throw DiagramError.invalid("A Visio package part exceeds the supported size limit.") }
            var data = Data()
            let checksum = try archive.extract(entry, bufferSize: 65536, skipCRC32: false) { chunk in
                try LifecycleJobContext.current?.checkpoint()
                guard data.count + chunk.count <= partLimit, total + chunk.count <= totalLimit else { throw DiagramError.invalid("The Visio drawing exceeds the supported import size limit.") }
                data.append(chunk); total += chunk.count
            }
            guard checksum == entry.checksum else { throw DiagramError.invalid("A Visio package part failed its checksum.") }
            parts[name] = data
        }
        guard parts["[Content_Types].xml"] != nil, parts["_rels/.rels"] != nil else { throw DiagramError.invalid("This file is not an OPC Visio drawing.") }
        return parts
    }
    static func write(_ parts: [String: Data], to url: URL) throws {
        guard parts.count <= 10000, parts.values.allSatisfy({ $0.count <= partLimit }),
              parts.values.reduce(0, { $0 + $1.count }) <= totalLimit else { throw DiagramError.invalid("The drawing exceeds the Visio package size limit.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-package-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let temp = directory.appendingPathComponent("drawing.zip")
        do {
            let archive = try Archive(url: temp, accessMode: .create)
            for name in parts.keys.sorted() {
                try LifecycleJobContext.current?.checkpoint()
                try validatePath(name)
                let data = parts[name]!
                try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, count in
                    data.subdata(in: Int(position)..<min(data.count, Int(position)+count))
                }
            }
        }
        try Data(contentsOf: temp).write(to: url, options: .atomic)
    }
}

struct VisioDocumentArchive: Codable, Equatable {
    private var sourceParts: ImmutableVisioParts
    var parts: [String: Data] {
        get { sourceParts.parts }
        set { sourceParts = ImmutableVisioParts(newValue,lineageID:sourceParts.lineageID) }
    }
    var sourceResourceID: UUID { sourceParts.id }
    var sourceLineageID: UUID { sourceParts.lineageID }
    var sourceByteCount: Int { sourceParts.byteCount + definitionRowByteCount }
    var pagesPart: String
    var pages: [VisioPageBinding]
    var connectorHierarchyVersion:Int? = nil
    /// Stable row identities at the last successful public save; removed XML is retained for undo.
    var definitionRows: [DefinitionSourceRow]? = nil {
        didSet { definitionRowByteCount = Self.rowSourceCharge(definitionRows);definitionRowsResourceID = UUID() }
    }
    private(set) var definitionRowsResourceID = UUID()
    private var definitionRowByteCount = 0
    private static func rowSourceCharge(_ rows: [DefinitionSourceRow]?) -> Int {
        rows?.reduce(0) { $0 + 256 + $1.address.key.utf8.count + ($1.removedXML?.count ?? 0) } ?? 0
    }
    /// The Office theme selected through the document's theme relationship.
    /// The package parts remain authoritative for round-trip preservation.
    var theme: VisioTheme? = nil

    init(parts: [String: Data], pagesPart: String, pages: [VisioPageBinding], connectorHierarchyVersion: Int? = nil, theme: VisioTheme? = nil, lineageID: UUID = UUID()) {
        sourceParts = ImmutableVisioParts(parts, lineageID: lineageID)
        self.pagesPart = pagesPart
        self.pages = pages
        self.connectorHierarchyVersion = connectorHierarchyVersion
        self.theme = theme
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sourceParts == rhs.sourceParts && lhs.pagesPart == rhs.pagesPart && lhs.pages == rhs.pages
            && lhs.connectorHierarchyVersion == rhs.connectorHierarchyVersion && lhs.theme == rhs.theme
            && lhs.definitionRows == rhs.definitionRows
    }

    private enum CodingKeys: String, CodingKey {
        case parts, pagesPart, pages, connectorHierarchyVersion, theme, definitionRows
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sourceParts = ImmutableVisioParts(try values.decode([String: Data].self, forKey: .parts))
        pagesPart = try values.decode(String.self, forKey: .pagesPart)
        pages = try values.decode([VisioPageBinding].self, forKey: .pages)
        connectorHierarchyVersion = try values.decodeIfPresent(Int.self, forKey: .connectorHierarchyVersion)
        theme = try values.decodeIfPresent(VisioTheme.self, forKey: .theme)
        definitionRows = try values.decodeIfPresent([DefinitionSourceRow].self, forKey: .definitionRows)
        definitionRowByteCount = Self.rowSourceCharge(definitionRows)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(parts, forKey: .parts)
        try values.encode(pagesPart, forKey: .pagesPart)
        try values.encode(pages, forKey: .pages)
        try values.encodeIfPresent(connectorHierarchyVersion, forKey: .connectorHierarchyVersion)
        try values.encodeIfPresent(theme, forKey: .theme)
        try values.encodeIfPresent(definitionRows, forKey: .definitionRows)
    }
}

/// Snapshots share one immutable source store. Equality takes an identity fast
/// path while preserving the existing value contract for separately read data.
private final class ImmutableVisioParts: Equatable {
    let id = UUID()
    let lineageID: UUID
    let parts: [String: Data]
    let byteCount: Int

    init(_ parts: [String: Data],lineageID:UUID = UUID()) {
        self.lineageID = lineageID
        self.parts = parts
        byteCount = parts.values.reduce(0) { count, data in
            let sum = count.addingReportingOverflow(data.count)
            return sum.overflow ? Int.max : sum.partialValue
        }
    }

    static func == (lhs: ImmutableVisioParts, rhs: ImmutableVisioParts) -> Bool {
        lhs === rhs || lhs.parts == rhs.parts
    }
}

/// Imported theme metadata needed by ShapeSheet evaluation. `colors` contains
/// only concrete RGB values we can resolve without Office's system palette or
/// theme effects; `colorScheme` retains each DrawingML color node's base data.
/// Line matrix widths/caps are imported separately from the Visio lineEx
/// extension records; only the former currently have exact selector mapping.
struct VisioTheme: Codable, Equatable {
    var relationshipID: String
    var relationshipType: String
    var target: String
    var part: String
    var name: String?
    var colorSchemeName: String?
    var schemeIndex: Int?
    /// Effect-scheme selector stored in the Visio fmtSchemeEx extension.
    var effectSchemeIndex: Int?
    /// Connector-scheme selector stored in the Visio fmtConnectorSchemeEx extension.
    var connectorSchemeIndex: Int?
    var colorScheme: [String: VisioThemeColor] = [:]
    /// Ordered DrawingML line matrix entries. QuickStyleLineMatrix 1...6
    /// selects the corresponding one-based entry when it is present.
    var effectLineStyles: [VisioThemeLineStyle] = []
    var connectorLineStyles: [VisioThemeLineStyle] = []
    /// Visio lineEx records are retained as typed metadata. Their sequence
    /// offset relative to QuickStyleLineMatrix is not specified by the public
    /// schema, so the evaluator does not currently resolve these properties.
    var effectLineExtensions: [VisioThemeLineExtension] = []
    var connectorLineExtensions: [VisioThemeLineExtension] = []
    /// Visio's variation color schemes in their zero-based XML list order.
    var variationColorSchemes: [Int: [String: String]] = [:]
    /// Monotone attributes keyed by the same zero-based color scheme index.
    var variationColorSchemeMonotone: [Int: Bool] = [:]
    /// Variation styles in their zero-based XML list order.
    var variationStyleSchemes: [Int: VisioThemeVariationStyleScheme] = [:]
    /// PageSheet VariationColorIndex selected for a page-specific copy.
    var variationColorIndex: Int?
    /// PageSheet VariationStyleIndex selected for a page-specific copy.
    var variationStyleIndex: Int?
    /// Property-specific values are populated only when the package provides
    /// an explicit mapped value. Theme StyleSheet THEMEVAL() placeholders do
    /// not define such a value.
    var values: [String: ShapeSheetCell] = [:]
    /// Normalized RGB colors keyed as Dark, Light, BackgroundColor and
    /// AccentColor1...AccentColor6.
    var colors: [String: String] = [:]
}

extension VisioTheme {
    private enum CodingKeys:String,CodingKey {
        case relationshipID,relationshipType,target,part,name,colorSchemeName,schemeIndex
        case effectSchemeIndex,connectorSchemeIndex,colorScheme
        case effectLineStyles,connectorLineStyles,effectLineExtensions,connectorLineExtensions
        case variationColorSchemes,variationColorSchemeMonotone,variationStyleSchemes
        case variationColorIndex,variationStyleIndex,values,colors
    }

    init(from decoder:Decoder) throws {
        let container = try decoder.container(keyedBy:CodingKeys.self)
        relationshipID = try container.decode(String.self,forKey:.relationshipID)
        relationshipType = try container.decode(String.self,forKey:.relationshipType)
        target = try container.decode(String.self,forKey:.target)
        part = try container.decode(String.self,forKey:.part)
        name = try container.decodeIfPresent(String.self,forKey:.name)
        colorSchemeName = try container.decodeIfPresent(String.self,forKey:.colorSchemeName)
        schemeIndex = try container.decodeIfPresent(Int.self,forKey:.schemeIndex)
        effectSchemeIndex = try container.decodeIfPresent(Int.self,forKey:.effectSchemeIndex)
        connectorSchemeIndex = try container.decodeIfPresent(Int.self,forKey:.connectorSchemeIndex)
        colorScheme = try container.decodeIfPresent([String:VisioThemeColor].self,forKey:.colorScheme) ?? [:]
        effectLineStyles = try container.decodeIfPresent([VisioThemeLineStyle].self,forKey:.effectLineStyles) ?? []
        connectorLineStyles = try container.decodeIfPresent([VisioThemeLineStyle].self,forKey:.connectorLineStyles) ?? []
        effectLineExtensions = try container.decodeIfPresent([VisioThemeLineExtension].self,forKey:.effectLineExtensions) ?? []
        connectorLineExtensions = try container.decodeIfPresent([VisioThemeLineExtension].self,forKey:.connectorLineExtensions) ?? []
        variationColorSchemes = try container.decodeIfPresent([Int:[String:String]].self,forKey:.variationColorSchemes) ?? [:]
        variationColorSchemeMonotone = try container.decodeIfPresent([Int:Bool].self,forKey:.variationColorSchemeMonotone) ?? [:]
        variationStyleSchemes = try container.decodeIfPresent([Int:VisioThemeVariationStyleScheme].self,forKey:.variationStyleSchemes) ?? [:]
        variationColorIndex = try container.decodeIfPresent(Int.self,forKey:.variationColorIndex)
        variationStyleIndex = try container.decodeIfPresent(Int.self,forKey:.variationStyleIndex)
        values = try container.decodeIfPresent([String:ShapeSheetCell].self,forKey:.values) ?? [:]
        colors = try container.decodeIfPresent([String:String].self,forKey:.colors) ?? [:]
    }
}

struct VisioThemeLineStyle: Codable, Equatable {
    /// DrawingML line width in EMUs (914,400 EMUs per inch).
    var widthEMU: Int?
    /// DrawingML cap token (`rnd`, `sq`, or another preserved token).
    var cap: String?
}

struct VisioThemeLineExtension: Codable, Equatable {
    var roundingEMU: Int?
    var beginArrow: Int?
    var beginSize: Int?
    var endArrow: Int?
    var endSize: Int?
}

struct VisioThemeColor: Codable, Equatable {
    /// DrawingML color node, such as `srgbClr` or `sysClr`.
    var type: String
    var value: String?
    /// DrawingML `lastClr`, commonly the concrete fallback for `sysClr`.
    var lastColor: String?
}

struct VisioThemeVariationStyleScheme: Codable, Equatable {
    var embellishment: Int?
    var styles: [VisioThemeVariationStyle] = []
}

struct VisioThemeVariationStyle: Codable, Equatable {
    var fillIndex: Int?
    var lineIndex: Int?
    var effectIndex: Int?
    var fontIndex: Int?
}

struct VisioPageBinding: Codable, Equatable {
    var pageID: UUID
    var visioID: String
    var part: String
    var original: DiagramPage
    var nodeIDs: [UUID: String]
    var edgeIDs: [UUID: String]
    // Model-only descendants do not have a page XML element until edited. Keep
    // their master identity so a save can emit a local override, not a duplicate.
    var inheritedShapes: [UUID: VisioInheritedShape]? = nil
}

struct VisioInheritedShape: Codable, Equatable {
    var masterShapeID: String
    var parentID: UUID
    var implicit: Bool
}
