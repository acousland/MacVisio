import Foundation
import CoreGraphics

/// Models store page coordinates. Public group contents store parent coordinates.
enum DiagramCoordinates {
    static func hydrateArchivedConnectors(_ input:Diagram) throws -> Diagram {
        guard var archive = input.visioArchive else { return input }
        guard archive.pages.count <= 1000,archive.parts.count <= 10000 else { throw DiagramError.invalid("Oversized archived connector hierarchy.") }
        var output = input
        for b in archive.pages.indices {
            let binding = archive.pages[b]
            guard let data = archive.parts[binding.part],data.count <= VisioPackage.partLimit else { throw DiagramError.invalid("Missing or oversized archived page.") }
            let document = try VisioXML.document(data)
            let parents = binding.nodeIDs.reduce(into:[UInt32:UUID]()){if let id = UInt32($1.value) { $0[id] = $1.key } }
            var shapeParents:[UInt32:UUID] = [:],seen = Set<UInt32>()
            var pending = (document.rootElement()?.firstLocal("Shapes")?.elementsLocal("Shape") ?? []).map{($0,0,Optional<UUID>.none)}
            while let (shape,depth,parent) = pending.popLast() {
                if ["1","true"].contains(shape.attr("Del") ?? "") { continue }
                guard depth < 64,let id = shape.attr("ID").flatMap(UInt32.init),seen.insert(id).inserted,seen.count <= 150000 else { throw DiagramError.invalid("Invalid archived shape hierarchy.") }
                if let parent { shapeParents[id] = parent }
                for child in shape.firstLocal("Shapes")?.elementsLocal("Shape") ?? [] { pending.append((child,depth+1,parents[id])) }
            }
            for e in binding.original.edges.indices where binding.original.edges[e].parentID == nil {
                let id = binding.original.edges[e].id
                let parent = binding.inheritedShapes?[id]?.parentID ?? binding.edgeIDs[id].flatMap(UInt32.init).flatMap{shapeParents[$0]}
                guard let parent else { continue }
                archive.pages[b].original.edges[e].parentID = parent
                if let p = output.pages.firstIndex(where:{$0.id == binding.pageID}),output.pages[p].nodes.contains(where:{$0.id == parent}),let i = output.pages[p].edges.firstIndex(where:{$0.id == id}),output.pages[p].edges[i].parentID == nil { output.pages[p].edges[i].parentID = parent }
            }
        }
        archive.connectorHierarchyVersion = 1;output.visioArchive = archive;return output
    }
    static func local(_ point:CGPoint,in parent:DiagramNode) -> CGPoint {
        let a = -parent.rotation * .pi/180,dx = point.x-parent.center.x,dy = point.y-parent.center.y
        var x = dx*cos(a)-dy*sin(a),y = dx*sin(a)+dy*cos(a)
        if parent.formatting.flipX { x = -x };if parent.formatting.flipY { y = -y }
        return CGPoint(x:x+parent.width/2,y:y+parent.height/2)
    }
    static func world(_ point:CGPoint,in parent:DiagramNode) -> CGPoint {
        var x = point.x-parent.width/2,y = point.y-parent.height/2;let a = parent.rotation * .pi/180
        if parent.formatting.flipX { x = -x };if parent.formatting.flipY { y = -y }
        return CGPoint(x:parent.center.x+x*cos(a)-y*sin(a),y:parent.center.y+x*sin(a)+y*cos(a))
    }
    static func connector(_ edge:DiagramEdge,in page:DiagramPage,sourceCoordinates:Bool = true) -> (edge:DiagramEdge,page:DiagramPage) {
        guard let parentID = edge.parentID,let parent = page.nodes.first(where:{$0.id == parentID}) else { return (edge,page) }
        var local = edge;local.parentID = nil
        let points = DiagramGeometry.route(edge,in:page).map { point -> DiagramPoint in let p = self.local(point,in:parent);return DiagramPoint(x:p.x+(sourceCoordinates ? parent.sheetOrigin.x : 0),y:p.y-(sourceCoordinates ? parent.sheetOrigin.y : 0)) }
        local.points = points;local.sourcePosition = points.first;local.targetPosition = points.last
        return (local,DiagramPage(width:parent.width,height:parent.height))
    }
}
