import Foundation
import CoreGraphics

/// A bounded, deterministic orthogonal router for native connectors.
/// Imported routes and connectors with cached points continue to use their saved geometry.
enum OrthogonalRouter {
    private enum Side: Int, CaseIterable {
        case east, west, north, south
        var dx: CGFloat { self == .east ? 1 : self == .west ? -1 : 0 }
        var dy: CGFloat { self == .north ? 1 : self == .south ? -1 : 0 }
    }

    private struct Obstacle {
        var id: UUID
        var rect: CGRect
        var score: Double
        var order: Int
    }

    private struct State: Hashable {
        var point: Int
        var heading: Int
        var index: Int { point * 5 + heading }
    }

    private struct QueueEntry {
        var state: State
        var cost: Int64
        var priority: Int64
    }

    private struct MinHeap {
        var values: [QueueEntry] = []
        var isEmpty: Bool { values.isEmpty }

        mutating func push(_ value: QueueEntry) {
            values.append(value)
            var index = values.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                guard Self.precedes(values[index],values[parent]) else { break }
                values.swapAt(index,parent)
                index = parent
            }
        }

        mutating func pop() -> QueueEntry? {
            guard !values.isEmpty else { return nil }
            if values.count == 1 { return values.removeLast() }
            let first = values[0]
            values[0] = values.removeLast()
            var index = 0
            while true {
                let left = index * 2 + 1, right = left + 1
                var best = index
                if left < values.count,Self.precedes(values[left],values[best]) { best = left }
                if right < values.count,Self.precedes(values[right],values[best]) { best = right }
                guard best != index else { break }
                values.swapAt(index,best)
                index = best
            }
            return first
        }

        private static func precedes(_ a: QueueEntry,_ b: QueueEntry) -> Bool {
            if a.priority != b.priority { return a.priority < b.priority }
            if a.cost != b.cost { return a.cost < b.cost }
            return a.state.index < b.state.index
        }
    }

    private struct Endpoint {
        var point: CGPoint
        var side: Side?
    }

    private static let initialObstacleLimit = 24
    private static let maximumObstacleLimit = 40
    private static let maximumExpandedStates = 24_000

    /// Returns nil when bounded search cannot produce a route; callers then use the
    /// established native fallback route.
    static func route(_ edge: DiagramEdge,in page: DiagramPage) -> [CGPoint]? {
        guard edge.source != edge.target else { return nil }
        let firstNode = page.nodes.first(where:{$0.id == edge.source})
        let lastNode = page.nodes.first(where:{$0.id == edge.target})
        let firstPort = ConnectionGeometry.fixed(edge.sourcePort,on:firstNode)
        let lastPort = ConnectionGeometry.fixed(edge.targetPort,on:lastNode)
        guard let first = endpoint(node:firstNode,fixed:firstPort,position:edge.sourcePosition?.cgPoint,
                                  toward:lastPort ?? lastNode?.center ?? edge.targetPosition?.cgPoint),
              let last = endpoint(node:lastNode,fixed:lastPort,position:edge.targetPosition?.cgPoint,
                                  toward:firstPort ?? firstNode?.center ?? edge.sourcePosition?.cgPoint) else { return nil }
        guard [first.point.x,first.point.y,last.point.x,last.point.y].allSatisfy(\.isFinite) else { return nil }

        let scale = CGFloat(page.paperScale)
        guard scale.isFinite,scale > 0 else { return nil }
        let clearance = 8 / scale
        let leadLength = 2 / scale
        let start = leadPoint(for:first,node:firstNode,minimum:leadLength)
        let goal = leadPoint(for:last,node:lastNode,minimum:leadLength)
        let span = hypot(goal.x-start.x,goal.y-start.y)
        let padding = min(max(96/scale,span*0.2),1200/scale)
        let searchBounds = CGRect(x:min(start.x,goal.x)-padding,y:min(start.y,goal.y)-padding,
                                  width:abs(goal.x-start.x)+2*padding,height:abs(goal.y-start.y)+2*padding)
        guard [searchBounds.minX,searchBounds.minY,searchBounds.maxX,searchBounds.maxY].allSatisfy(\.isFinite) else { return nil }
        let nodeByID = page.nodes.reduce(into:[UUID:DiagramNode]()) { result,node in
            if result[node.id] == nil { result[node.id] = node }
        }
        let hiddenLayers = Set((page.layers ?? []).filter{!$0.visible}.map(\.name))
        let containingGroups = endpointGroups([edge.source,edge.target],nodes:nodeByID)
        var protected:[Obstacle] = []
        for (id,node) in [(edge.source,firstNode),(edge.target,lastNode)] {
            if let node,let rect = rotatedBounds(of:node) {
                protected.append(Obstacle(id:id,rect:rect,score:-1,order:-1))
            }
        }
        guard !protected.contains(where:{obstacle in
            (obstacle.id != edge.source && collides([first.point,start],with:obstacle.rect)) ||
            (obstacle.id != edge.target && collides([goal,last.point],with:obstacle.rect))
        }) else { return nil }
        var nearby:[Obstacle] = []
        var preferred:[Obstacle] = []
        let broad = searchBounds.insetBy(dx:-clearance,dy:-clearance)

        for (order,node) in page.nodes.enumerated() {
            guard node.id != edge.source,node.id != edge.target,!containingGroups.contains(node.id),
                  isVisible(node,nodes:nodeByID,hiddenLayers:hiddenLayers),
                  let rect = rotatedBounds(of:node)?.insetBy(dx:-clearance,dy:-clearance),
                  rect.intersects(broad) else { continue }
            let score = distance(from:start,to:goal,through:rect)
            let obstacle = Obstacle(id:node.id,rect:rect,score:score,order:order)
            nearby.append(obstacle)
            insert(obstacle,into:&preferred,limit:initialObstacleLimit)
        }

        if let quick = directPath(from:start,to:goal,first:first.point,last:last.point,
                                  nearby:nearby,protected:protected,sourceID:edge.source,targetID:edge.target) { return quick }

        var selected = preferred
        for attempt in 0...4 {
            guard let path = search(from:start,to:goal,bounds:searchBounds,obstacles:selected+protected,paperScale:scale) else { return nil }
            var result = [first.point]
            result.append(contentsOf:path)
            result.append(last.point)
            result = simplified(result)
            var blocked:[Obstacle] = []
            var selectedCollision = false
            for obstacle in nearby where collides(result,with:obstacle.rect) {
                if selected.contains(where:{$0.id == obstacle.id}) { selectedCollision = true }
                else { insert(obstacle,into:&blocked,limit:4) }
            }
            if selectedCollision { return nil }
            if blocked.isEmpty { return result }
            guard attempt < 4,selected.count < maximumObstacleLimit else { return nil }
            let additions = blocked.prefix(min(4,maximumObstacleLimit-selected.count))
            guard !additions.isEmpty else { return nil }
            selected.append(contentsOf:additions)
            selected.sort(by:precedes)
        }
        return nil
    }

    private static func endpoint(node:DiagramNode?,fixed:CGPoint?,position:CGPoint?,toward:CGPoint?) -> Endpoint? {
        guard let point = fixed ?? node.map({node in
            let destination = toward ?? node.center
            let side = side(from:node.center,toward:destination)
            let far = CGPoint(x:node.center.x+side.dx*100_000,y:node.center.y+side.dy*100_000)
            return DiagramGeometry.boundary(of:node,toward:far)
        }) ?? position else { return nil }
        guard let node else { return Endpoint(point:point,side:nil) }
        let dx = point.x-node.center.x,dy = point.y-node.center.y
        let outwardSide:Side
        if fixed != nil { outwardSide = side(from:node.center,toward:point) }
        else { outwardSide = side(from:node.center,toward:toward ?? node.center) }
        // A fixed port can sit at the center of a shape. In that case, follow the
        // remote endpoint's dominant axis to leave the shape deterministically.
        let usefulSide = abs(dx)+abs(dy) > 1e-8 ? outwardSide : side(from:point,toward:toward ?? point)
        return Endpoint(point:point,side:usefulSide)
    }

    private static func side(from origin:CGPoint,toward point:CGPoint) -> Side {
        let dx = point.x-origin.x,dy = point.y-origin.y
        if abs(dx) >= abs(dy) { return dx < 0 ? .west : .east }
        return dy < 0 ? .south : .north
    }

    private static func shifted(_ point:CGPoint,by side:Side,distance:CGFloat) -> CGPoint {
        CGPoint(x:point.x+side.dx*distance,y:point.y+side.dy*distance)
    }

    private static func leadPoint(for endpoint:Endpoint,node:DiagramNode?,minimum:Double) -> CGPoint {
        guard let side = endpoint.side else { return endpoint.point }
        var length = minimum
        if let node,let bounds = rotatedBounds(of:node) {
            switch side {
            case .east: length = max(length,bounds.maxX-endpoint.point.x+minimum)
            case .west: length = max(length,endpoint.point.x-bounds.minX+minimum)
            case .north: length = max(length,bounds.maxY-endpoint.point.y+minimum)
            case .south: length = max(length,endpoint.point.y-bounds.minY+minimum)
            }
        }
        return shifted(endpoint.point,by:side,distance:max(0,length))
    }

    private static func directPath(from start:CGPoint,to goal:CGPoint,first:CGPoint,last:CGPoint,
                                   nearby:[Obstacle],protected:[Obstacle],sourceID:UUID,targetID:UUID) -> [CGPoint]? {
        let horizontalFirst = abs(goal.x-start.x) >= abs(goal.y-start.y)
        let elbows = horizontalFirst
            ? [CGPoint(x:goal.x,y:start.y),CGPoint(x:start.x,y:goal.y)]
            : [CGPoint(x:start.x,y:goal.y),CGPoint(x:goal.x,y:start.y)]
        for elbow in elbows {
            let middle = simplified([start,elbow,goal])
            guard !protected.contains(where:{collides(middle,with:$0.rect)}) else { continue }
            var full = [first];full.append(contentsOf:middle);full.append(last);full = simplified(full)
            guard !nearby.contains(where:{collides(full,with:$0.rect)}) else { continue }
            guard !protected.contains(where:{obstacle in
                (obstacle.id != sourceID && collides([first,start],with:obstacle.rect)) ||
                (obstacle.id != targetID && collides([goal,last],with:obstacle.rect))
            }) else { continue }
            return full
        }
        return nil
    }

    private static func endpointGroups(_ ids:[UUID],nodes:[UUID:DiagramNode]) -> Set<UUID> {
        var result:Set<UUID> = [],seen:Set<UUID> = []
        for id in ids {
            var current:UUID? = id
            for _ in 0..<64 {
                guard let value = current,seen.insert(value).inserted,let node = nodes[value] else { break }
                if node.formatting.isGroup { result.insert(value) }
                current = node.parentID
            }
        }
        return result
    }

    private static func isVisible(_ node:DiagramNode,nodes:[UUID:DiagramNode],hiddenLayers:Set<String>) -> Bool {
        var current:DiagramNode? = node
        for _ in 0..<64 {
            guard let value = current else { return true }
            if hiddenLayers.contains(value.layer) || value.formatting.layerNames.contains(where:hiddenLayers.contains) { return false }
            current = value.parentID.flatMap{nodes[$0]}
        }
        return false
    }

    private static func rotatedBounds(of node:DiagramNode) -> CGRect? {
        guard [node.x,node.y,node.width,node.height,node.rotation].allSatisfy(\.isFinite) else { return nil }
        let radians = CGFloat(node.rotation * .pi / 180)
        let cosine = abs(cos(radians)),sine = abs(sin(radians))
        let width = CGFloat(node.width),height = CGFloat(node.height)
        let halfWidth = (width*cosine+height*sine)/2
        let halfHeight = (width*sine+height*cosine)/2
        return CGRect(x:node.center.x-halfWidth,y:node.center.y-halfHeight,width:halfWidth*2,height:halfHeight*2)
    }

    private static func distance(from start:CGPoint,to end:CGPoint,through rect:CGRect) -> Double {
        let center = CGPoint(x:rect.midX,y:rect.midY),dx = end.x-start.x,dy = end.y-start.y
        let length = dx*dx+dy*dy
        let t = length > 0 ? max(0,min(1,((center.x-start.x)*dx+(center.y-start.y)*dy)/length)) : 0
        let nearest = CGPoint(x:start.x+t*dx,y:start.y+t*dy)
        return Double(max(0,hypot(center.x-nearest.x,center.y-nearest.y)-hypot(rect.width,rect.height)/2))
    }

    private static func precedes(_ a:Obstacle,_ b:Obstacle) -> Bool {
        if a.score != b.score { return a.score < b.score }
        return a.order < b.order
    }

    private static func insert(_ obstacle:Obstacle,into values:inout[Obstacle],limit:Int) {
        var index = 0
        while index < values.count && !precedes(obstacle,values[index]) { index += 1 }
        if index < limit { values.insert(obstacle,at:index) }
        if values.count > limit { values.removeLast() }
    }

    private static func search(from start:CGPoint,to goal:CGPoint,bounds:CGRect,obstacles:[Obstacle],paperScale:CGFloat) -> [CGPoint]? {
        var xs = [start.x,goal.x,bounds.minX,bounds.maxX]
        var ys = [start.y,goal.y,bounds.minY,bounds.maxY]
        for obstacle in obstacles {
            xs.append(max(bounds.minX,min(bounds.maxX,obstacle.rect.minX)))
            xs.append(max(bounds.minX,min(bounds.maxX,obstacle.rect.maxX)))
            ys.append(max(bounds.minY,min(bounds.maxY,obstacle.rect.minY)))
            ys.append(max(bounds.minY,min(bounds.maxY,obstacle.rect.maxY)))
        }
        xs = uniqueSorted(xs);ys = uniqueSorted(ys)
        guard xs.count*ys.count <= 8_000,let startX = xs.firstIndex(of:start.x),let startY = ys.firstIndex(of:start.y),
              let goalX = xs.firstIndex(of:goal.x),let goalY = ys.firstIndex(of:goal.y) else { return nil }
        let width = xs.count,height = ys.count
        let startPoint = startY*width+startX,goalPoint = goalY*width+goalX
        let stateCount = width*height*5
        var costs = [Int64](repeating:Int64.max,count:stateCount)
        var parents = [Int](repeating:-1,count:stateCount)
        var queue = MinHeap()
        let initial = State(point:startPoint,heading:4)
        costs[initial.index] = 0
        queue.push(QueueEntry(state:initial,cost:0,priority:heuristic(start,goal,paperScale:paperScale)))
        let turnPenalty:Int64 = 18_000
        let moves = [(1,0,0),(-1,0,1),(0,1,2),(0,-1,3)]
        let rects = obstacles.map(\.rect)
        var expanded = 0
        var terminal:Int?

        while let entry = queue.pop() {
            if entry.cost > costs[entry.state.index] { continue }
            if entry.state.point == goalPoint { terminal = entry.state.index;break }
            expanded += 1
            if expanded > maximumExpandedStates { return nil }
            let xIndex = entry.state.point % width,yIndex = entry.state.point / width
            for (dx,dy,direction) in moves {
                let nx = xIndex+dx,ny = yIndex+dy
                guard nx >= 0,nx < width,ny >= 0,ny < height else { continue }
                let destination = ny*width+nx
                let a = CGPoint(x:xs[xIndex],y:ys[yIndex]),b = CGPoint(x:xs[nx],y:ys[ny])
                guard !collides(a,b,with:rects) else { continue }
                let length = scaledCost(abs(b.x-a.x)+abs(b.y-a.y),paperScale:paperScale)
                let bend = entry.state.heading != 4 && entry.state.heading != direction ? turnPenalty : 0
                let nextCost = entry.cost+length+bend
                let next = State(point:destination,heading:direction)
                guard nextCost < costs[next.index] else { continue }
                costs[next.index] = nextCost
                parents[next.index] = entry.state.index
                queue.push(QueueEntry(state:next,cost:nextCost,priority:nextCost+heuristic(b,goal,paperScale:paperScale)))
            }
        }
        guard var index = terminal else { return nil }
        var route:[CGPoint] = []
        while index >= 0 {
            let pointIndex = index/5,xIndex = pointIndex%width,yIndex = pointIndex/width
            route.append(CGPoint(x:xs[xIndex],y:ys[yIndex]))
            index = parents[index]
        }
        return simplified(route.reversed())
    }

    private static func scaledCost(_ length:CGFloat,paperScale:CGFloat) -> Int64 {
        let value = Double(length)*Double(paperScale)*1_000
        guard value.isFinite,value < Double(Int64.max/4) else { return Int64.max/4 }
        return Int64(value.rounded())
    }

    private static func heuristic(_ a:CGPoint,_ b:CGPoint,paperScale:CGFloat) -> Int64 {
        let estimate = Double(abs(a.x-b.x)+abs(a.y-b.y))*Double(paperScale)*1_000
        guard estimate.isFinite,estimate < Double(Int64.max/4) else { return Int64.max/4 }
        // The grid has at most 40,000 heading states. This margin keeps the
        // rounded-cost heuristic admissible despite sub-millipoint edge rounding.
        return max(0,Int64(estimate.rounded(.down))-20_000)
    }

    private static func uniqueSorted(_ values:[CGFloat]) -> [CGFloat] {
        Array(Set(values.filter(\.isFinite))).sorted()
    }

    private static func collides(_ a:CGPoint,_ b:CGPoint,with rects:[CGRect]) -> Bool {
        for rect in rects where collides(a,b,with:rect) { return true }
        return false
    }

    private static func collides(_ a:CGPoint,_ b:CGPoint,with rect:CGRect) -> Bool {
        let epsilon = 1e-7
        if abs(a.y-b.y) < epsilon {
            return a.y > rect.minY+epsilon && a.y < rect.maxY-epsilon && max(a.x,b.x) > rect.minX+epsilon && min(a.x,b.x) < rect.maxX-epsilon
        }
        if abs(a.x-b.x) < epsilon {
            return a.x > rect.minX+epsilon && a.x < rect.maxX-epsilon && max(a.y,b.y) > rect.minY+epsilon && min(a.y,b.y) < rect.maxY-epsilon
        }
        return true
    }

    private static func collides(_ path:[CGPoint],with rect:CGRect) -> Bool {
        guard path.count > 1 else { return false }
        for index in 1..<path.count where collides(path[index-1],path[index],with:rect) { return true }
        return false
    }

    private static func simplified<S:Sequence>(_ points:S) -> [CGPoint] where S.Element == CGPoint {
        var result:[CGPoint] = []
        for point in points {
            if let last = result.last,abs(last.x-point.x)<1e-8,abs(last.y-point.y)<1e-8 { continue }
            result.append(point)
            while result.count >= 3 {
                let a = result[result.count-3],b = result[result.count-2],c = result[result.count-1]
                let horizontal = abs(a.y-b.y)<1e-8 && abs(b.y-c.y)<1e-8
                let vertical = abs(a.x-b.x)<1e-8 && abs(b.x-c.x)<1e-8
                guard horizontal || vertical else { break }
                result.remove(at:result.count-2)
            }
        }
        return result
    }
}
