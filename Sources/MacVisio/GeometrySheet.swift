import Foundation

struct ShapeGeometryRow:Codable,Equatable {
    var index:Int
    var type:String
    var cells:[String:ShapeSheetCell]
}
struct ShapeGeometrySection:Codable,Equatable {
    var index:Int
    var cells:[String:ShapeSheetCell]
    var rows:[ShapeGeometryRow]
    var valid:Bool { index >= 0 && index <= UInt32.max && rows.count <= 100000 && Set(rows.map(\.index)).count == rows.count && rows.allSatisfy{$0.index >= 0 && $0.index <= UInt32.max && $0.type.utf8.count <= 256 && $0.cells.count <= 64 && $0.cells.values.allSatisfy{$0.formula.utf8.count <= 16384}} && cells.count <= 64 && cells.values.allSatisfy{$0.formula.utf8.count <= 16384} }
}
enum GeometrySheet {
    struct Address { var section:Int;var row:Int?;var cell:String }
    static func address(_ reference:String) -> Address? {
        guard let regex = try? NSRegularExpression(pattern:"^Geometry([1-9][0-9]*)\\.([A-Za-z]+)([0-9]*)$",options:.caseInsensitive),let match = regex.firstMatch(in:reference,range:NSRange(reference.startIndex...,in:reference)),let s = Range(match.range(at:1),in:reference),let c = Range(match.range(at:2),in:reference),let r = Range(match.range(at:3),in:reference),let section = Int(reference[s]),section <= Int(UInt32.max)+1 else { return nil }
        var row:Int?;if !reference[r].isEmpty { guard let index = UInt32(reference[r]) else { return nil };row = Int(index) };return Address(section:section-1,row:row,cell:String(reference[c]))
    }
    static func cell(_ reference:String,on node:DiagramNode) -> ShapeSheetCell? {
        guard let a = address(reference),let section = node.formatting.geometry?.first(where:{$0.index == a.section}) else { return nil }
        let cells = a.row.flatMap{row in section.rows.first{$0.index == row}?.cells} ?? (a.row == nil ? section.cells : [:])
        return cells.first{$0.key.caseInsensitiveCompare(a.cell) == .orderedSame}?.value
    }
    static func names(_ sections:[ShapeGeometrySection]) -> [String] {
        sections.flatMap { section in section.cells.keys.sorted().map{"Geometry\(section.index+1)."+$0}+section.rows.flatMap{row in row.cells.keys.sorted().map{"Geometry\(section.index+1)."+$0+String(row.index)}} }
    }
    static func compositeType(_ reference:String,on node:DiagramNode) -> String? {
        guard let a = address(reference),let row = a.row,let definition = node.formatting.geometry?.first(where:{$0.index == a.section})?.rows.first(where:{$0.index == row}) else { return nil }
        if definition.type.uppercased() == "NURBSTO",a.cell.uppercased() == "E" { return "NURBS" }
        if definition.type.uppercased() == "POLYLINETO",a.cell.uppercased() == "A" { return "POLYLINE" };return nil
    }
    static func set(_ reference:String,_ cell:ShapeSheetCell,on node:inout DiagramNode) throws {
        guard let a = address(reference),var sections = node.formatting.geometry,let i = sections.firstIndex(where:{$0.index == a.section}) else { throw DiagramError.invalid("Unknown geometry section.") }
        if let row = a.row {
            guard let j = sections[i].rows.firstIndex(where:{$0.index == row}) else { throw DiagramError.invalid("Unknown geometry row.") }
            let key = sections[i].rows[j].cells.keys.first{$0.caseInsensitiveCompare(a.cell) == .orderedSame} ?? a.cell;sections[i].rows[j].cells[key] = cell
        } else { let key = sections[i].cells.keys.first{$0.caseInsensitiveCompare(a.cell) == .orderedSame} ?? a.cell;sections[i].cells[key] = cell }
        node.formatting.geometry = sections
    }
    static func patch(_ sections:[ShapeGeometrySection],element:XMLElement,previous:[ShapeGeometrySection] = []) {
        for removed in previous where !sections.contains(where:{$0.index == removed.index}) {
            let section = element.elementsLocal("Section").first{$0.attr("N") == "Geometry" && $0.attr("IX") == String(removed.index)} ?? XMLElement(name:"Section")
            if section.parent == nil { section.setAttr("N","Geometry");section.setAttr("IX",String(removed.index));element.addChild(section) };section.setAttr("Del","1")
        }
        func patchCells(_ cells:[String:ShapeSheetCell],old:[String:ShapeSheetCell],on element:XMLElement) {
            for (key,cell) in cells where old[key] != cell {
                let value = VisioXML.set(element,key,cell.value,formula:cell.formula.isEmpty ? nil : cell.formula);value.setAttr("U",cell.unit.isEmpty ? nil : cell.unit)
            }
        }
        for value in sections {
            let old = previous.first{$0.index == value.index};if old == value { continue }
            let section = element.elementsLocal("Section").first{$0.attr("N") == "Geometry" && $0.attr("IX") == String(value.index)} ?? XMLElement(name:"Section")
            if section.parent == nil { section.setAttr("N","Geometry");section.setAttr("IX",String(value.index));element.addChild(section) };section.setAttr("Del",nil)
            patchCells(value.cells,old:old?.cells ?? [:],on:section)
            for removed in old?.rows ?? [] where !value.rows.contains(where:{$0.index == removed.index}) {
                let row = section.elementsLocal("Row").first{$0.attr("IX") == String(removed.index)} ?? XMLElement(name:"Row")
                if row.parent == nil { row.setAttr("IX",String(removed.index));section.addChild(row) };row.setAttr("Del","1")
            }
            for value in value.rows {
                let oldRow = old?.rows.first{$0.index == value.index};if oldRow == value { continue }
                let row = section.elementsLocal("Row").first{$0.attr("IX") == String(value.index)} ?? XMLElement(name:"Row")
                if row.parent == nil { row.setAttr("IX",String(value.index));section.addChild(row) };row.setAttr("Del",nil)
                if oldRow?.type != value.type { row.setAttr("T",value.type) };patchCells(value.cells,old:oldRow?.cells ?? [:],on:row)
            }
        }
    }
    static func scaled(_ input:[ShapeGeometrySection],by ratio:Double) -> [ShapeGeometrySection] {
        input.map { section in var section = section
            for r in section.rows.indices {
                let type = section.rows[r].type
                if type.hasPrefix("Rel") { continue }
                let extra:Set<String>
                switch type { case "CubBezTo","QuadBezTo","Ellipse":extra = ["A","B","C","D"];case "EllipticalArcTo":extra = ["A","B"];case "ArcTo":extra = ["A"];default:extra = [] }
                for key in section.rows[r].cells.keys where ["X","Y"].contains(key) || extra.contains(key) {
                    if let value = Double(section.rows[r].cells[key]!.value) { section.rows[r].cells[key]?.value = ShapeSheetEngine.format(value*ratio);section.rows[r].cells[key]?.formula = "" }
                }
                let key = type.uppercased() == "NURBSTO" ? "E" : type.uppercased() == "POLYLINETO" ? "A" : ""
                if let cell = section.rows[r].cells[key],let data = try? CompositeGeometry.evaluate(cell.value,numeric:{_ in throw DiagramError.invalid("Unresolved cached geometry")},cached:true) {
                    section.rows[r].cells[key]?.value = data.scaled(by:ratio).formula;section.rows[r].cells[key]?.formula = ""
                }
            };return section
        }
    }
    static func refreshCompositeCaches(_ input:Diagram) -> Diagram {
        var result = input
        for p in result.pages.indices { for i in result.pages[p].nodes.indices {
            let node = result.pages[p].nodes[i]
            guard let sections = node.formatting.geometry,sections.contains(where:{$0.rows.contains{["NURBSTO","POLYLINETO","SPLINESTART","SPLINEKNOT"].contains($0.type.uppercased())}}) else { continue }
            let rendered = VisioFormat.geometryPaths(sections,width:node.sheetWidth/72,height:node.sheetHeight/72)
            if rendered.warnings.isEmpty,rendered.paths.reduce(0,{$0+$1.commands.count}) <= 100000,rendered.paths.flatMap(\.commands).allSatisfy({$0.isValid(xScale:node.width*result.pages[p].paperScale,yScale:node.height*result.pages[p].paperScale)}) { result.pages[p].nodes[i].formatting.paths = rendered.paths }
        } };return result
    }
}
