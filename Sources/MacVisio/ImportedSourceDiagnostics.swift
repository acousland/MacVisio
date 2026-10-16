import Foundation

/// Re-establish current source facts on native-envelope/native-file reads. This
/// runs once during opening/rebase, never from paint, status or AX getters. It
/// does not run formulas, invoke an importer helper, or store derived issues in
/// semantic model metadata. Unknown source remains explicitly unclassified.
enum ImportedSourceDiagnostics {
    static let cachedPolicyMessage = "Saved ShapeSheet values are used on open. Supported numeric formulas recalculate after edits; other formulas retain their source and cached values. Data links, macros and advanced effects are not executed."

    static func scan(_ diagram: Diagram) -> [DocumentDiagnostic] {
        var records = ImagePreviewDiagnostics.records(in: diagram)
        guard let archive = diagram.visioArchive else { return records }
        let pages = Dictionary(diagram.pages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for binding in archive.pages {
            guard let page = pages[binding.pageID] else { continue }
            let nodes = Dictionary(page.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            let nodeIDs = Dictionary(binding.nodeIDs.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
            let edgeIDs = Dictionary(binding.edgeIDs.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
            func emit(_ code: String, _ message: String, sourceID: String? = nil, cell: String? = nil,
                      feature: String? = nil, dimension: DocumentDiagnostic.Dimension = .rendering) {
                let target: DocumentDiagnostic.Target
                if let sourceID, let id = nodeIDs[sourceID], nodes[id] != nil { target = .shape(page: page.id, shape: id) }
                else if let sourceID, let id = edgeIDs[sourceID], page.edges.contains(where: { $0.id == id }) { target = .connector(page: page.id, connector: id) }
                else { target = .page(page.id) }
                records.append(DocumentDiagnostic(code: code, origin: .importer, severity: .warning, dimension: dimension,
                    target: target, source: .init(part: binding.part, visioID: sourceID, cell: cell, feature: feature),
                    displayState: .cached, message: message, requestedActions: [.revealTarget, .viewDetails]))
            }
            guard let data = archive.parts[binding.part], let root = try? VisioXML.document(data).rootElement() else {
                emit("import.source-inspection", "The preserved page source could not be inspected for native display limitations.", feature: "unclassified-page", dimension: .interchange)
                continue
            }
            for shape in root.firstLocal("Shapes")?.allShapes ?? [] {
                let sourceID = shape.attr("ID")
                let node = sourceID.flatMap { nodeIDs[$0] }.flatMap { nodes[$0] }
                if let pattern = Double(VisioXML.value(shape, "FillPattern") ?? ""), pattern > 1 {
                    emit("import.fill-pattern", "Gradients and fill patterns are approximated by solid colors.", sourceID: sourceID, cell: "FillPattern")
                }
                for key in ["Width", "Height"] where Double(VisioXML.value(shape, key) ?? "") == 0 {
                    emit("import.zero-axis", "Zero-size shape axes use a minimal editing frame; original public dimensions remain preserved in the source package.", sourceID: sourceID, cell: key)
                }
                for section in shape.elementsLocal("Section") {
                    switch section.attr("N") {
                    case "Actions":
                        emit("import.ignored-shape-action", "Imported shape actions are preserved but not executed.", sourceID: sourceID, feature: "Actions", dimension: .behavior)
                    case "Character":
                        for row in section.elementsLocal("Row") {
                            if let size = Double(VisioXML.value(row, "Size") ?? ""), size*72 < 1 || size*72 > 500 {
                                emit("import.font-size", "Text sizes outside the supported range were clamped.", sourceID: sourceID, cell: "Char.Size", feature: row.attr("IX"))
                            }
                        }
                    case "Connection":
                        for row in section.elementsLocal("Row") {
                            let index = row.attr("IX").flatMap(UInt32.init)
                            if index.flatMap({ i in node?.formatting.connectionPoints.first { $0.index == i } }) != nil { continue }
                            if Double(VisioXML.value(row, "X") ?? "") == nil || Double(VisioXML.value(row, "Y") ?? "") == nil {
                                emit("import.connection-point", "An unsupported connection point retains its source XML but cannot be edited.", sourceID: sourceID, feature: "Connection."+(row.attr("IX") ?? row.attr("N") ?? "unknown"), dimension: .editing)
                            }
                        }
                    case "Geometry":
                        let handled: Set<String> = ["MoveTo","RelMoveTo","LineTo","RelLineTo","PolylineTo","PolyLineTo","NURBSTo","CubBezTo","RelCubBezTo","QuadBezTo","RelQuadBezTo","EllipticalArcTo","RelEllipticalArcTo","Ellipse","ArcTo","SplineStart","SplineKnot"]
                        for row in section.elementsLocal("Row") {
                            guard let type = row.attr("T"), !type.isEmpty, !handled.contains(type), row.attr("Del") != "1" else { continue }
                            emit("import.geometry-row", "Unsupported geometry rows retain their source but have a partial native preview.", sourceID: sourceID,
                                 feature: "Geometry.\(section.attr("IX") ?? "0").Row.\(row.attr("IX") ?? "unknown").\(type)")
                        }
                    default: break
                    }
                }
                if shape.firstLocal("ForeignData") != nil, node?.formatting.image == nil {
                    emit("import.foreign-object", "An embedded OLE/WMF/EMF object is preserved in the file but cannot be rendered natively.", sourceID: sourceID, feature: "ForeignData")
                }
                for field in node?.formatting.textFields ?? [] where field.cells.isEmpty {
                    emit("import.text-field", "An unresolved text field retains its cached display.", sourceID: sourceID, feature: "Field.\(field.index)", dimension: .behavior)
                }
                let complexTypes: Set<String> = ["NURBSTo", "PolylineTo", "PolyLineTo", "SplineStart", "SplineKnot", "EllipticalArcTo", "RelEllipticalArcTo"]
                if let node, let definitions = node.formatting.geometry,
                   definitions.contains(where: { $0.rows.contains { complexTypes.contains($0.type) } }) {
                    _ = VisioFormat.geometryPaths(definitions, width: node.sheetWidth/72, height: node.sheetHeight/72, onIssue: { issue in
                        emit("import.geometry-row", issue.error, sourceID: sourceID,
                             feature: "Geometry.\(issue.section).Row.\(issue.row).\(issue.type)")
                    })
                }
            }
        }
        let documentPart = try? VisioReusableFormat.documentPart(archive.parts)
        let hasEvents = documentPart.flatMap { archive.parts[$0] }.flatMap { try? VisioXML.document($0).rootElement()?.firstLocal("EventList") } != nil
        if hasEvents || archive.parts.keys.contains(where: { $0.lowercased().contains("vbaproject") }) {
            records.append(DocumentDiagnostic(code: "import.ignored-actions", origin: .importer, severity: .warning,
                dimension: .behavior, target: .document, source: .init(part: documentPart, feature: "macros-events"),
                displayState: .notApplicable, message: "Macros and document events are ignored."))
        }
        records.append(DocumentDiagnostic(code: "import.cached-policy", origin: .importer, severity: .information,
            dimension: .behavior, target: .document, source: .init(part: documentPart, feature: "cached-policy"),
            displayState: .cached, message: cachedPolicyMessage))
        var seen = Set<DocumentDiagnostic.ID>()
        return records.filter { seen.insert($0.id).inserted }
    }
}
