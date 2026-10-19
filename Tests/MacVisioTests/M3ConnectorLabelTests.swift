import AppKit
import CryptoKit
import ImageIO
import XCTest
@testable import MacVisio

final class M3ConnectorLabelTests: XCTestCase {
    private func fixture(factor:Double = 1) -> DiagramPage {
        var page = DiagramPage(width:500/factor,height:240/factor)
        var left = DiagramNode(x:30/factor,y:110/factor,text:""),right = DiagramNode(x:450/factor,y:110/factor,text:"")
        for key in [0,1] {
            if key == 0 { left.width = 20/factor;left.height = 20/factor;left.fill = "#FFFFFF00";left.stroke = "#FFFFFF00" }
            else { right.width = 20/factor;right.height = 20/factor;right.fill = "#FFFFFF00";right.stroke = "#FFFFFF00" }
        }
        var edge = DiagramEdge(source:left.id,target:right.id,label:"Red <&> Blue\nField 7",style:.straight)
        edge.arrow = false;edge.color = "#444444"
        var first = ShapeCharacterStyle(node:edge.textNode)
        first.fontName = "Arial";first.size = 30;first.bold = true;first.underline = true;first.color = "#FF0000";first.sourceIndex = 3
        var second = first;second.fontName = "Courier New";second.size = 18;second.bold = false;second.italic = true;second.underline = false;second.color = "#0000FF";second.sourceIndex = 9
        let paragraph = ShapeParagraphStyle(alignment:.left)
        edge.formatting.textRuns = [ShapeTextRun(text:"Red <&> ",character:first,paragraph:paragraph),
            ShapeTextRun(text:"Blue\n",character:second,paragraph:paragraph),
            ShapeTextRun(text:"Field ",character:second,paragraph:paragraph),
            ShapeTextRun(text:"7",character:second,paragraph:paragraph,fieldIndex:7,fieldToken:UUID())]
        edge.formatting.textFields = [ShapeTextField(index:7,cells:["Value":ShapeSheetCell(value:"7",formula:"GUARD(7)")],cached:"7")]
        page.nodes = [left,right];page.edges = [edge]
        if factor != 1 { page.drawingScale = DrawingScale(page:factor,drawing:1,type:3) }
        return page
    }

    func testPreparedLabelsUseEveryStoredRunAndKeepDefaultLabelsUnchanged() throws {
        _ = NSApplication.shared
        let edge = fixture().edges[0],label = PreparedEdgeLabel(edge)
        XCTAssertTrue(label.isRich);XCTAssertEqual(label.attributed.string,edge.label)
        let first = try XCTUnwrap(label.attributed.attribute(.font,at:0,effectiveRange:nil) as? NSFont)
        let second = try XCTUnwrap(label.attributed.attribute(.font,at:9,effectiveRange:nil) as? NSFont)
        XCTAssertEqual(first.pointSize,30);XCTAssertEqual(second.pointSize,18)
        XCTAssertTrue(NSFontManager.shared.traits(of:first).contains(.boldFontMask))
        XCTAssertTrue(NSFontManager.shared.traits(of:second).contains(.italicFontMask))
        XCTAssertEqual(label.attributed.attribute(.underlineStyle,at:0,effectiveRange:nil) as? Int,NSUnderlineStyle.single.rawValue)
        var plain = DiagramEdge(source:edge.source,target:edge.target,label:"Plain")
        let original = PreparedEdgeLabel(plain)
        XCTAssertFalse(original.isRich);XCTAssertEqual((original.attributes[.font] as? NSFont)?.pointSize,12)
        plain.color = "#FF0000"
        let recolored = PreparedEdgeLabel(plain,previous:original)
        XCTAssertEqual(recolored.size,original.size);XCTAssertFalse(recolored.matches(edge))
    }

    func testSameTextStyleEditInvalidatesWarmCacheAndExpandsRouteBounds() throws {
        _ = NSApplication.shared
        var page = fixture();let scene = RetainedRenderPage(page)
        let first = try XCTUnwrap(scene.preparedLabel(page.edges[0]))
        XCTAssertTrue(first === scene.preparedLabel(page.edges[0]))
        let before = try XCTUnwrap(scene.routeBounds[page.edges[0].id])
        page.edges[0].formatting.textRuns![0].character.size = 80
        scene.update(page)
        let second = try XCTUnwrap(scene.preparedLabel(page.edges[0]))
        XCTAssertFalse(first === second);XCTAssertGreaterThan(second.size.width,first.size.width)
        XCTAssertGreaterThan(try XCTUnwrap(scene.routeBounds[page.edges[0].id]).height,before.height)
        XCTAssertTrue(second === scene.preparedLabel(page.edges[0]))
        XCTAssertEqual(scene.routes[page.edges[0].id],DiagramGeometry.route(page.edges[0],in:page))
    }

    func testLayerColorAndTransparencyProjectIntoRichRunsWithoutChangingSource() throws {
        _ = NSApplication.shared
        var page = fixture();page.edges[0].layer = "Color"
        page.layers = [DiagramLayer(name:"Color",color:"#00AA00",colorTransparency:50)]
        let original = page.edges[0],colored = DiagramDrawing.layerColored(original,in:page)
        XCTAssertEqual(colored.formatting.textRuns?.map{$0.character.color},Array(repeating:"#00AA0080",count:4))
        let svg = DiagramDrawing.svg(page)
        XCTAssertFalse(svg.contains("fill=\"#FF0000\""));XCTAssertFalse(svg.contains("fill=\"#0000FF\""))
        XCTAssertTrue(svg.contains("fill=\"#00AA00\""));XCTAssertTrue(svg.contains("fill-opacity=\"0.5019607843137255\""))
        page.layers?[0].colorTransparency = 100
        let hidden = PreparedEdgeLabel(DiagramDrawing.layerColored(original,in:page))
        hidden.attributed.enumerateAttribute(.foregroundColor,in:NSRange(location:0,length:hidden.attributed.length)) { value,_,_ in
            XCTAssertEqual((value as? NSColor)?.alphaComponent,0)
        }
        XCTAssertEqual(page.edges[0],original)
    }

    func testNativeAndSVGExportsShowRunColorsSizesAndDecorationsAtPaperScaleOnce() throws {
        _ = NSApplication.shared
        var artifacts:[String:Data] = [:]
        var expectedCounts:[String:[Int]] = [:]
        for (name,factor) in [("unscaled",1.0),("scaled",0.02)] {
            let page = fixture(factor:factor),before = page
            let png = try DiagramExport.png(page,scale:2),pdf = DiagramExport.pdf(page),svg = DiagramDrawing.svg(page)
            let image = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData,nil)).flatMapImage()
            let counts = try coloredPixels(image)
            XCTAssertGreaterThan(counts[0],600);XCTAssertGreaterThan(counts[1],200)
            expectedCounts[name] = counts
            XCTAssertTrue(svg.contains("font-size=\"30.0\""));XCTAssertTrue(svg.contains("font-size=\"18.0\""))
            XCTAssertTrue(svg.contains("fill=\"#FF0000\""));XCTAssertTrue(svg.contains("fill=\"#0000FF\""))
            XCTAssertTrue(svg.contains("text-decoration=\"underline\""));XCTAssertTrue(svg.contains("font-style=\"italic\""))
            XCTAssertTrue(svg.contains("Red &lt;&amp;&gt; "))
            let xml = try XMLDocument(xmlString:svg,options:[])
            XCTAssertTrue(xml.rootElement()?.stringValue?.contains("Field 7") == true)
            let provider = try XCTUnwrap(CGDataProvider(data:pdf as CFData)),document = try XCTUnwrap(CGPDFDocument(provider))
            let pdfPage = try XCTUnwrap(document.page(at:1));XCTAssertEqual(pdfPage.getBoxRect(.mediaBox).width,500,accuracy:1e-8)
            let context = try XCTUnwrap(CGContext(data:nil,width:1000,height:480,bitsPerComponent:8,bytesPerRow:4000,
                space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x:2,y:2);context.drawPDFPage(pdfPage)
            let pdfCounts = try coloredPixels(XCTUnwrap(context.makeImage()))
            XCTAssertGreaterThan(pdfCounts[0],600);XCTAssertGreaterThan(pdfCounts[1],200)
            XCTAssertEqual(page,before)
            artifacts[name+".png"] = png;artifacts[name+".pdf"] = pdf;artifacts[name+".svg"] = Data(svg.utf8)
        }
        XCTAssertLessThanOrEqual(abs(expectedCounts["unscaled"]![0]-expectedCounts["scaled"]![0]),20)
        XCTAssertLessThanOrEqual(abs(expectedCounts["unscaled"]![1]-expectedCounts["scaled"]![1]),20)
        try retain(artifacts,scenario:"native-svg-paper-scale")
    }

    func testPublicReopenKeepsRunStylesAndFieldSourceBeforeRendering() throws {
        _ = NSApplication.shared
        var drawing = Diagram();drawing.page = fixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M3Labels-\(UUID())",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let file = directory.appendingPathComponent("native.vsdx");try VisioFormat.write(drawing,to:file)
        var parts = try VisioPackage.read(file)
        if let data = parts["macvisio/document.json"] {
            let native = try NativeMetadataStorage.load(data,parts:parts)
            for name in native.storageParts.union(["macvisio/document.json"]) { parts.removeValue(forKey:name) }
        }
        let root = try VisioXML.document(XCTUnwrap(parts["_rels/.rels"]))
        for relation in root.rootElement()?.elementsLocal("Relationship") ?? [] where relation.attr("Type") == "urn:macvisio:relationships:diagram" { relation.detach() }
        parts["_rels/.rels"] = root.xmlData(options:.nodePreserveAll)
        let types = try VisioXML.document(XCTUnwrap(parts["[Content_Types].xml"]))
        for item in types.rootElement()?.elementsLocal("Override") ?? [] where item.attr("PartName") == "/macvisio/document.json" { item.detach() }
        parts["[Content_Types].xml"] = types.xmlData(options:.nodePreserveAll)
        let publicURL = directory.appendingPathComponent("public.vsdx");try VisioPackage.write(parts,to:publicURL)
        let reopened = try VisioFormat.read(from:publicURL).diagram,edge = try XCTUnwrap(reopened.page.edges.first)
        let runs = try XCTUnwrap(edge.formatting.textRuns)
        XCTAssertEqual(try XCTUnwrap(runs.first?.character.size),30,accuracy:1e-8)
        XCTAssertEqual(try XCTUnwrap(runs.last?.character.size),18,accuracy:1e-8)
        XCTAssertEqual(runs.first?.character.color,"#FF0000");XCTAssertEqual(runs.last?.character.color,"#0000FF")
        XCTAssertEqual(edge.formatting.textFields?.first?.cells["Value"]?.formula,"GUARD(7)")
        let png = try DiagramExport.png(reopened.page,scale:2)
        let pixels = try coloredPixels(XCTUnwrap(CGImageSourceCreateWithData(png as CFData,nil)).flatMapImage())
        XCTAssertGreaterThan(pixels[0],600);XCTAssertGreaterThan(pixels[1],200)
        try retain(["public.vsdx":Data(contentsOf:publicURL),"public.png":png,"public.pdf":DiagramExport.pdf(reopened.page),
                    "public.svg":Data(DiagramDrawing.svg(reopened.page).utf8)],scenario:"public-reopen")
    }

    private func coloredPixels(_ image:CGImage) throws -> [Int] {
        let context = try XCTUnwrap(CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,
            space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to:UInt8.self)
        var counts = [0,0]
        for i in 0..<image.width*image.height {
            if bytes[i*4]>180 && bytes[i*4+1]<80 && bytes[i*4+2]<80 { counts[0] += 1 }
            if bytes[i*4+2]>180 && bytes[i*4]<80 && bytes[i*4+1]<80 { counts[1] += 1 }
        }
        return counts
    }
    private func retain(_ artifacts:[String:Data],scenario:String) throws {
        guard let path = ProcessInfo.processInfo.environment["M3_EVIDENCE_DIR"],!path.isEmpty else { return }
        guard (path as NSString).isAbsolutePath,["native-svg-paper-scale","public-reopen"].contains(scenario),artifacts.count <= 6 else {
            throw DiagramError.invalid("Connector label evidence requires an absolute directory and fixed scenario.")
        }
        let target = URL(fileURLWithPath:path,isDirectory:true).appendingPathComponent("M3ConnectorLabelTests",isDirectory:true).appendingPathComponent(scenario,isDirectory:true)
        try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
        var files:[[String:Any]] = []
        for (name,data) in artifacts.sorted(by:{$0.key<$1.key}) {
            guard data.count <= 16*1024*1024 else { throw DiagramError.invalid("Connector label evidence exceeds 16 MiB.") }
            try data.write(to:target.appendingPathComponent(name),options:.atomic)
            files.append(["path":name,"bytes":data.count,"sha256":SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()])
        }
        let data = try JSONSerialization.data(withJSONObject:["schema":"macvisio.m3.connector-labels.v1","scenario":scenario,
            "files":files,"reference_run":false,"scope":"Actual native and public-reopened styled labels at existing route midpoint; exact Visio label transforms and unsupported text families remain open."],options:[.prettyPrinted,.sortedKeys])
        guard data.count <= 64*1024 else { throw DiagramError.invalid("Connector label manifest exceeds 64 KiB.") }
        try data.write(to:target.appendingPathComponent("manifest.json"),options:.atomic)
    }
}

private extension CGImageSource {
    func flatMapImage() throws -> CGImage { try XCTUnwrap(CGImageSourceCreateImageAtIndex(self,0,nil)) }
}
