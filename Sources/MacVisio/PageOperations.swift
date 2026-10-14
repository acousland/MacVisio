import Foundation

/// Page layers stay separate: shape IDs and layer names are scoped to each page.
struct DiagramScene {
    var page:DiagramPage
    var backgrounds:[DiagramPage] = []
    var layers:[DiagramPage] { backgrounds+[page] }
    func offset(for layer:DiagramPage) -> CGPoint { CGPoint(x:0,y:page.paperHeight-layer.paperHeight) }
}

enum PageOperations {
    static func backgroundCandidates(for id:UUID,in diagram:Diagram) -> [DiagramPage] {
        let byID = diagram.pages.reduce(into:[UUID:DiagramPage]()){if $0[$1.id] == nil { $0[$1.id] = $1 }}
        return diagram.orderedPages.filter { candidate in
            guard candidate.isBackground == true,candidate.id != id else { return false }
            var next:UUID? = candidate.id,seen = Set<UUID>()
            while let current = next {
                guard current != id,seen.insert(current).inserted else { return false }
                next = byID[current]?.backgroundPageID
            };return true
        }
    }
    static func configure(_ id:UUID,in diagram:inout Diagram,name:String? = nil,width:Double? = nil,height:Double? = nil,isBackground:Bool? = nil,background:UUID?? = nil,scale:DrawingScale?? = nil) throws {
        var next = diagram
        guard let index = next.pages.firstIndex(where:{$0.id == id}) else { throw DiagramError.invalid("The page no longer exists.") }
        if let name = name { next.pages[index].name = name }
        if let scale { next.pages[index].drawingScale = scale }
        if let isBackground = isBackground,(next.pages[index].isBackground == true) != isBackground {
            next.pages[index].isBackground = isBackground
            if !isBackground { for i in next.pages.indices where next.pages[i].backgroundPageID == id { next.pages[i].backgroundPageID = nil } }
        }
        if let background = background { next.pages[index].backgroundPageID = background }
        let oldHeight = next.pages[index].height,newHeight = height ?? oldHeight
        if let width = width { next.pages[index].width = width };next.pages[index].height = newHeight
        // Visio's page coordinates have their origin at the lower left. Changing
        // paper height preserves literal shape coordinates, rather than moving them.
        let delta = newHeight-oldHeight
        if delta != 0 {
            for i in next.pages[index].nodes.indices { next.pages[index].nodes[i].y += delta }
            for i in next.pages[index].edges.indices {
                if let p = next.pages[index].edges[i].sourcePosition { next.pages[index].edges[i].sourcePosition = DiagramPoint(x:p.x,y:p.y+delta) }
                if let p = next.pages[index].edges[i].targetPosition { next.pages[index].edges[i].targetPosition = DiagramPoint(x:p.x,y:p.y+delta) }
                next.pages[index].edges[i].points = next.pages[index].edges[i].points?.map{DiagramPoint(x:$0.x,y:$0.y+delta)}
            }
        }
        diagram = try next.validated()
    }
    @discardableResult static func addBackground(to id:UUID,in diagram:inout Diagram) throws -> UUID {
        guard let page = diagram.pages.first(where:{$0.id == id}) else { throw DiagramError.invalid("The page no longer exists.") }
        var next = diagram,new = DiagramPage(name:"Background \(diagram.pages.filter{$0.isBackground == true}.count+1)",width:page.width,height:page.height)
        new.isBackground = true;next.pages.append(new)
        next.pages[next.pages.count-1].drawingScale = page.drawingScale
        try configure(id,in:&next,background:.some(new.id));next.activePageID = new.id
        diagram = next;return new.id
    }
    static func delete(_ id:UUID,in diagram:inout Diagram) throws {
        guard diagram.pages.count>1,let index = diagram.pages.firstIndex(where:{$0.id == id}) else { throw DiagramError.invalid("The final page cannot be deleted.") }
        var next = diagram
        for i in next.pages.indices where next.pages[i].backgroundPageID == id { next.pages[i].backgroundPageID = nil }
        next.pages.remove(at:index)
        if next.activePageID == id { next.activePageID = next.pages[min(index,next.pages.count-1)].id }
        diagram = try next.validated()
    }
}
