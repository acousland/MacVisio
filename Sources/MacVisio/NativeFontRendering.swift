import AppKit

/// Main-thread renderer policy. The catalog is local; no font is downloaded,
/// and selecting a fallback never changes the requested name in the model.
enum NativeFontRendering {
    private static var retainedCatalog: FontSubstitution.Catalog?
    private static var resolutions: [String: FontSubstitution.Resolution] = [:]

    static var catalog: FontSubstitution.Catalog {
        if let retainedCatalog { return retainedCatalog }
        let result = FontSubstitution.Catalog(
            installedNames: NSFontManager.shared.availableFonts + NSFontManager.shared.availableFontFamilies,
            preferredFallbacks: ["Arial", "Helvetica", "System"],
            aliases: ["Calibri": ["Carlito", "Arial", "Helvetica"], "Aptos": ["Arial", "Helvetica"]])
        retainedCatalog = result
        return result
    }

    static func refreshCatalog() {
        retainedCatalog = nil
        resolutions.removeAll(keepingCapacity: true)
    }

    static func resolution(for requested: String) -> FontSubstitution.Resolution {
        if let result = resolutions[requested] { return result }
        let result = FontSubstitution.resolve(requested, using: catalog)
        if resolutions.count >= 512 { resolutions.removeAll(keepingCapacity: true) }
        resolutions[requested] = result
        return result
    }

    static func font(requested: String, size: Double, bold: Bool = false, italic: Bool = false) -> NSFont {
        let resolved = resolution(for: requested)
        var font = resolved.renderingName == "System" ? NSFont.systemFont(ofSize: size)
            : NSFont(name: resolved.renderingName, size: size) ?? NSFont.systemFont(ofSize: size)
        if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }
}

enum DrawingContentChecks {
    static func evaluate(_ diagram: Diagram, catalog: FontSubstitution.Catalog, inputKey: String) -> [DocumentDiagnostic] {
        var records: [DocumentDiagnostic] = []
        for entry in FontSubstitution.inventory(in: diagram, using: catalog) where entry.resolution.isSubstituted {
            for use in entry.uses {
                records.append(DocumentDiagnostic(
                    code: "font.substituted", origin: .font, severity: .warning, dimension: .rendering,
                    target: .shape(page: use.pageID, shape: use.nodeID),
                    source: .init(cell: "Character.Font", feature: "font:\(entry.resolution.requestedName):\(use.runIndex.map(String.init) ?? "base")"),
                    displayState: .evaluated,
                    message: "Requested font “\(entry.resolution.requestedName)” renders with “\(entry.resolution.renderingName)”. The requested name is preserved.",
                    inputKey: inputKey, requestedActions: [.revealTarget, .viewDetails]))
            }
        }
        for page in diagram.pages {
            for node in page.nodes where BasicFlowchart.isOffPage(node) && BasicFlowchart.targetID(for: node, in: diagram) == nil {
                records.append(DocumentDiagnostic(code: "content.offpage-destination", origin: .content, severity: .warning,
                    dimension: .behavior, target: .shape(page: page.id, shape: node.id), source: .init(feature: BasicFlowchart.targetPageKey),
                    displayState: .unavailable,
                    message: "This off-page link has no unique current destination. Select it and use Insert Off-page Link to choose another page.",
                    inputKey: inputKey, requestedActions: [.revealTarget, .viewDetails]))
            }
            for node in page.nodes where node.formatting.image != nil && page.isVisible(node) {
                let described = !node.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || node.formatting.data.contains { property in
                        ["alttext", "accessibilitydescription"].contains(property.key.lowercased())
                            && !property.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                if !described {
                    records.append(DocumentDiagnostic(
                        code: "content.image-description", origin: .content, severity: .warning,
                        dimension: .editing, target: .shape(page: page.id, shape: node.id),
                        displayState: .notApplicable,
                        message: "This image has no text description. Add descriptive text or an AltText Shape Data value, or review whether it is decorative.",
                        inputKey: inputKey, requestedActions: [.revealTarget, .viewDetails]))
                }
            }
        }
        return records
    }
}

extension EditorWindowController {
    @objc func checkDrawingContent(_ sender: Any?) {
        diagramDocument.commitTextEditing()
        guard !diagramDocument.isCalculating else {
            root.status.stringValue = "Wait for the current edit to finish, then check the drawing."
            return
        }
        NativeFontRendering.refreshCatalog()
        let key = diagramDocument.diagnosticInputKey
        let records = DrawingContentChecks.evaluate(diagramDocument.diagram, catalog: NativeFontRendering.catalog, inputKey: key)
        _ = diagramDocument.setSupplementalDiagnostics(records, inputKey: key)
        showDocumentIssues(sender)
    }
}
