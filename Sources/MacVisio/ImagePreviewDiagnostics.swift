import Foundation

/// Read-time metadata policy, never a pixel decode or paint-time producer.
enum ImagePreviewDiagnostics {
    static func records(in diagram: Diagram) -> [DocumentDiagnostic] {
        var records: [DocumentDiagnostic] = []
        for page in diagram.pages {
            let binding = diagram.visioArchive?.pages.first { $0.pageID == page.id }
            for node in page.nodes {
                guard let image = node.formatting.image else { continue }
                do { _ = try NativeImageDecoding.preflight(data: image.data, mimeType: image.mimeType) }
                catch {
                    records.append(DocumentDiagnostic(code: "image.preview-unavailable", origin: .importer,
                        severity: .warning, dimension: .rendering, target: .shape(page: page.id, shape: node.id),
                        source: .init(part: binding?.part, visioID: binding?.nodeIDs[node.id], feature: "EmbeddedImage"),
                        displayState: .unavailable,
                        message: "Image bytes remain preserved; the native preview is unavailable. \(error.localizedDescription)",
                        requestedActions: [.revealTarget, .viewDetails]))
                }
            }
        }
        return records
    }
}
