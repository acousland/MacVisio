import Foundation
import ImageIO

#if canImport(FoundationXML)
    import FoundationXML
#endif

/// Assessment uses immutable values only. The owner supplies the exact save
/// snapshot and the last successful source baseline, never a gesture preview.
enum DocumentSaveImpact {
    enum Format: Equatable { case native, visio, legacy }
    enum Feature: String {
        case signature, solution, foreignObject, masterRelation, failedFormula, actions, legacyReconstruction,
            unresolvedSource
    }
    struct Risk: Equatable {
        let feature: Feature
        let dimension: DocumentDiagnostic.Dimension
        let target: DocumentDiagnostic.Target
        let source: DocumentDiagnostic.Source
        let message: String
    }
    struct Assessment: Equatable {
        let risks: [Risk]
        var requiresReview: Bool { !risks.isEmpty }
    }
    struct Baseline {
        let snapshot: Diagram
    }
    struct UnsafeOverwrite: LocalizedError {
        let assessment: Assessment
        var errorDescription: String? {
            "This save may change unsupported source behavior. Save a separate copy or a native MacVisio file to preserve the original."
        }
        var recoverySuggestion: String? {
            "Choose Save As to another destination, or cancel and review Document Issues."
        }
    }
    enum Resolution {
        case cancel
        case copy(URL)
        case nativeCopy(URL)
    }

    static func assess(
        snapshot: Diagram, baseline: Baseline?, diagnostics: [DocumentDiagnostic], format: Format
    ) -> Assessment {
        guard format != .native else { return Assessment(risks: []) }
        var source = baseline?.snapshot ?? snapshot
        if baseline == nil, let archive = snapshot.visioArchive {
            source.pages = archive.pages.map(\.original)
        }
        var risks: [Risk] = []
        func append(
            _ feature: Feature, _ dimension: DocumentDiagnostic.Dimension,
            _ target: DocumentDiagnostic.Target, _ provenance: DocumentDiagnostic.Source,
            _ message: String
        ) {
            let risk = Risk(
                feature: feature, dimension: dimension, target: target, source: provenance, message: message)
            if !risks.contains(risk) { risks.append(risk) }
        }
        if format == .legacy {
            if let original = snapshot.legacySource,
                snapshot.pages == original.pages, snapshot.title == original.title
            {
                return Assessment(risks: [])
            }
            append(
                .legacyReconstruction, .behavior, .document, .init(feature: "legacy-reconstruction"),
                "Binary Visio output reconstructs graphics and text without full original formulas, data or connector glue semantics."
            )
            return Assessment(risks: risks)
        }
        guard let archive = source.visioArchive else { return Assessment(risks: []) }
        let originals = Dictionary(uniqueKeysWithValues: source.pages.map { ($0.id, $0) })
        let pages = Dictionary(uniqueKeysWithValues: snapshot.pages.map { ($0.id, $0) })
        let changed = snapshot.pages != source.pages || snapshot.title != source.title
        if archive.parts.keys.contains(where: { $0.lowercased().hasPrefix("_xmlsignatures/") }),
            changed || archive.parts["macvisio/document.json"] != nil
        {
            append(
                .signature, .preservation, .document, .init(feature: "digital-signature"),
                "Rewriting this signed package can invalidate its digital signature, including native metadata updates."
            )
        }
        if changed, archive.parts.keys.contains(where: { $0.lowercased().hasPrefix("visio/solutions/") }) {
            append(
                .solution, .behavior, .document, .init(feature: "solution"),
                "The package contains solution data whose behavior after these edits is not established.")
        }
        for binding in archive.pages {
            guard let old = originals[binding.pageID], pages[binding.pageID] != old else { continue }
            let current = pages[binding.pageID]
            let oldNodes = Dictionary(uniqueKeysWithValues: old.nodes.map { ($0.id, $0) })
            let nodes = Dictionary(uniqueKeysWithValues: (current?.nodes ?? []).map { ($0.id, $0) })
            guard let bytes = archive.parts[binding.part], let xml = try? VisioXML.document(bytes),
                let root = xml.rootElement()
            else {
                append(
                    .unresolvedSource, .interchange, .page(binding.pageID),
                    .init(part: binding.part, feature: "unresolved-page-source"),
                    "This changed page's preserved source could not be classified for save impact.")
                continue
            }
            let elements = Dictionary(
                (root.firstLocal("Shapes")?.allShapes ?? []).compactMap { element in
                    element.attr("ID").map { ($0, element) }
                },
                uniquingKeysWith: { first, _ in first })
            func inspectFeatures(
                _ element: XMLElement?, target: DocumentDiagnostic.Target, sourceID: String?,
                hasImportedBinding: Bool
            ) {
                guard let element else {
                    if hasImportedBinding, let sourceID {
                        append(
                            .unresolvedSource, .interchange, target,
                            .init(part: binding.part, visioID: sourceID, feature: "missing-bound-source"),
                            "An affected imported object's bound source element is missing; its preservation and interchange are unresolved."
                        )
                    }
                    return
                }
                let knownChildren: Set<String> = ["Cell", "Section", "Text", "Shapes", "ForeignData"]
                let knownSections: Set<String> = [
                    "Geometry", "Character", "Paragraph", "User", "Property", "Hyperlink", "Connection",
                    "Control", "Controls", "Field", "Actions",
                ]
                for child in (element.children ?? []).compactMap({ $0 as? XMLElement }) {
                    let name = child.localName ?? child.name ?? ""
                    if !knownChildren.contains(name) {
                        append(
                            .unresolvedSource, .interchange, target,
                            .init(part: binding.part, visioID: sourceID, feature: "Element:" + name),
                            "An affected source object contains an unclassified feature; its post-edit interchange is unresolved."
                        )
                    }
                }
                for section in element.elementsLocal("Section") {
                    let name = section.attr("N") ?? ""
                    if name == "Actions" {
                        append(
                            .actions, .behavior, target,
                            .init(part: binding.part, visioID: sourceID, feature: "Section:Actions"),
                            "This affected source object contains Actions behavior that MacVisio does not execute or qualify."
                        )
                        continue
                    } else if !knownSections.contains(name) {
                        append(
                            .unresolvedSource, .interchange, target,
                            .init(part: binding.part, visioID: sourceID, feature: "Section:" + name),
                            "An affected source object contains an unclassified section; its post-edit behavior is unresolved."
                        )
                        continue
                    }
                    for row in section.elementsLocal("Row") {
                        for cell in row.elementsLocal("Cell")
                        where formulaNeedsReview(cell.attr("F"), knownHost: knownSections.contains(name)) {
                            append(
                                .unresolvedSource, .behavior, target,
                                .init(
                                    part: binding.part, visioID: sourceID,
                                    feature: "Section:" + name + "/Row:"
                                        + (row.attr("N") ?? row.attr("IX") ?? "") + "/Cell:"
                                        + (cell.attr("N") ?? "")),
                                "An affected source section contains an unclassified formula; preserved cached values do not establish its behavior."
                            )
                        }
                    }
                }
                let knownCells = Set(
                    ShapeSheetEngine.geometryKeys + ShapeSheetEngine.textKeys + [
                        "FillForegnd", "FillPattern", "FillForegndTrans", "LineColor", "LinePattern",
                        "LineColorTrans",
                    ])
                for cell in element.elementsLocal("Cell") {
                    let name = cell.attr("N") ?? ""
                    if formulaNeedsReview(cell.attr("F"), knownHost: knownCells.contains(name)) {
                        append(
                            .unresolvedSource, .behavior, target,
                            .init(
                                part: binding.part, visioID: sourceID, cell: name.isEmpty ? nil : name,
                                feature: "unclassified-cell-formula"),
                            "An affected source cell has an unclassified formula or host context; its behavior is unresolved."
                        )
                    }
                }
            }
            for (id, original) in oldNodes where nodes[id] != original {
                let target = DocumentDiagnostic.Target.shape(page: binding.pageID, shape: id)
                let sourceID = binding.nodeIDs[id] ?? original.formatting.sourceShapeID
                let element = sourceID.flatMap { elements[$0] }
                inspectFeatures(
                    element, target: target, sourceID: sourceID,
                    hasImportedBinding: binding.nodeIDs[id] != nil)
                if let foreign = element?.firstLocal("ForeignData"),
                    !isSupportedBitmap(
                        foreign, original: original.formatting.image, current: nodes[id]?.formatting.image)
                {
                    append(
                        .foreignObject, .behavior, target,
                        .init(part: binding.part, visioID: sourceID, feature: "foreign-object"),
                        "An edited or removed foreign object may retain bytes without retaining its original behavior."
                    )
                }
                let inherited =
                    binding.inheritedShapes?[id] != nil || element?.attr("Master") != nil
                    || element?.attr("MasterShape") != nil
                if inherited,
                    nodes[id]?.parentID != original.parentID
                        || nodes[id]?.formatting.sheet != original.formatting.sheet
                {
                    append(
                        .masterRelation, .behavior, target,
                        .init(part: binding.part, visioID: sourceID, feature: "master-relation"),
                        "This edit changes a source master relationship or its cell overrides; inherited behavior needs review."
                    )
                }
            }
            for edge in old.edges where current?.edges.first(where: { $0.id == edge.id }) != edge {
                let sourceID = binding.edgeIDs[edge.id] ?? edge.sourceShapeID
                inspectFeatures(
                    sourceID.flatMap { elements[$0] },
                    target: .connector(page: binding.pageID, connector: edge.id), sourceID: sourceID,
                    hasImportedBinding: binding.edgeIDs[edge.id] != nil)
            }
        }
        for diagnostic in diagnostics
        where diagnostic.origin == .calculation
            && ["calculation.geometry.cell", "calculation.field.cell"].contains(diagnostic.code)
            && (diagnostic.displayState == .cached || diagnostic.displayState == .unavailable)
        {
            guard case .shape(let pageID, let shapeID) = diagnostic.target,
                let current = pages[pageID], let original = originals[pageID],
                current.nodes.first(where: { $0.id == shapeID })
                    != original.nodes.first(where: { $0.id == shapeID }),
                diagnostic.source.cell != nil
            else { continue }
            append(
                .failedFormula, .behavior, diagnostic.target, diagnostic.source,
                "An edited object has an unevaluated cell with cached output; source behavior cannot be confirmed."
            )
        }
        return Assessment(risks: risks)
    }

    /// Recognize only an ordinary supported bitmap wrapper with actual supplied
    /// PNG/JPEG bytes. Unknown foreign attributes/children stay under review.
    /// ImageIO inspects the in-memory source; no pixel decode, I/O or cache is used.
    private static func isSupportedBitmap(
        _ foreign: XMLElement, original: EmbeddedImage?, current: EmbeddedImage?
    ) -> Bool {
        guard foreign.attr("ForeignType") == "Bitmap",
            foreign.elementsLocal("Rel").count == 1,
            foreign.elementsLocal("Rel").first?.attributes?.contains(where: {
                ($0.localName ?? $0.name) == "id" && $0.stringValue?.isEmpty == false
            }) == true,
            foreign.attr("CompressionType").map({ ["PNG", "JPEG", "JPG"].contains($0) }) ?? true
        else { return false }
        let knownAttributes: Set<String> = [
            "ForeignType", "CompressionType", "CompressionLevel", "ExtentX", "ExtentY", "MappingMode",
        ]
        guard
            (foreign.attributes ?? []).allSatisfy({ knownAttributes.contains($0.localName ?? $0.name ?? "") }
            ),
            (foreign.children ?? []).compactMap({ $0 as? XMLElement }).allSatisfy({ child in
                (child.localName ?? child.name) == "Rel"
                    && (child.attributes ?? []).allSatisfy { ($0.localName ?? $0.name) == "id" }
            })
        else { return false }
        func supported(_ image: EmbeddedImage?) -> Bool {
            guard let image,
                let expected = ["image/png": "public.png", "image/jpeg": "public.jpeg"][image.mimeType],
                let source = CGImageSourceCreateWithData(
                    image.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                CGImageSourceGetType(source).map({ $0 as String }) == expected,
                CGImageSourceGetCount(source) == 1, CGImageSourceGetStatus(source) == .statusComplete,
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
                let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber
            else { return false }
            return width.doubleValue > 0 && height.doubleValue > 0
                && width.doubleValue * height.doubleValue <= 100_000_000
        }
        return supported(original) && supported(current)
    }

    /// This bounded source vocabulary mirrors names recognized by the accepted
    /// dependency/evaluator adapters. Recognition does not certify semantics or
    /// arity; real evaluator failures retain their separate risk records.
    private static func formulaNeedsReview(_ authored: String?, knownHost: Bool) -> Bool {
        guard let authored else { return false }
        let text = authored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !["INH", "NO FORMULA"].contains(text.uppercased()) else { return false }
        guard let expression = try? ShapeSheet.parse(text) else { return true }
        func literal(_ expression: ShapeSheet.Expression) -> Bool {
            switch expression {
            case .number, .measure, .string: return true
            case .unary(_, let value): return literal(value)
            default: return false
            }
        }
        if literal(expression) { return false }
        guard knownHost else { return true }
        let knownFunctions: Set<String> = [
            "PI", "ABS", "SQRT", "SIN", "COS", "TAN", "ASIN", "ACOS", "ATAN", "ATAN2", "LN", "EXP", "INT",
            "SIGN", "ROUND", "MODULUS", "DEG", "RAD", "POW", "MIN", "MAX", "SUM", "AND", "OR", "NOT", "IF",
            "IFERROR", "GUARD", "THEMEGUARD", "SETATREF", "SETATREFEXPR", "SETATREFEVAL", "BOUND", "REF",
            "STRSAME", "STRSAMEEX", "UPPER", "LOWER", "LEN", "LEFT", "RIGHT", "MID", "FIND", "REPLACE",
            "SUBSTITUTE", "REPT", "INDEX", "CHAR", "UNICHAR", "TRIM", "CONCATENATE", "FIELDPICTURE",
            "CEILING", "FLOOR", "RGB", "BITAND", "BITOR", "BITXOR", "HSL", "RED", "GREEN", "BLUE", "HUE",
            "SAT", "LUM", "LUMDIFF", "THEMEVAL", "THEMEPROP", "ISTHEMED", "SHAPETEXT", "TEXTWIDTH",
            "TEXTHEIGHT", "PAGENAME", "PAGENUMBER", "PAGECOUNT", "BKGPAGENAME", "ID", "DATE", "FORMAT",
            "NOW", "TODAY", "NURBS", "POLYLINE", "FONT",
        ]
        func unknown(_ expression: ShapeSheet.Expression) -> Bool {
            switch expression {
            case .number, .measure, .string, .reference, .omitted: return false
            case .unary(_, let value): return unknown(value)
            case .binary(_, let first, let second): return unknown(first) || unknown(second)
            case .call(let name, let arguments):
                return !knownFunctions.contains(name.uppercased()) || arguments.contains(where: unknown)
            }
        }
        return unknown(expression)
    }
}
