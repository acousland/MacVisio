import Foundation

/// Computes the small translation needed to align a moving selection with
/// visible target bounds. The caller decides which targets participate (for
/// example, by consulting Visio layer Snap settings) and supplies a threshold
/// in drawing coordinates.
enum ShapeSnapping {
    static func bounds(of node: DiagramNode) -> CGRect {
        let rect = node.rect.standardized
        guard node.rotation.isFinite,node.rotation.truncatingRemainder(dividingBy:360) != 0 else { return rect }
        let angle = node.rotation * .pi / 180,cosine = cos(angle),sine = sin(angle),center = CGPoint(x:rect.midX,y:rect.midY)
        let corners = [CGPoint(x:rect.minX,y:rect.minY),CGPoint(x:rect.minX,y:rect.maxY),CGPoint(x:rect.maxX,y:rect.minY),CGPoint(x:rect.maxX,y:rect.maxY)].map { point in
            let dx = point.x-center.x,dy = point.y-center.y
            return CGPoint(x:center.x+dx*cosine-dy*sine,y:center.y+dx*sine+dy*cosine)
        }
        return corners.reduce(CGRect.null) { $0.union(CGRect(origin:$1,size:.zero)) }
    }

    static func alignmentDelta(moving rawMoving: CGRect, targets rawTargets: [CGRect], tolerance: CGFloat) -> CGPoint {
        guard tolerance.isFinite, tolerance >= 0 else { return .zero }
        let moving = rawMoving.standardized
        let targets = rawTargets.filter { $0.origin.x.isFinite && $0.origin.y.isFinite && $0.width.isFinite && $0.height.isFinite }.map(\.standardized)
        guard !targets.isEmpty else { return .zero }

        func bestDelta(_ movingMarks: [CGFloat], _ targetMarks: [CGFloat]) -> CGFloat {
            var best: CGFloat?
            for from in movingMarks {
                for to in targetMarks {
                    let delta = to - from
                    guard abs(delta) <= tolerance else { continue }
                    if best == nil || abs(delta) < abs(best!) { best = delta }
                }
            }
            return best ?? 0
        }

        let movingX = [moving.minX, moving.midX, moving.maxX]
        let movingY = [moving.minY, moving.midY, moving.maxY]
        let targetX = targets.flatMap { [$0.minX, $0.midX, $0.maxX] }
        let targetY = targets.flatMap { [$0.minY, $0.midY, $0.maxY] }
        return CGPoint(x: bestDelta(movingX, targetX), y: bestDelta(movingY, targetY))
    }
}

extension DiagramPage {
    /// Layer restrictions are combined conservatively: any assigned layer
    /// that disables a behavior blocks that behavior for the shape.
    func permitsShapeSnap(to node: DiagramNode) -> Bool {
        permitsLayerBehavior(node, keyPath: \.snap)
    }

    func permitsGlue(to node: DiagramNode) -> Bool {
        permitsLayerBehavior(node, keyPath: \.glue)
    }

    private func permitsLayerBehavior(_ node: DiagramNode, keyPath: KeyPath<DiagramLayer, Bool>) -> Bool {
        let names = Set(node.formatting.layerNames + [node.layer])
        return (layers ?? []).filter { names.contains($0.name) }.allSatisfy { $0[keyPath:keyPath] }
    }
}
