import AppKit
import XCTest
@testable import MacVisio

final class GroupedConnectorTests:XCTestCase {
    private var directories:[URL] = []
    override func tearDown() { for directory in directories { try? FileManager.default.removeItem(at:directory) };super.tearDown() }
    private func url(_ name:String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-groups-\(UUID())")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);directories.append(directory);return directory.appendingPathComponent(name)
    }
    private func diagram(_ nested:Bool = false) -> Diagram {
        var diagram = Diagram();diagram.page.width = 840;diagram.page.height = 640
        var group = DiagramNode(x:100,y:120,text:"Outer group");group.width = 480;group.height = 300;group.fill = "#FFFFFF00";group.formatting.isGroup = true;group.formatting.textBox = ShapeTextBox(centerX:0.4,centerY:0.1,width:0.5,height:0.12)
        var a = DiagramNode(x:140,y:170,text:"Input"),b = DiagramNode(x:350,y:330,text:"Output")
        a.width = 90;a.height = 60;b.width = 90;b.height = 60;a.parentID = group.id;b.parentID = group.id
        var inner = DiagramNode(x:290,y:250,text:"Inner group");inner.width = 250;inner.height = 140;inner.parentID = group.id;inner.formatting.isGroup = true;inner.fill = "#FFFFFF00";inner.formatting.textBox = group.formatting.textBox
        if nested { b.parentID = inner.id }
        diagram.page.nodes = nested ? [group,a,inner,b] : [group,a,b]
        var attached = DiagramEdge(source:a.id,target:b.id,label:"Attached");attached.parentID = group.id
        var free = DiagramEdge(source:UUID(),target:UUID(),label:"Owned route",color:"#C0392B",style:.straight,arrow:false)
        free.parentID = nested ? inner.id : group.id;free.points = [DiagramPoint(x:315,y:260),DiagramPoint(x:350,y:260),DiagramPoint(x:350,y:300),DiagramPoint(x:460,y:300)];free.sourcePosition = free.points!.first;free.targetPosition = free.points!.last
        diagram.page.edges = [attached,free];return diagram
    }
    private func external(_ diagram:Diagram) throws -> URL {
        let file = try url("external.vsdx");try VisioFormat.write(diagram,to:file)
        var parts = try VisioPackage.read(file);parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:file);return file
    }
    private func masterFixture() throws -> URL {
        let source = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Examples/Masters/masters-source.vsdx"),file = try url("master-source.vsdx")
        try Data(contentsOf:source).write(to:file);return file
    }
    private func publicReopen(_ model:Diagram) throws -> (Diagram,[String:Data]) {
        let file = try url("public-reopen.vsdx");try VisioFormat.write(model,to:file)
        var parts = try VisioPackage.read(file);parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:file)
        return (try VisioFormat.read(from:file).diagram,parts)
    }
    private func assertPoints(_ actual:[CGPoint],_ expected:[CGPoint],accuracy:Double = 0.000001,file:StaticString = #filePath,line:UInt = #line) {
        XCTAssertEqual(actual.count,expected.count,file:file,line:line)
        for (a,b) in zip(actual,expected) { XCTAssertEqual(a.x,b.x,accuracy:accuracy,file:file,line:line);XCTAssertEqual(a.y,b.y,accuracy:accuracy,file:file,line:line) }
    }
    private func transform(_ diagram:inout Diagram) {
        let old = diagram.page.nodes[0];var changed = old;changed.x += 60;changed.y += 45;changed.width *= 1.25;changed.height *= 1.25;changed.rotation = 90;changed.formatting.flipX = true
        diagram.page.nodes[0] = changed;DiagramOperations.transformChildren(in:&diagram.page,from:old,to:changed)
    }
    func testOwnedRoutesFollowNestedGroupTranslationScaleRotationAndFlip() throws {
        var diagram = diagram(true);let before = diagram,oldParent = before.page.nodes.first{$0.id == before.page.edges[1].parentID}!
        transform(&diagram);let parent = diagram.page.nodes.first{$0.id == diagram.page.edges[1].parentID}!
        let expected = before.page.edges[1].points!.map { point -> CGPoint in
            let p = DiagramCoordinates.local(point.cgPoint,in:oldParent)
            return DiagramCoordinates.world(CGPoint(x:p.x*1.25,y:p.y*1.25),in:parent)
        }
        assertPoints(DiagramGeometry.route(diagram.page.edges[1],in:diagram.page),expected)
        XCTAssertEqual(diagram.page.edges[1].sourcePosition,diagram.page.edges[1].points?.first)
        XCTAssertNoThrow(try diagram.validated())
    }
    func testConnectedRoutesRotateWithTheGroupInsteadOfReroutingInPageAxes() throws {
        var diagram = diagram();let old = diagram.page.nodes[0],route = DiagramGeometry.route(diagram.page.edges[0],in:diagram.page)
        transform(&diagram);let changed = diagram.page.nodes[0]
        let expected = route.map { p -> CGPoint in let local = DiagramCoordinates.local(p,in:old);return DiagramCoordinates.world(CGPoint(x:local.x*1.25,y:local.y*1.25),in:changed) }
        assertPoints(DiagramGeometry.route(diagram.page.edges[0],in:diagram.page),expected)
    }
    func testGroupingCapturesInternalConnectionsAndUngroupReparentsThem() throws {
        var page = diagram().page;let group = page.nodes.removeFirst();for i in page.nodes.indices { page.nodes[i].parentID = nil };page.edges[0].parentID = nil;page.edges.removeLast()
        let id = try DiagramOperations.group(Set(page.nodes.map(\.id)),in:&page)
        XCTAssertEqual(page.edges[0].parentID,id);XCTAssertEqual(DiagramOperations.commonGroup(page.edges[0].source,page.edges[0].target,in:page),id)
        _ = DiagramOperations.ungroup([id],in:&page);XCTAssertNil(page.edges[0].parentID);XCTAssertFalse(page.nodes.contains{$0.id == group.id})
    }
    func testNearestCommonGroupIsUsedWhenCreatingNativeConnections() throws {
        _ = NSApplication.shared
        let document = MacVisioDocument();document.diagram = diagram(true)
        var child = DiagramNode(x:440,y:270,text:"Second inner child");child.parentID = document.diagram.page.nodes[2].id;document.diagram.page.nodes.append(child);document.makeWindowControllers()
        let controller = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
        controller.connect(document.diagram.page.nodes[3].id,to:child.id)
        XCTAssertEqual(document.diagram.page.edges.last?.parentID,child.parentID)
    }
    func testPublicVSDXRetainsNestedConnectorParentsAndWorldRoutes() throws {
        var expected = diagram(true);transform(&expected);let source = try external(expected),restored = try VisioFormat.read(from:source).diagram
        for edge in expected.page.edges {
            let actual = restored.page.edges.first{$0.label == edge.label}!,parent = restored.page.nodes.first{$0.id == actual.parentID}!
            XCTAssertEqual(parent.text,expected.page.nodes.first{$0.id == edge.parentID}!.text)
            assertPoints(DiagramGeometry.route(actual,in:restored.page),DiagramGeometry.route(edge,in:expected.page))
        }
    }
    func testMovingAnImportedGroupPreservesLocalConnectorXMLAndOpaqueContent() throws {
        let source = try external(diagram());var parts = try VisioPackage.read(source)
        let xml = try VisioXML.document(parts["visio/pages/page1.xml"]!),shape = xml.rootElement()!.firstLocal("Shapes")!.allShapes.first{$0.firstLocal("Text")?.stringValue == "Owned route"}!
        shape.addChild(try VisioXML.element("<v:Opaque xmlns:v=\"urn:test:group\">preserved</v:Opaque>"));parts["visio/pages/page1.xml"] = xml.xmlData(options:.nodePreserveAll);try VisioPackage.write(parts,to:source)
        let originalXML = shape.xmlString;var model = try VisioFormat.read(from:source).diagram
        let old = model.page.nodes[0];model.page.nodes[0].x += 75;model.page.nodes[0].y += 30
        DiagramOperations.transformChildren(in:&model.page,from:old,to:model.page.nodes[0])
        let destination = try url("moved.vsdx");try VisioFormat.write(model,to:destination)
        let saved = try VisioXML.document(try VisioPackage.read(destination)["visio/pages/page1.xml"]!)
        XCTAssertEqual(saved.rootElement()!.firstLocal("Shapes")!.allShapes.first{$0.firstLocal("Text")?.stringValue == "Owned route"}?.xmlString,originalXML)
    }
    func testEditingAndReparentingAnImportedConnectorKeepsPublicHierarchy() throws {
        var model = try VisioFormat.read(from:external(diagram(true))).diagram
        let index = model.page.edges.firstIndex{$0.label == "Owned route"}!,oldParent = model.page.edges[index].parentID
        model.page.edges[index].parentID = model.page.nodes[0].id;model.page.edges[index].label = "Reparented route"
        XCTAssertNotEqual(oldParent,model.page.edges[index].parentID)
        let destination = try url("reparented.vsdx");try VisioFormat.write(model,to:destination)
        var parts = try VisioPackage.read(destination);parts.removeValue(forKey:"macvisio/document.json");try VisioPackage.write(parts,to:destination)
        let restored = try VisioFormat.read(from:destination).diagram,edge = restored.page.edges.first{$0.label == "Reparented route"}!
        XCTAssertEqual(restored.page.nodes.first{$0.id == edge.parentID}?.text,"Outer group")
        assertPoints(DiagramGeometry.route(edge,in:restored.page),DiagramGeometry.route(model.page.edges[index],in:model.page))
    }
    func testCopyInsertIncludesOwnedDetachedRoutesAndRemapsTheirParents() throws {
        let model = diagram(true),ids = model.page.descendants(of:model.page.nodes[0].id)
        let fragment = DiagramOperations.fragment(ids,from:model.page);XCTAssertEqual(fragment.edges.count,2)
        var page = DiagramPage();try DiagramOperations.insert(fragment,into:&page,at:CGPoint(x:200,y:200))
        XCTAssertNotEqual(page.edges[1].parentID,model.page.edges[1].parentID)
        XCTAssertEqual(page.nodes.first{$0.id == page.edges[1].parentID}?.text,"Inner group")
        let before = model.page.edges[1].points!,after = page.edges[1].points!
        for i in before.indices { XCTAssertEqual(after[i].x-before[i].x,100,accuracy:0.000001);XCTAssertEqual(after[i].y-before[i].y,80,accuracy:0.000001) }
    }
    func testCopyingAConnectorAloneDetachesUnavailableGlueWithoutLosingEndpoints() throws {
        let model = diagram(),edge = model.page.edges[0],route = DiagramGeometry.route(edge,in:model.page)
        let fragment = DiagramOperations.fragment([],edges:[edge.id],from:model.page)
        XCTAssertNil(fragment.edges[0].parentID);XCTAssertEqual(fragment.edges[0].sourcePosition,route.first.map(DiagramPoint.init));XCTAssertEqual(fragment.edges[0].targetPosition,route.last.map(DiagramPoint.init))
        var page = DiagramPage();try DiagramOperations.insert(fragment,into:&page);var check = Diagram();check.pages = [page];XCTAssertNoThrow(try check.validated())
    }
    func testGroupVisibilityLockAndPrintingApplyToOwnedEdges() throws {
        var model = diagram();model.page.layers = [DiagramLayer(name:"Group layer",visible:false,locked:true,printable:false)];model.page.nodes[0].layer = "Group layer"
        XCTAssertFalse(model.page.isVisible(model.page.edges[1]));XCTAssertTrue(model.page.isLocked(model.page.edges[1]));XCTAssertFalse(model.page.isVisible(model.page.edges[1],printing:true))
        XCTAssertFalse(DiagramDrawing.svg(model.page).contains("Owned route"))
        model.page.layers![0].visible = true;XCTAssertTrue(model.page.isVisible(model.page.edges[1]));XCTAssertFalse(model.page.isVisible(model.page.edges[1],printing:true))
    }
    func testNativeGroupDeletionRemovesDetachedOwnedEdgesAndUndoRestoresThem() throws {
        _ = NSApplication.shared
        let document = MacVisioDocument();document.diagram = diagram();document.makeWindowControllers()
        let controller = try XCTUnwrap(document.windowControllers.first as? EditorWindowController);controller.canvas.select([document.diagram.page.nodes[0].id]);controller.deleteSelection(nil)
        XCTAssertTrue(document.diagram.page.nodes.isEmpty);XCTAssertTrue(document.diagram.page.edges.isEmpty)
        document.undoManager?.undo();XCTAssertEqual(document.diagram.page.edges.count,2);XCTAssertNotNil(document.diagram.page.edges[1].parentID)
    }
    func testNativeResizeDragUsesTheOriginalSnapshotForEveryEvent() throws {
        _ = NSApplication.shared
        let document = MacVisioDocument();document.diagram = diagram();document.makeWindowControllers()
        let controller = try XCTUnwrap(document.windowControllers.first as? EditorWindowController),canvas = controller.canvas
        controller.window?.contentView?.layoutSubtreeIfNeeded();canvas.zoom = 1;canvas.snapsToGrid = false;canvas.select([document.diagram.page.nodes[0].id])
        func event(_ type:NSEvent.EventType,_ point:CGPoint) throws -> NSEvent {
            let location = canvas.convert(CGPoint(x:canvas.pageOrigin.x+point.x,y:canvas.pageOrigin.y+point.y),to:nil)
            return try XCTUnwrap(NSEvent.mouseEvent(with:type,location:location,modifierFlags:[],timestamp:0,windowNumber:controller.window!.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1))
        }
        let before = document.diagram;canvas.mouseDown(with:try event(.leftMouseDown,CGPoint(x:580,y:420)))
        canvas.mouseDragged(with:try event(.leftMouseDragged,CGPoint(x:660,y:460)))
        canvas.mouseDragged(with:try event(.leftMouseDragged,CGPoint(x:740,y:500)))
        XCTAssertEqual(document.diagram.page.nodes[0].width,640,accuracy:0.000001)
        XCTAssertEqual(document.diagram.page.nodes[1].width,90*640/480,accuracy:0.000001)
        let actualX = try XCTUnwrap(document.diagram.page.edges[1].points?[1].x),expectedX = 100+(before.page.edges[1].points![1].x-100)*640/480
        XCTAssertEqual(actualX,expectedX,accuracy:0.000001)
        canvas.mouseUp(with:try event(.leftMouseUp,CGPoint(x:740,y:500)))
        document.undoManager?.undo();XCTAssertEqual(document.diagram.page.nodes[0].width,480)
    }
    func testOlderNativeArchiveHydratesGroupedConnectorParents() throws {
        let source = try external(diagram(true));var old = try VisioFormat.read(from:source).diagram
        let parent = old.page.edges[1].parentID;old.visioArchive?.connectorHierarchyVersion = nil
        for i in old.page.edges.indices { old.page.edges[i].parentID = nil;old.visioArchive?.pages[0].original.edges[i].parentID = nil }
        let document = MacVisioDocument();try document.read(from:JSONEncoder().encode(old),ofType:MacVisioDocument.nativeType)
        XCTAssertEqual(document.diagram.page.edges[1].parentID,parent);XCTAssertEqual(document.diagram.visioArchive?.pages[0].original.edges[1].parentID,parent)
        XCTAssertEqual(document.diagram.visioArchive?.parts["visio/pages/page1.xml"],try VisioPackage.read(source)["visio/pages/page1.xml"])
    }
    func testInvalidConnectorParentsAreRejectedAndOlderJSONStillDecodes() throws {
        var model = diagram();model.page.edges[0].parentID = model.page.nodes[1].id;XCTAssertThrowsError(try model.validated())
        let edge = DiagramEdge(source:UUID(),target:UUID()),data = try JSONEncoder().encode(edge);XCTAssertNil(try JSONDecoder().decode(DiagramEdge.self,from:data).parentID)
    }
    func testMovingAMasterInTheNativeEditorKeepsImplicitChildrenAndConnectionsImplicit() throws {
        _ = NSApplication.shared
        let source = try masterFixture(),document = MacVisioDocument();try document.read(from:source,ofType:MacVisioDocument.visioType);document.makeWindowControllers()
        let controller = try XCTUnwrap(document.windowControllers.first as? EditorWindowController),root = document.diagram.page.nodes.first{$0.formatting.sourceShapeID == "10"}!
        controller.canvas.select([root.id]);controller.modifySelection("Move master"){$0.x += 60;$0.y += 30}
        let (restored,parts) = try publicReopen(document.diagram)
        let xml = try VisioXML.document(parts["visio/pages/page1.xml"]!),shape = xml.rootElement()!.firstLocal("Shapes")!.elementsLocal("Shape").first{$0.attr("ID") == "10"}!
        XCTAssertNil(shape.firstLocal("Shapes"));XCTAssertEqual(restored.page.nodes.count,9);XCTAssertEqual(restored.page.edges.count,2)
        XCTAssertEqual(parts["visio/masters/master1.xml"],try VisioPackage.read(source)["visio/masters/master1.xml"])
        let edge = document.diagram.page.edges.first{$0.parentID == root.id}!,newRoot = restored.page.nodes.first{$0.formatting.sourceShapeID == "10"}!,actual = restored.page.edges.first{$0.parentID == newRoot.id}!
        assertPoints(DiagramGeometry.route(actual,in:restored.page),DiagramGeometry.route(edge,in:document.diagram.page))
    }
    func testUngroupingAMasterMaterializesCachedMembersWithoutOrphanMasterReferences() throws {
        var model = try VisioFormat.read(from:masterFixture()).diagram
        let root = model.page.nodes.first{$0.formatting.sourceShapeID == "10"}!,before = model
        _ = DiagramOperations.ungroup([root.id],in:&model.page)
        let (restored,parts) = try publicReopen(model)
        XCTAssertEqual(restored.page.nodes.count,8);XCTAssertEqual(restored.page.edges.count,2)
        let xml = try VisioXML.document(parts["visio/pages/page1.xml"]!)
        XCTAssertFalse(xml.rootElement()!.firstLocal("Shapes")!.allShapes.contains{$0.attr("MasterShape") != nil})
        let member = restored.page.nodes.first{$0.text == "Inherited left" && $0.parentID == nil}!
        XCTAssertEqual(member.formatting.data.first?.value,"45");XCTAssertEqual(member.formatting.hyperlinks.count,1)
        let edge = restored.page.edges.first{$0.parentID == nil}!,originalEdge = before.page.edges.first{$0.parentID == root.id}!
        assertPoints(DiagramGeometry.route(edge,in:restored.page),DiagramGeometry.route(originalEdge,in:before.page))
    }
    func testUngroupingAnInheritedNestedGroupSuppressesItsOldSlotAndRetainsGlue() throws {
        var model = try VisioFormat.read(from:masterFixture()).diagram
        let root = model.page.nodes.first{$0.formatting.sourceShapeID == "10"}!,nested = model.page.nodes.first{$0.parentID == root.id && $0.formatting.isGroup}!
        _ = DiagramOperations.ungroup([nested.id],in:&model.page)
        let (restored,parts) = try publicReopen(model),newRoot = restored.page.nodes.first{$0.formatting.sourceShapeID == "10"}!
        XCTAssertEqual(restored.page.nodes.count,8)
        let inner = restored.page.nodes.first{$0.parentID == newRoot.id && $0.text == "Inherited inner"}!,edge = restored.page.edges.first{$0.parentID == newRoot.id}!
        XCTAssertEqual(edge.target,inner.id)
        let xml = try VisioXML.document(parts["visio/pages/page1.xml"]!)
        XCTAssertTrue(xml.rootElement()!.firstLocal("Shapes")!.allShapes.contains{$0.attr("MasterShape") == "3" && $0.attr("Del") == "1"})
    }
    func testNumericLookingTextAndEquivalentCachesArePreservedDuringRecalculation() throws {
        var model = diagram();model.page.nodes[1].formatting.sheet["Char.Size"] = ShapeSheetCell(value:"0.138888888888889");model.page.nodes[1].fontSize = 10.000000000000007
        model.page.nodes[1].formatting.sheet["Prop.Serial"] = ShapeSheetCell(value:"00125");model.page.nodes[1].formatting.data = [ShapeDataProperty(key:"Serial",label:"Serial",value:"00125",type:0)]
        let result = ShapeSheetEngine.recalculate(model)
        XCTAssertEqual(result.diagram.page.nodes[1].formatting.sheet["Prop.Serial"]?.value,"00125");XCTAssertEqual(result.diagram.page.nodes[1].formatting.data[0].value,"00125")
        XCTAssertEqual(result.diagram.page.nodes[1].formatting.sheet["Char.Size"]?.value,"0.138888888888889")
    }
    func testCopiedIdentifiersWrapAndFormulaRemappingIgnoresQuotedText() throws {
        var fragment = diagram();fragment.page.nodes[0].formatting.sourceShapeID = "10";fragment.page.nodes[1].formatting.sourceShapeID = "11";fragment.page.nodes[2].formatting.sourceShapeID = "12"
        fragment.page.nodes[1].formatting.sheet["User.Reference"] = ShapeSheetCell(value:"4",formula:"sheet.010!Width+SHEET.12!Height")
        fragment.page.nodes[1].formatting.sheet["User.Literal"] = ShapeSheetCell(value:"quoted",formula:"\"Sheet.10!Width\"&\"say \"\"Sheet.12!\"\"\"")
        var page = DiagramPage();try DiagramOperations.insert(fragment.page,into:&page,reservedIDs:["4294967295"])
        let group = page.nodes.first{$0.formatting.isGroup}!,input = page.nodes.first{$0.text == "Input"}!,output = page.nodes.first{$0.text == "Output"}!
        XCTAssertEqual(group.formatting.sourceShapeID,"0")
        XCTAssertEqual(input.formatting.sheet["User.Reference"]?.formula,"Sheet.0!Width+Sheet.\(output.formatting.sourceShapeID!)!Height")
        XCTAssertEqual(input.formatting.sheet["User.Literal"]?.formula,fragment.page.nodes[1].formatting.sheet["User.Literal"]?.formula)
        XCTAssertTrue(page.edges.allSatisfy{$0.sourceShapeID.flatMap(UInt32.init) != nil})
    }
    func testFreshExportAllocatesBoundedIDsForGroupsAndConnectors() throws {
        var model = diagram();model.page.nodes[0].formatting.sourceShapeID = "4294967295";model.page.edges[0].sourceShapeID = "0"
        let source = try external(model),parts = try VisioPackage.read(source),xml = try VisioXML.document(parts["visio/pages/page1.xml"]!)
        let ids = xml.rootElement()!.firstLocal("Shapes")!.allShapes.compactMap{$0.attr("ID").flatMap(UInt32.init)}
        XCTAssertEqual(ids.count,5);XCTAssertEqual(Set(ids).count,5);XCTAssertTrue(ids.contains(UInt32.max));XCTAssertTrue(ids.contains(0))
        XCTAssertEqual(try VisioFormat.read(from:source).diagram.page.edges.count,2)
    }
    func testSavedNativeCachesMatchEditedImportedGeometry() throws {
        var model = try VisioFormat.read(from:external(diagram())).diagram
        let old = model.page.nodes[0];model.page.nodes[0].x += 40;DiagramOperations.transformChildren(in:&model.page,from:old,to:model.page.nodes[0])
        let destination = try url("with-metadata.vsdx");try VisioFormat.write(model,to:destination)
        let restored = try VisioFormat.read(from:destination).diagram;var edited = restored;edited.page.nodes[1].text = "Changed text"
        let result = ShapeSheetEngine.recalculate(edited,previous:restored)
        XCTAssertEqual(result.diagram.page.nodes[0].x,model.page.nodes[0].x,accuracy:0.000001)
        XCTAssertEqual(result.diagram.page.nodes[1].x,model.page.nodes[1].x,accuracy:0.000001)
        let second = try url("unchanged.vsdx");try VisioFormat.write(restored,to:second)
        XCTAssertEqual(try VisioPackage.read(second)["visio/pages/page1.xml"],try VisioPackage.read(destination)["visio/pages/page1.xml"])
    }
    func testShapeFlipsMoveTextBlocksWithoutMirroringGlyphs() throws {
        var page = DiagramPage(width:260,height:200),node = DiagramNode(kind:.text,x:50,y:50,text:"F");node.width = 150;node.height = 100;node.fontSize = 60
        page.nodes = [node];let original = try XCTUnwrap(NSBitmapImageRep(data:DiagramExport.png(page,scale:1)))
        page.nodes[0].formatting.flipX = true;let flipped = try XCTUnwrap(NSBitmapImageRep(data:DiagramExport.png(page,scale:1)))
        XCTAssertEqual(original.pixelsWide,flipped.pixelsWide);XCTAssertEqual(original.pixelsHigh,flipped.pixelsHigh)
        let size = original.bytesPerRow*original.pixelsHigh
        XCTAssertEqual(Data(bytes:try XCTUnwrap(original.bitmapData),count:size),Data(bytes:try XCTUnwrap(flipped.bitmapData),count:size))
        node.formatting.textBox = ShapeTextBox(centerX:0.25,centerY:0.3,width:0.4,height:0.5,rotation:30,left:3,right:7,top:2,bottom:4)
        let before = DiagramDrawing.textLayout(for:node);node.formatting.flipX = true;let after = DiagramDrawing.textLayout(for:node)
        XCTAssertEqual(after.center.x,2*node.center.x-before.center.x,accuracy:0.000001);XCTAssertEqual(after.rotation,-30)
        XCTAssertEqual(after.rect.minX,after.center.x-node.width*0.4/2+3,accuracy:0.000001)
        let xml = try VisioXML.document(Data(DiagramDrawing.svg(page).utf8))
        let text = try XCTUnwrap(try xml.nodes(forXPath:"//*[local-name()='text']").first as? XMLElement)
        XCTAssertFalse((text.parent as? XMLElement)?.attr("transform")?.contains("scale") ?? false)
    }
    func testBinaryGroupedRouteParsesAtItsTransformedWorldPositionWithoutMetadata() throws {
        var model = diagram(true);transform(&model);let source = try url("grouped.vsd")
        try VSDBinaryFormat.encoded(model,includeMetadata:false).write(to:source)
        let restored = try LegacyVisioFormat.read(from:source).diagram
        let paths = restored.page.nodes.filter{$0.stroke.uppercased().hasPrefix("#C0392B") && !$0.formatting.paths.isEmpty}
        XCTAssertFalse(paths.isEmpty)
        let actual = paths.reduce(CGRect.null){$0.union($1.rect)},points = DiagramGeometry.route(model.page.edges[1],in:model.page)
        let expected = points.reduce(CGRect.null){$0.union(CGRect(origin:$1,size:.zero))}
        XCTAssertEqual(actual.minX,expected.minX,accuracy:0.05);XCTAssertEqual(actual.minY,expected.minY,accuracy:0.05);XCTAssertEqual(actual.width,expected.width,accuracy:0.05);XCTAssertEqual(actual.height,expected.height,accuracy:0.05)
        if let path = ProcessInfo.processInfo.environment["MACVISIO_GROUP_ARTIFACT_DIR"] {
            let directory = URL(fileURLWithPath:path);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try VSDBinaryFormat.write(model,to:directory.appendingPathComponent("grouped-connectors.vsd"));try VisioFormat.write(model,to:directory.appendingPathComponent("grouped-connectors.vsdx"))
            try JSONEncoder().encode(model).write(to:directory.appendingPathComponent("grouped-connectors.macvisio"),options:.atomic)
            _ = NSApplication.shared
            let document = MacVisioDocument();document.diagram = model;document.makeWindowControllers()
            let controller = try XCTUnwrap(document.windowControllers.first as? EditorWindowController),view = try XCTUnwrap(controller.window?.contentView)
            view.layoutSubtreeIfNeeded();controller.canvas.fitPage();view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in:view.bounds));view.cacheDisplay(in:view.bounds,to:bitmap)
            try XCTUnwrap(bitmap.representation(using:.png,properties:[:])).write(to:directory.appendingPathComponent("grouped-editor.png"),options:.atomic)
        }
    }
}
