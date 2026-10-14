import Foundation

/// Cached lengths stay in Visio drawing inches. Rendering converts them to
/// paper inches using PageScale / DrawingScale; font size and line weight do not.
struct DrawingScale:Codable,Equatable {
    var page:Double = 1
    var drawing:Double = 1
    var pageUnit:String?
    var drawingUnit:String?
    var type:Int?
    var factor:Double { page/drawing }
    var isValid:Bool { page.isFinite && drawing.isFinite && page > 0 && drawing > 0 && factor.isFinite && (1e-6...1e6).contains(factor) }
    static func read(_ cells:[String:ShapeSheetCell]) throws -> DrawingScale? {
        guard cells["PageScale"] != nil || cells["DrawingScale"] != nil else { return nil }
        let result = DrawingScale(page:Double(cells["PageScale"]?.value ?? "1") ?? .nan,drawing:Double(cells["DrawingScale"]?.value ?? "1") ?? .nan,pageUnit:cells["PageScale"]?.unit,drawingUnit:cells["DrawingScale"]?.unit,type:cells["DrawingScaleType"].flatMap{Int($0.value)})
        guard result.isValid else { throw DiagramError.invalid("The drawing scale is invalid or outside the supported range.") }
        if result.page == 1,result.drawing == 1,(result.pageUnit ?? "").isEmpty,(result.drawingUnit ?? "").isEmpty,(result.type ?? 0) == 0 { return nil };return result
    }
    static func write(_ page:DiagramPage,to sheet:XMLElement) {
        let scale = page.drawingScale ?? DrawingScale()
        VisioXML.set(sheet,"PageScale",scale.page);VisioXML.set(sheet,"DrawingScale",scale.drawing)
        VisioXML.set(sheet,"DrawingScaleType",Double(scale.type ?? (scale.factor == 1 ? 0 : 3)))
        for (name,unit) in [("PageScale",scale.pageUnit),("DrawingScale",scale.drawingUnit)] { if let unit { sheet.elementsLocal("Cell").first{$0.attr("N") == name}?.setAttr("U",unit) } }
    }
    static func paperNode(_ input:DiagramNode,factor:Double) -> DiagramNode {
        var node = input;node.x *= factor;node.y *= factor;node.width *= factor;node.height *= factor
        if var box = node.formatting.textBox { box.left *= factor;box.right *= factor;box.top *= factor;box.bottom *= factor;node.formatting.textBox = box }
        return node
    }
    static func hydrate(_ input:Diagram) throws -> Diagram? {
        guard var archive = input.visioArchive,let data = archive.parts[archive.pagesPart] else { return nil }
        let root = try VisioXML.document(data).rootElement(),entries = root?.elementsLocal("Page") ?? []
        var result = input,changed = false
        for i in result.pages.indices where result.pages[i].drawingScale == nil {
            guard let b = archive.pages.firstIndex(where:{$0.pageID == result.pages[i].id}),let entry = entries.first(where:{$0.attr("ID") == archive.pages[b].visioID}),let sheet = entry.firstLocal("PageSheet") else { continue }
            let cells = sheet.elementsLocal("Cell").reduce(into:[String:ShapeSheetCell]()){if let name = $1.attr("N"),let value = $1.attr("V") { $0[name] = ShapeSheetCell(value:value,formula:$1.attr("F") ?? "",unit:$1.attr("U") ?? "") } }
            if let scale = try read(cells) { result.pages[i].drawingScale = scale;archive.pages[b].original.drawingScale = scale;changed = true }
        }
        result.visioArchive = archive;return changed ? result : nil
    }
    static func convert(_ input:DiagramPage,to factor:Double,targetMeasured:Bool? = nil) -> DiagramPage {
        let measured = targetMeasured ?? (factor != 1)
        if input.paperScale == factor,input.isMeasured == measured { return input }
        // Measured shapes keep real dimensions between measured drawings.
        // Crossing measured/unmeasured spaces preserves their paper size.
        let ratio = input.isMeasured == measured ? 1 : input.paperScale/factor
        var page = input;page.width *= ratio;page.height *= ratio;page.drawingScale = factor == 1 && !measured ? nil : DrawingScale(page:factor,drawing:1,type:measured ? 3 : 0)
        let lengths:Set<String> = ["Width","Height","PinX","PinY","LocPinX","LocPinY"]
        for i in page.nodes.indices {
            let original = input.nodes[i];var node = original
            node.formatting.sheet["DropOnPageScale"] = ShapeSheetCell(value:ShapeSheetEngine.format(ratio))
            if ratio == 1 { page.nodes[i] = node;continue }
            node.x *= ratio;node.y *= ratio;node.width *= ratio;node.height *= ratio
            if var box = node.formatting.textBox { box.left *= ratio;box.right *= ratio;box.top *= ratio;box.bottom *= ratio;node.formatting.textBox = box }
            // Full source-master behavior needs retained master instances. For a
            // cached fragment crossing scales, materialize geometry expressions
            // so literal source lengths cannot revert the resized public shape.
            for key in lengths where node.formatting.sheet[key] != nil { if let value = Double(node.formatting.sheet[key]!.value) { node.formatting.sheet[key] = ShapeSheetCell(value:ShapeSheetEngine.format(value*ratio),unit:node.formatting.sheet[key]!.unit) } }
            if let geometry = node.formatting.geometry { node.formatting.geometry = GeometrySheet.scaled(geometry,by:ratio) }
            node.formatting.controls = ControlGeometry.scaled(node.formatting.controls,by:ratio)
            for j in node.formatting.connectionPoints.indices {
                let point = ConnectionGeometry.local(original.formatting.connectionPoints[j],on:original)
                func cell(_ old:ShapeSheetCell,_ value:Double) -> ShapeSheetCell {
                    let evaluated = try? ShapeSheet.evaluate(old.formula){name in if name.caseInsensitiveCompare("Width") == .orderedSame { return node.sheetWidth/72 };if name.caseInsensitiveCompare("Height") == .orderedSame { return node.sheetHeight/72 };throw DiagramError.invalid("Unresolved scaled port") }
                    return ShapeSheetCell(value:ShapeSheetEngine.format(value),formula:evaluated.map{abs($0-value)<1e-9 ? old.formula : ""} ?? "",unit:old.unit)
                }
                node.formatting.connectionPoints[j].x = cell(original.formatting.connectionPoints[j].x,point.x*ratio);node.formatting.connectionPoints[j].y = cell(original.formatting.connectionPoints[j].y,point.y*ratio)
            }
            page.nodes[i] = node
        }
        for i in page.edges.indices {
            if let p = page.edges[i].sourcePosition { page.edges[i].sourcePosition = DiagramPoint(x:p.x*ratio,y:p.y*ratio) };if let p = page.edges[i].targetPosition { page.edges[i].targetPosition = DiagramPoint(x:p.x*ratio,y:p.y*ratio) }
            page.edges[i].points = page.edges[i].points?.map{DiagramPoint(x:$0.x*ratio,y:$0.y*ratio)}
        };return page
    }
}
