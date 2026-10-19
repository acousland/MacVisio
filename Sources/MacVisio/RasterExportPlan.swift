import CoreGraphics
import Foundation
import MacVisioInfrastructure

enum RasterExportRegion: String, CaseIterable {
    case page, content, selection
}

/// Raw selection identity captured before the save-panel draft. Locked objects
/// remain exportable. Group expansion is derived from this exact frozen page.
struct RasterExportSelection: Equatable {
    let input: LifecycleJobInput
    let pageID: UUID
    let nodeIDs: Set<UUID>
    let edgeIDs: Set<UUID>

    var isEmpty: Bool { nodeIDs.isEmpty && edgeIDs.isEmpty }

    func expanded(in snapshot: Diagram, input candidate: LifecycleJobInput,
                  cancellation: LifecycleJobCancellation? = nil) throws -> RasterExportMembership {
        guard candidate == input, snapshot.activePageID == pageID,
              let page = snapshot.pages.first(where: { $0.id == pageID }) else { throw LifecycleJobError.staleInput }
        guard !isEmpty else { throw DiagramError.invalid("Select one or more objects to export.") }
        let availableNodes = Set(page.nodes.map(\.id)), availableEdges = Set(page.edges.map(\.id))
        guard nodeIDs.isSubset(of: availableNodes), edgeIDs.isSubset(of: availableEdges) else {
            throw LifecycleJobError.staleInput
        }
        var children: [UUID: [UUID]] = [:]
        for node in page.nodes {
            try cancellation?.check()
            if let parent = node.parentID { children[parent, default: []].append(node.id) }
        }
        var nodes = nodeIDs, pending = Array(nodeIDs)
        while let id = pending.popLast() {
            try cancellation?.check()
            for child in children[id] ?? [] where nodes.insert(child).inserted { pending.append(child) }
        }
        var edges = edgeIDs
        for edge in page.edges {
            try cancellation?.check()
            if let parent = edge.parentID, nodes.contains(parent) { edges.insert(edge.id) }
        }
        return RasterExportMembership(nodeIDs: nodes, edgeIDs: edges)
    }
}

struct RasterExportMembership {
    let nodeIDs: Set<UUID>
    let edgeIDs: Set<UUID>

    func contains(_ element: PageElementID) -> Bool {
        switch element {
        case .node(let id): return nodeIDs.contains(id)
        case .edge(let id): return edgeIDs.contains(id)
        }
    }
}

/// Top-left physical paper coordinates and exact outward-aligned raster size.
/// Cropped output has one complete pixel of antialiasing guard on every side.
/// This is conservative publication geometry, not pixel-tight ink detection.
struct RasterExportViewport: Equatable {
    let rect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int

    static func cropped(_ bounds: CGRect, options: OwnedExportOptions) throws -> Self {
        try options.validateRasterDPI()
        guard !bounds.isNull, !bounds.isInfinite,
              [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].allSatisfy({ $0.isFinite && abs($0) <= 1e9 }),
              bounds.width >= 0, bounds.height >= 0 else {
            throw DiagramError.invalid("There is no printable artwork in the requested raster region.")
        }
        let scale = options.rasterDPI / 72
        let left = floor(bounds.minX * scale) - 1, top = floor(bounds.minY * scale) - 1
        let right = ceil(bounds.maxX * scale) + 1, bottom = ceil(bounds.maxY * scale) + 1
        let width = right - left, height = bottom - top
        guard width >= 1, height >= 1,
              width <= Double(OwnedExportOptions.maximumRasterDimension),
              height <= Double(OwnedExportOptions.maximumRasterDimension) else {
            throw DiagramError.invalid("The cropped region exceeds the supported raster dimensions. Choose a lower resolution.")
        }
        let w = Int(width), h = Int(height)
        guard w <= OwnedExportOptions.maximumRasterPixels / h else {
            throw DiagramError.invalid("Raster export supports up to 100 million pixels. Choose a lower resolution.")
        }
        return Self(rect: CGRect(x: left / scale, y: top / scale, width: width / scale, height: height / scale),
                    pixelWidth: w, pixelHeight: h)
    }
}
