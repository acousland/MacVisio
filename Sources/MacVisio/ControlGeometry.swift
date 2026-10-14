import Foundation
import CoreGraphics

struct ShapeControl:Codable,Equatable {
    var name:String
    var index:Int
    var cells:[String:ShapeSheetCell]
    var sourceIndex:Int?
    var valid:Bool { !name.isEmpty && name.utf8.count <= 256 && !name.contains("!") && !name.contains(".") && index >= 0 && index <= UInt32.max && cells.count <= 64 && cells.values.allSatisfy{$0.formula.utf8.count <= 16384 && $0.value.utf8.count <= 131072} }
    func cell(_ key:String) -> ShapeSheetCell? {
        let canonical = key.caseInsensitiveCompare("Tip") == .orderedSame ? "Prompt" : key
        return cells.first{$0.key.caseInsensitiveCompare(canonical) == .orderedSame}?.value ?? (["TIP","PROMPT"].contains(key.uppercased()) ? cells.first{$0.key.caseInsensitiveCompare("Tip") == .orderedSame}?.value : nil)
    }
    func behavior(_ axis:String) -> Int { cell(axis+"Con").flatMap{Double($0.value)}.flatMap{Int(exactly:$0)} ?? 0 }
    var visible:Bool { behavior("X") < 5 && behavior("Y") < 5 && [cell("X"),cell("Y")].allSatisfy{$0.flatMap{Double($0.value)}.map{$0.isFinite && abs($0)<100000} ?? false} }
}
enum ControlGeometry {
    static func address(_ reference:String,on node:DiagramNode) -> (Int,String)? {
        guard reference.lowercased().hasPrefix("controls.") else { return nil }
        let tail = String(reference.dropFirst(9)),fields = ["X","Y","XCon","YCon","XDyn","YDyn","CanGlue","Tip","Prompt"]
        var row = tail,key = "X"
        if let dot = tail.lastIndex(of:"."),let field = fields.first(where:{$0.caseInsensitiveCompare(String(tail[tail.index(after:dot)...])) == .orderedSame}) { row = String(tail[..<dot]);key = field }
        if let index = node.formatting.controls.firstIndex(where:{$0.name.caseInsensitiveCompare(row) == .orderedSame}) { return (index,key) }
        if row.count > 1,let axis = row.first,["X","Y","x","y"].contains(axis),let number = UInt32(row.dropFirst()),number > 0,let i = node.formatting.controls.firstIndex(where:{$0.index == number-1}) { return (i,String(axis).uppercased()) };return nil
    }
    static func cell(_ reference:String,on node:DiagramNode) -> ShapeSheetCell? { guard let (i,key) = address(reference,on:node) else { return nil };return node.formatting.controls[i].cell(key) }
    static func set(_ reference:String,_ cell:ShapeSheetCell,on node:inout DiagramNode) throws {
        guard let (i,key) = address(reference,on:node) else { throw DiagramError.invalid("Unknown control handle cell.") };let canonical = key.caseInsensitiveCompare("Tip") == .orderedSame ? "Prompt" : key;let stored = node.formatting.controls[i].cells.keys.first{$0.caseInsensitiveCompare(canonical) == .orderedSame} ?? canonical;node.formatting.controls[i].cells[stored] = cell
    }
    static func point(_ control:ShapeControl,on node:DiagramNode) -> CGPoint {
        let x = Double(control.cell("X")?.value ?? "") ?? 0,y = Double(control.cell("Y")?.value ?? "") ?? 0
        return DiagramCoordinates.world(CGPoint(x:x*72-node.sheetOrigin.x,y:node.height-y*72+node.sheetOrigin.y),in:node)
    }
    static func resized(_ controls:[ShapeControl],from old:DiagramNode,to node:DiagramNode) -> [ShapeControl] {
        controls.map { control in var control = control
            for axis in ["X","Y"] { guard var cell = control.cell(axis),cell.formula.isEmpty || ["Inh","No Formula"].contains(cell.formula),let value = Double(cell.value) else { continue }
                let before = (axis == "X" ? old.sheetWidth : old.sheetHeight)/72,after = (axis == "X" ? node.sheetWidth : node.sheetHeight)/72,behavior = control.behavior(axis)%5
                let next = behavior <= 1 && before != 0 ? value*after/before : behavior == 3 ? value+(after-before)/2 : behavior == 4 ? value+after-before : value
                cell.value = CompositeGeometry.number(next);let key = control.cells.keys.first{$0.caseInsensitiveCompare(axis) == .orderedSame} ?? axis;control.cells[key] = cell
            };return control
        }
    }
    static func scaled(_ controls:[ShapeControl],by ratio:Double) -> [ShapeControl] {
        controls.map { value in var value = value
            for key in value.cells.keys where ["X","Y","XDYN","YDYN"].contains(key.uppercased()) { if let number = Double(value.cells[key]!.value) { value.cells[key]?.value = CompositeGeometry.number(number*ratio);value.cells[key]?.formula = "" } };return value
        }
    }
    static func patch(_ controls:[ShapeControl],on element:XMLElement,previous:[ShapeControl] = []) {
        let section = element.elementsLocal("Section").first{["Control","Controls"].contains($0.attr("N") ?? "")} ?? VisioXML.section(element,"Control")
        func row(_ control:ShapeControl) -> XMLElement {
            if let found = section.elementsLocal("Row").first(where:{$0.attr("N") == control.name}) { return found }
            if let index = control.sourceIndex,let found = section.elementsLocal("Row").first(where:{$0.attr("IX") == String(index)}) { return found }
            if let found = section.elementsLocal("Row").first(where:{$0.attr("N") == nil && $0.attr("IX") == String(control.index)}) { return found }
            let created = XMLElement(name:"Row");created.setAttr("N",control.name);section.addChild(created);return created
        }
        var renamed = Set<String>()
        let inherited = element.attr("Master") != nil || element.attr("MasterShape") != nil
        for control in controls {
            let old = previous.first{$0.index == control.index};if old == control { continue }
            let target:XMLElement
            if let old,old.name != control.name,!inherited,let existing = section.elementsLocal("Row").first(where:{$0.attr("N") == old.name || ($0.attr("N") == nil && $0.attr("IX") == String(old.sourceIndex ?? old.index))}) {
                target = existing;target.setAttr("N",control.name);renamed.insert(old.name)
            } else if let old,old.name != control.name {
                target = XMLElement(name:"Row");target.setAttr("N",control.name);section.addChild(target)
            } else { target = row(control) }
            target.setAttr("Del",nil)
            for (key,cell) in control.cells where old?.cells[key] != cell || (old?.name != control.name && !renamed.contains(old?.name ?? "")) { let entry = VisioXML.set(target,key == "Tip" ? "Prompt" : key,cell.value,formula:cell.formula.isEmpty ? nil : cell.formula);entry.setAttr("U",cell.unit.isEmpty ? nil : cell.unit) }
            if target.elementsLocal("Cell").isEmpty { for (key,cell) in control.cells { let entry = VisioXML.set(target,key == "Tip" ? "Prompt" : key,cell.value,formula:cell.formula.isEmpty ? nil : cell.formula);entry.setAttr("U",cell.unit.isEmpty ? nil : cell.unit) } }
        }
        for removed in previous where !renamed.contains(removed.name) && !controls.contains(where:{$0.name == removed.name}) { row(removed).setAttr("Del","1") }
    }
}
