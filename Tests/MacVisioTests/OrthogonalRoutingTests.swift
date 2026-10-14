import CoreGraphics
import XCTest
@testable import MacVisio

final class OrthogonalRoutingTests:XCTestCase {
    private func pair() -> (DiagramPage,DiagramNode,DiagramNode,DiagramEdge) {
        var page = DiagramPage(width:800,height:500)
        var source = DiagramNode(x:50,y:100,text:"Source"),target = DiagramNode(x:430,y:100,text:"Target")
        source.width = 80;source.height = 60;target.width = 80;target.height = 60
        page.nodes = [source,target]
        let edge = DiagramEdge(source:source.id,target:target.id)
        return (page,source,target,edge)
    }

    private func assertOrthogonal(_ points:[CGPoint],file:StaticString = #filePath,line:UInt = #line) {
        XCTAssertGreaterThanOrEqual(points.count,2,file:file,line:line)
        for (a,b) in zip(points,points.dropFirst()) {
            XCTAssertTrue(abs(a.x-b.x)<1e-7 || abs(a.y-b.y)<1e-7,"Segment is diagonal: \(a) -> \(b)",file:file,line:line)
        }
    }

    private func intersects(_ a:CGPoint,_ b:CGPoint,_ rect:CGRect) -> Bool {
        if abs(a.y-b.y)<1e-7 {
            return a.y>rect.minY+1e-7 && a.y<rect.maxY-1e-7 && max(a.x,b.x)>rect.minX+1e-7 && min(a.x,b.x)<rect.maxX-1e-7
        }
        if abs(a.x-b.x)<1e-7 {
            return a.x>rect.minX+1e-7 && a.x<rect.maxX-1e-7 && max(a.y,b.y)>rect.minY+1e-7 && min(a.y,b.y)<rect.maxY-1e-7
        }
        return true
    }

    private func assertAvoids(_ points:[CGPoint],_ rect:CGRect,file:StaticString = #filePath,line:UInt = #line) {
        for (a,b) in zip(points,points.dropFirst()) {
            XCTAssertFalse(intersects(a,b,rect),"Route crosses obstacle at \(a) -> \(b)",file:file,line:line)
        }
    }

    private func assertPoint(_ actual:CGPoint?,_ expected:CGPoint,file:StaticString = #filePath,line:UInt = #line) {
        guard let actual else { XCTFail("Missing route endpoint",file:file,line:line);return }
        XCTAssertEqual(actual.x,expected.x,accuracy:1e-7,file:file,line:line)
        XCTAssertEqual(actual.y,expected.y,accuracy:1e-7,file:file,line:line)
    }

    func testRoutesAroundVisibleAndRotatedObstacleDeterministically() {
        var (page,source,target,edge) = pair()
        var obstacle = DiagramNode(x:220,y:90,text:"Rotated obstacle")
        obstacle.width = 110;obstacle.height = 80;obstacle.rotation = 32
        page.nodes = [source,target,obstacle]
        let radians = CGFloat(obstacle.rotation * .pi/180),width = CGFloat(obstacle.width),height = CGFloat(obstacle.height)
        let rotatedWidth = abs(cos(radians))*width+abs(sin(radians))*height
        let rotatedHeight = abs(sin(radians))*width+abs(cos(radians))*height
        let bounds = CGRect(x:obstacle.center.x-rotatedWidth/2,y:obstacle.center.y-rotatedHeight/2,width:rotatedWidth,height:rotatedHeight)
        let route = DiagramGeometry.route(edge,in:page)
        XCTAssertEqual(route,DiagramGeometry.route(edge,in:page))
        assertOrthogonal(route)
        XCTAssertTrue(route.contains{abs($0.y-source.center.y)>1})
        assertAvoids(route,bounds.insetBy(dx:-8,dy:-8))
        assertPoint(route.first,DiagramGeometry.boundary(of:source,toward:CGPoint(x:100_000,y:source.center.y)))
        assertPoint(route.last,DiagramGeometry.boundary(of:target,toward:CGPoint(x:-100_000,y:target.center.y)))
    }

    func testFixedGluePortsRemainAnchoredAndShortLeadCanTurnAroundNearbyObstacle() {
        var (page,source,target,edge) = pair()
        source.formatting.connectionPoints = [ShapeConnectionPoint(index:0,name:"Output",x:ShapeSheetCell(value:"1.111111111111"),y:ShapeSheetCell(value:"0.416666666667"))]
        target.formatting.connectionPoints = [ShapeConnectionPoint(index:0,name:"Input",x:ShapeSheetCell(value:"0"),y:ShapeSheetCell(value:"0.416666666667"))]
        edge.sourcePort = "N:Output";edge.targetPort = "N:Input"
        var obstacle = DiagramNode(x:142,y:110,text:"Near source")
        obstacle.width = 70;obstacle.height = 40
        page.nodes = [source,target,obstacle];page.edges = [edge]
        let sourcePoint = ConnectionGeometry.point(source.formatting.connectionPoints[0],on:source)
        let targetPoint = ConnectionGeometry.point(target.formatting.connectionPoints[0],on:target)
        let route = DiagramGeometry.route(edge,in:page)
        assertOrthogonal(route)
        assertPoint(route.first,sourcePoint)
        assertPoint(route.last,targetPoint)
        assertAvoids(route,obstacle.rect.insetBy(dx:-8,dy:-8))
    }

    func testHiddenObstacleDoesNotChangeAutomaticRoute() {
        var (page,source,target,edge) = pair()
        var obstacle = DiagramNode(x:220,y:90,text:"Hidden")
        obstacle.width = 110;obstacle.height = 80;obstacle.layer = "Hidden"
        page.nodes = [source,target,obstacle]
        page.layers = [DiagramLayer(name:"Hidden",visible:false)]
        page.edges = [edge]
        let route = DiagramGeometry.route(edge,in:page)
        XCTAssertEqual(route.map(\.y),Array(repeating:source.center.y,count:route.count))
        assertOrthogonal(route)
    }

    func testEndpointGroupContainersAreNotObstacles() {
        var page = DiagramPage(width:800,height:500)
        var group = DiagramNode(x:20,y:30,text:"Group")
        group.width = 600;group.height = 300;group.formatting.isGroup = true
        var source = DiagramNode(x:70,y:130,text:"Source"),target = DiagramNode(x:450,y:130,text:"Target")
        source.width = 80;source.height = 60;target.width = 80;target.height = 60
        source.parentID = group.id;target.parentID = group.id
        let edge = DiagramEdge(source:source.id,target:target.id)
        page.nodes = [group,source,target]
        let route = DiagramGeometry.route(edge,in:page)
        assertOrthogonal(route)
        XCTAssertEqual(route.first?.y,source.center.y)
        XCTAssertEqual(route.last?.y,target.center.y)
        XCTAssertTrue(route.allSatisfy{group.rect.insetBy(dx:-1,dy:-1).contains($0)})
    }

    func testStraightAndExplicitCachedRoutesKeepExistingSemantics() {
        var (page,source,target,edge) = pair()
        var obstacle = DiagramNode(x:220,y:90,text:"Obstacle")
        obstacle.width = 110;obstacle.height = 80
        page.nodes = [source,target,obstacle]
        edge.style = .straight
        let straight = DiagramGeometry.route(edge,in:page)
        XCTAssertEqual(straight.count,2)
        XCTAssertEqual(straight.first,DiagramGeometry.boundary(of:source,toward:target.center))
        XCTAssertEqual(straight.last,DiagramGeometry.boundary(of:target,toward:source.center))

        edge.style = .orthogonal
        let cache = [DiagramPoint(x:0,y:0),DiagramPoint(x:180,y:130),DiagramPoint(x:300,y:130),DiagramPoint(x:999,y:999)]
        edge.points = cache
        let cached = DiagramGeometry.route(edge,in:page)
        XCTAssertEqual(Array(cached.dropFirst().dropLast(1)),cache.dropFirst().dropLast(1).map(\.cgPoint))
        XCTAssertEqual(cached.count,cache.count)
    }

    func testPaperScaleKeepsPhysicalRouteGeometry() {
        var (page,source,target,edge) = pair()
        var obstacle = DiagramNode(x:220,y:90,text:"Obstacle")
        obstacle.width = 110;obstacle.height = 80
        page.nodes = [source,target,obstacle]
        let paperRoute = DiagramGeometry.route(edge,in:page)

        page.nodes = page.nodes.map { node in
            var scaled = node;scaled.x /= 10;scaled.y /= 10;scaled.width /= 10;scaled.height /= 10
            return scaled
        }
        page.width /= 10;page.height /= 10;page.drawingScale = DrawingScale(page:10,drawing:1)
        let drawingRoute = DiagramGeometry.route(edge,in:page).map{CGPoint(x:$0.x*10,y:$0.y*10)}
        XCTAssertEqual(drawingRoute.count,paperRoute.count)
        for (actual,expected) in zip(drawingRoute,paperRoute) {
            XCTAssertEqual(actual.x,expected.x,accuracy:1e-6)
            XCTAssertEqual(actual.y,expected.y,accuracy:1e-6)
        }
    }

    func testThousandsOfDistantShapesDoNotExpandSearchGrid() {
        var (page,source,target,edge) = pair()
        page.nodes = [source,target]
        for index in 0..<3_000 {
            var node = DiagramNode(x:10_000+Double(index)*200,y:10_000,text:"Remote \(index)")
            node.width = 40;node.height = 30
            page.nodes.append(node)
        }
        let start = ProcessInfo.processInfo.systemUptime
        let route = DiagramGeometry.route(edge,in:page)
        let elapsed = ProcessInfo.processInfo.systemUptime-start
        assertOrthogonal(route)
        XCTAssertLessThanOrEqual(route.count,4)
        XCTAssertLessThan(elapsed,5,"Routing a single connector should stay bounded with thousands of distant shapes")
    }
}
