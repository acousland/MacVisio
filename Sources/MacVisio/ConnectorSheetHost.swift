import Foundation

/// An immutable evaluation view keeps the connector's own UUID and public
/// sheet. It never inserts a shape into the drawing or changes graph membership.
enum ConnectorSheetHost {
    static func sourceNode(_ edge: DiagramEdge) -> DiagramNode {
        var node = edge.textNode
        node.formatting.sourceShapeID = edge.sourceShapeID
        return node
    }
    static func node(_ edge: DiagramEdge, in page: DiagramPage,
                     nodesByID: [UUID: DiagramNode]? = nil) -> DiagramNode {
        var node = sourceNode(edge)
        node.stroke = edge.color; node.strokeWidth = edge.width
        func endpoint(_ id: UUID) -> CGPoint? {
            if let nodesByID { return nodesByID[id]?.center }
            return page.nodes.first { $0.id == id }?.center
        }
        let begin = edge.sourcePosition?.cgPoint ?? endpoint(edge.source) ?? .zero
        let end = edge.targetPosition?.cgPoint ?? endpoint(edge.target) ?? begin
        let distance = hypot(end.x-begin.x,end.y-begin.y)
        node.width = max(0.001,abs(edge.formatting.sheet["Width"].flatMap { Double($0.value) } ?? distance/72)*72)
        node.height = max(0.001,abs(edge.formatting.sheet["Height"].flatMap { Double($0.value) } ?? 0)*72)
        node.x = (begin.x+end.x-node.width)/2; node.y = (begin.y+end.y-node.height)/2
        node.rotation = atan2(end.y-begin.y,end.x-begin.x)*180 / .pi
        return node
    }
}
