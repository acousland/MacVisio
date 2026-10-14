import AppKit
import XCTest
@testable import MacVisio

final class ConnectionPointTests:XCTestCase {
    private var directories:[URL] = []
    override func tearDown() { for directory in directories { try? FileManager.default.removeItem(at:directory) };super.tearDown() }
    private func url(_ name:String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-ports-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);directories.append(directory);return directory.appendingPathComponent(name)
    }
    private func port(_ index:UInt32,_ name:String?,_ x:String,_ y:String,_ fx:String = "",_ fy:String = "") -> ShapeConnectionPoint {
        ShapeConnectionPoint(index:index,name:name,x:ShapeSheetCell(value:x,formula:fx),y:ShapeSheetCell(value:y,formula:fy))
    }
    private func diagram() -> Diagram {
        var model = Diagram();model.page.width = 900;model.page.height = 600
        var a = DiagramNode(x:100,y:100,text:"Source"),b = DiagramNode(x:450,y:250,text:"Target")
        a.width = 180;a.height = 120;b.width = 180;b.height = 120
        a.formatting.connectionPoints = [port(0,"Output","2.5","1","Width","Height*0.6"),port(1,"Aux","0.5","0.5")]
        b.formatting.connectionPoints = [port(0,"Input","0","0.25","0","Height*0.2"),port(1,nil,"1","0.5")]
        model.page.nodes = [a,b]
        var edge = DiagramEdge(source:a.id,target:b.id,label:"Named ports",style:.straight);edge.sourcePort = a.formatting.connectionPoints[0].id;edge.targetPort = b.formatting.connectionPoints[0].id;model.page.edges = [edge]
        return model
    }
    private func publicRead(_ model:Diagram) throws -> (Diagram,[String:Data]) {
        let file = try url("public.vsdx");try VisioFormat.write(model,to:file)
        var parts = try VisioPackage.read(file);parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:file)
        return (try VisioFormat.read(from:file).diagram,parts)
    }
    private func assertPoint(_ actual:CGPoint?,_ expected:CGPoint,accuracy:Double = 0.000001,file:StaticString = #filePath,line:UInt = #line) throws {
        let actual = try XCTUnwrap(actual,file:file,line:line);XCTAssertEqual(actual.x,expected.x,accuracy:accuracy,file:file,line:line);XCTAssertEqual(actual.y,expected.y,accuracy:accuracy,file:file,line:line)
    }
    func testNamedAndIndexedPortsRoundTripPublicXMLAndGlue() throws {
        let model = diagram(),(restored,parts) = try publicRead(model)
        XCTAssertEqual(restored.page.nodes.map{$0.formatting.connectionPoints.count},[2,2])
        XCTAssertEqual(restored.page.edges[0].sourcePort,"N:Output");XCTAssertEqual(restored.page.edges[0].targetPort,"N:Input")
        try assertPoint(DiagramGeometry.route(restored.page.edges[0],in:restored.page).first,CGPoint(x:280,y:148))
        try assertPoint(DiagramGeometry.route(restored.page.edges[0],in:restored.page).last,CGPoint(x:450,y:346))
        let xml = try VisioXML.document(parts["visio/pages/page1.xml"]!),connections = xml.rootElement()!.firstLocal("Connects")!.elementsLocal("Connect")
        XCTAssertEqual(connections.map{$0.attr("ToCell")},["Connections.Output.X","Connections.Input.X"])
        XCTAssertEqual(connections.map{$0.attr("ToPart")},["100","100"])
        let wire = xml.rootElement()!.firstLocal("Shapes")!.allShapes.first{$0.attr("NameU")?.contains("Connector") == true}!
        XCTAssertTrue(wire.elementsLocal("Cell").first{$0.attr("N") == "BeginX"}!.attr("F")!.contains("Connections.Output.X"))
    }
    func testIndexedToCellAndToPartReferencesResolveTheSamePort() throws {
        let model = diagram(),node = model.page.nodes[1]
        XCTAssertEqual(ConnectionGeometry.matching(cell:"Connections.X2",part:nil,on:node)?.id,"IX:1")
        XCTAssertEqual(ConnectionGeometry.matching(cell:"unknown",part:"101",on:node)?.id,"IX:1")
        XCTAssertNil(ConnectionGeometry.matching(cell:"PinX",part:"3",on:node))
    }
    func testFixedAndFormulaCoordinatesHaveDifferentResizeSemantics() throws {
        var model = diagram();let before = model;model.page.nodes[0].width = 360;model.page.nodes[0].height = 240
        let node = model.page.nodes[0]
        try assertPoint(ConnectionGeometry.point(node.formatting.connectionPoints[0],on:node),CGPoint(x:460,y:196))
        try assertPoint(ConnectionGeometry.point(node.formatting.connectionPoints[1],on:node),CGPoint(x:136,y:304))
        let result = ShapeSheetEngine.recalculate(model,previous:before)
        XCTAssertEqual(result.diagram.page.nodes[0].formatting.connectionPoints[0].x.value,"5");XCTAssertEqual(result.diagram.page.nodes[0].formatting.connectionPoints[1].x.value,"0.5")
        XCTAssertTrue(result.issues.isEmpty)
    }
    func testRotatedReflectedGroupedPortRetainsExactWorldAttachment() throws {
        var model = diagram();let root = try DiagramOperations.group(Set(model.page.nodes.map(\.id)),in:&model.page),old = model.page.nodes.first{$0.id == root}!
        let index = model.page.nodes.firstIndex{$0.id == root}!,source = model.page.nodes.first{$0.text == "Source"}!
        let oldPoint = ConnectionGeometry.point(source.formatting.connectionPoints[0],on:source)
        model.page.nodes[index].rotation = 90;model.page.nodes[index].formatting.flipX = true;let changed = model.page.nodes[index]
        DiagramOperations.transformChildren(in:&model.page,from:old,to:changed)
        let local = DiagramCoordinates.local(oldPoint,in:old),expected = DiagramCoordinates.world(local,in:changed)
        try assertPoint(DiagramGeometry.route(model.page.edges[0],in:model.page).first,expected)
        let (restored,_) = try publicRead(model);try assertPoint(DiagramGeometry.route(restored.page.edges[0],in:restored.page).first,expected)
        XCTAssertNotNil(restored.page.edges[0].parentID)
    }
    func testCachedRouteEndpointsHonorPortsInsteadOfMovingToShapeBoundary() throws {
        var model = diagram();model.page.edges[0].points = [DiagramPoint(x:999,y:999),DiagramPoint(x:400,y:150),DiagramPoint(x:998,y:998)]
        let route = DiagramGeometry.route(model.page.edges[0],in:model.page)
        try assertPoint(route.first,CGPoint(x:280,y:148));try assertPoint(route.last,CGPoint(x:450,y:346));XCTAssertEqual(route[1],CGPoint(x:400,y:150))
    }
    func testPortRenameUpdatesGlueAndDeletionKeepsTheLastPhysicalEndpoint() throws {
        _ = NSApplication.shared
        let document = MacVisioDocument();document.undoManager?.groupsByEvent = false;document.diagram = diagram();document.makeWindowControllers();let editor = document.windowControllers[0] as! EditorWindowController
        let id = document.diagram.page.nodes[0].id;var points = document.diagram.page.nodes[0].formatting.connectionPoints;points[0].name = "Feed"
        document.undoManager?.beginUndoGrouping();try editor.setConnectionPoints(points,for:id);document.undoManager?.endUndoGrouping();XCTAssertEqual(document.diagram.page.edges[0].sourcePort,"N:Feed")
        let expected = DiagramGeometry.route(document.diagram.page.edges[0],in:document.diagram.page).first!
        document.undoManager?.beginUndoGrouping();try editor.setConnectionPoints([],for:id);document.undoManager?.endUndoGrouping()
        XCTAssertNil(document.diagram.page.edges[0].sourcePort);XCTAssertNotEqual(document.diagram.page.edges[0].source,id);try assertPoint(DiagramGeometry.route(document.diagram.page.edges[0],in:document.diagram.page).first,expected)
        document.undoManager?.undo();XCTAssertEqual(document.diagram.page.edges[0].sourcePort,"N:Feed")
    }
    func testNativeConnectorClicksSnapToVisiblePortMarkers() throws {
        _ = NSApplication.shared
        let document = MacVisioDocument();document.diagram = diagram();document.diagram.page.edges = [];document.makeWindowControllers()
        let controller = document.windowControllers[0] as! EditorWindowController,canvas = controller.canvas;controller.window!.contentView!.layoutSubtreeIfNeeded();canvas.zoom = 1;canvas.tool = .connector
        func click(_ p:CGPoint) throws {
            let location = canvas.convert(CGPoint(x:canvas.pageOrigin.x+p.x,y:canvas.pageOrigin.y+p.y),to:nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with:.leftMouseDown,location:location,modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1));canvas.mouseDown(with:event)
        }
        try click(CGPoint(x:280,y:148));XCTAssertEqual(canvas.pendingSourcePort,"N:Output")
        try click(CGPoint(x:450,y:346));XCTAssertEqual(document.diagram.page.edges.count,1);XCTAssertEqual(document.diagram.page.edges[0].sourcePort,"N:Output");XCTAssertEqual(document.diagram.page.edges[0].targetPort,"N:Input")
    }
    func testCopyRemapsNodeGlueAndPortFormulasButKeepsPortIdentity() throws {
        var model = diagram();model.page.nodes[0].formatting.sourceShapeID = "10";model.page.nodes[1].formatting.sourceShapeID = "11"
        model.page.nodes[0].formatting.connectionPoints[0].x.formula = "Sheet.11!Width"
        let fragment = DiagramOperations.fragment(Set(model.page.nodes.map(\.id)),from:model.page)
        var page = DiagramPage();try DiagramOperations.insert(fragment,into:&page,reservedIDs:["40"])
        XCTAssertEqual(page.edges[0].sourcePort,"N:Output");XCTAssertEqual(page.edges[0].targetPort,"N:Input");XCTAssertEqual(page.edges[0].source,page.nodes[0].id)
        XCTAssertEqual(page.nodes[0].formatting.connectionPoints[0].x.formula,"Sheet.\(page.nodes[1].formatting.sourceShapeID!)!Width")
        let single = DiagramOperations.fragment([],edges:[model.page.edges[0].id],from:model.page);XCTAssertNil(single.edges[0].sourcePort);XCTAssertNil(single.edges[0].targetPort)
    }
    func testPortReferencesParticipateInNumericShapeSheetDependencies() throws {
        var model = diagram();model.page.nodes[0].formatting.sheet["User.Measure"] = ShapeSheetCell(value:"0",formula:"Connections.Output.X*2")
        let result = ShapeSheetEngine.recalculate(model);XCTAssertEqual(result.diagram.page.nodes[0].formatting.sheet["User.Measure"]?.value,"5");XCTAssertTrue(result.issues.isEmpty)
    }
    func testInvalidPortDataAndMissingGlueTargetsAreRejected() throws {
        var model = diagram();model.page.nodes[0].formatting.connectionPoints[1].index = 0;XCTAssertThrowsError(try model.validated())
        model = diagram();model.page.edges[0].sourcePort = "N:Missing";XCTAssertThrowsError(try model.validated())
        model = diagram();model.page.nodes[0].formatting.connectionPoints[0].x.value = "nan";XCTAssertThrowsError(try model.validated())
    }
    func testPreservedPortEditRetainsUnknownCellsAndUpdatesPublicGlue() throws {
        let source = try url("source.vsdx");try VisioFormat.write(diagram(),to:source)
        var parts = try VisioPackage.read(source);parts.removeValue(forKey:"macvisio/document.json")
        let xml = try VisioXML.document(parts["visio/pages/page1.xml"]!),shape = xml.rootElement()!.firstLocal("Shapes")!.elementsLocal("Shape")[0],row = shape.elementsLocal("Section").first{$0.attr("N") == "Connection"}!.elementsLocal("Row")[0]
        VisioXML.set(row,"D","opaque-data",formula:"FUTURE()")
        parts["visio/pages/page1.xml"] = xml.xmlData(options:.nodePreserveAll);try VisioPackage.write(parts,to:source)
        var model = try VisioFormat.read(from:source).diagram;model.page.nodes[0].formatting.connectionPoints[0].x = ShapeSheetCell(value:"1")
        let (restored,saved) = try publicRead(model)
        try assertPoint(DiagramGeometry.route(restored.page.edges[0],in:restored.page).first,CGPoint(x:172,y:148))
        let output = try VisioXML.document(saved["visio/pages/page1.xml"]!),savedRow = output.rootElement()!.firstLocal("Shapes")!.elementsLocal("Shape")[0].elementsLocal("Section").first{$0.attr("N") == "Connection"}!.elementsLocal("Row")[0]
        XCTAssertEqual(VisioXML.value(savedRow,"D"),"opaque-data");XCTAssertEqual(savedRow.elementsLocal("Cell").first{$0.attr("N") == "D"}?.attr("F"),"FUTURE()")
    }
    func testBothFormatExportsContainPortAnchoredCachedGraphics() throws {
        let model = diagram(),binary = try url("ports.vsd");try VSDBinaryFormat.encoded(model,includeMetadata:false).write(to:binary)
        let independent = try LegacyVisioFormat.read(from:binary).diagram
        XCTAssertTrue(independent.page.nodes.contains{$0.text == "Named ports"})
        let native = try url("native.vsd");try VSDBinaryFormat.write(model,to:native);let restored = try LegacyVisioFormat.read(from:native)
        XCTAssertTrue(restored.legacyNative);XCTAssertEqual(restored.diagram.page.edges[0].sourcePort,"N:Output")
        if let path = ProcessInfo.processInfo.environment["MACVISIO_PORT_ARTIFACT_DIR"] {
            let directory = URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try VisioFormat.write(model,to:directory.appendingPathComponent("connection-points.vsdx"));try VSDBinaryFormat.write(model,to:directory.appendingPathComponent("connection-points.vsd"));try JSONEncoder().encode(model).write(to:directory.appendingPathComponent("connection-points.macvisio"),options:.atomic)
            try DiagramExport.png(model.page,scale:1).write(to:directory.appendingPathComponent("connection-points.png"),options:.atomic)
            _ = NSApplication.shared;let document = MacVisioDocument();document.diagram = model;document.makeWindowControllers();let controller = document.windowControllers[0] as! EditorWindowController,view = controller.window!.contentView!
            view.layoutSubtreeIfNeeded();controller.canvas.fitPage();controller.setTool(.connector);view.layoutSubtreeIfNeeded();let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:bitmap);try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:directory.appendingPathComponent("connection-editor.png"),options:.atomic)
        }
    }
    func testInheritedMasterPortsUseInstanceScopedGlueAndCanBeDeletedLocally() throws {
        _ = NSApplication.shared
        let template = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Examples/Masters/masters-source.vsdx"),source = try url("master-ports.vsdx")
        var parts = try VisioPackage.read(template),xml = try VisioXML.document(parts["visio/masters/master1.xml"]!)
        let shape = xml.rootElement()!.firstLocal("Shapes")!.allShapes.first{$0.attr("ID") == "2"}!
        shape.addChild(try VisioXML.element("<Section N=\"Connection\"><Row N=\"Socket\"><Cell N=\"X\" V=\"0.3\"/><Cell N=\"Y\" V=\"0.1\"/></Row></Section>"))
        let connection = xml.rootElement()!.firstLocal("Connects")!.elementsLocal("Connect").first{$0.attr("FromCell") == "BeginX"}!
        connection.setAttr("ToCell","Connections.Socket.X");connection.setAttr("ToPart","100")
        parts["visio/masters/master1.xml"] = xml.xmlData(options:.nodePreserveAll);try VisioPackage.write(parts,to:source)
        let document = MacVisioDocument();try document.read(from:source,ofType:MacVisioDocument.visioType);document.makeWindowControllers()
        XCTAssertEqual(document.diagram.page.edges.filter{$0.sourcePort == "N:Socket"}.count,2)
        let edge = document.diagram.page.edges[0],point = DiagramGeometry.route(edge,in:document.diagram.page).first!,editor = document.windowControllers[0] as! EditorWindowController
        try editor.setConnectionPoints([],for:edge.source)
        let (restored,saved) = try publicRead(document.diagram)
        XCTAssertEqual(restored.page.edges.filter{$0.sourcePort == "N:Socket"}.count,1)
        let nodeIDs = Set(restored.page.nodes.map(\.id))
        let detached = try XCTUnwrap(restored.page.edges.first{$0.sourcePort == nil && !nodeIDs.contains($0.source)})
        try assertPoint(DiagramGeometry.route(detached,in:restored.page).first,point)
        XCTAssertEqual(saved["visio/masters/master1.xml"],parts["visio/masters/master1.xml"])
        let page = try VisioXML.document(saved["visio/pages/page1.xml"]!)
        let rows = page.rootElement()!.firstLocal("Shapes")!.allShapes.flatMap{$0.elementsLocal("Section").filter{$0.attr("N") == "Connection"}.flatMap{$0.elementsLocal("Row")}}
        XCTAssertTrue(rows.contains{$0.attr("N") == "Socket" && $0.attr("Del") == "1"})
    }
    func testOlderNativeMetadataDoesNotConcealPublicPorts() throws {
        let source = try url("old-cache.vsdx");var model = diagram();try VisioFormat.write(model,to:source)
        var parts = try VisioPackage.read(source),envelope = try JSONSerialization.jsonObject(with:parts["macvisio/document.json"]!) as! [String:Any]
        for i in model.page.nodes.indices { model.page.nodes[i].formatting.connectionPoints = [] };model.page.edges[0].sourcePort = nil;model.page.edges[0].targetPort = nil
        envelope["diagram"] = try JSONSerialization.jsonObject(with:JSONEncoder().encode(model));envelope.removeValue(forKey:"connectionPointsVersion")
        parts["macvisio/document.json"] = try JSONSerialization.data(withJSONObject:envelope);try VisioPackage.write(parts,to:source)
        let restored = try VisioFormat.read(from:source)
        XCTAssertEqual(restored.diagram.page.nodes[0].formatting.connectionPoints.count,2);XCTAssertEqual(restored.diagram.page.edges[0].sourcePort,"N:Output")
        XCTAssertTrue(restored.warnings.contains{$0.contains("Older native metadata did not model connection points")})
    }
    func testDeletedNamedRowsKeepIndexedAliasesStableOnPublicReopen() throws {
        var model = diagram();model.page.nodes[0].formatting.connectionPoints.removeFirst();model.page.edges[0].sourcePort = "N:Aux"
        let (restored,_) = try publicRead(model),node = restored.page.nodes[0]
        XCTAssertEqual(node.formatting.connectionPoints.first?.index,1);XCTAssertEqual(ConnectionGeometry.matching(cell:"Connections.X2",part:"101",on:node)?.id,"N:Aux")
    }
}
