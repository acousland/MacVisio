import AppKit
import UniformTypeIdentifiers

extension MacVisioDocument {
    /// Capture committed counts and accepted current diagnostics together on the
    /// document owner. Global profiler samples would mix documents, so timings
    /// remain absent until a document-owned producer supplies them.
    func redactedSupportReport(bundle: Bundle = .main) -> NativeSupportReport {
        var metadata: [String: String] = [:]
        for key in NativeSupportReport.Application.allowedKeys {
            if let value = bundle.object(forInfoDictionaryKey: key) as? String { metadata[key] = value }
        }
        return NativeSupportReport(snapshot: diagram, diagnostics: currentDiagnostics, bundleMetadata: metadata)
    }
}

extension EditorWindowController {
    @objc func exportRedactedSupportReport(_ sender: Any?) {
        guard lifecycleJobs.isActive, let window else { return }
        let report = diagramDocument.redactedSupportReport()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MacVisio Support.json"
        panel.title = "Export Redacted Support Report"
        panel.message = "Includes drawing counts, issue categories and app version. Drawing text, names, paths, formulas and diagnostic messages are omitted."
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self, self.lifecycleJobs.isActive, let destination = panel.url else { return }
            do {
                if let source = self.diagramDocument.fileURL,
                   source.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL.resolvingSymlinksInPath() {
                    throw DiagramError.invalid("Choose a separate report file; the drawing cannot be replaced by a support report.")
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: destination, options: .atomic)
                self.root.status.stringValue = "Redacted support report exported."
            } catch { self.presentError(error) }
        }
    }
}
