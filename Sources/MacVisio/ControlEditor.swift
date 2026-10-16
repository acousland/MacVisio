import AppKit

enum ControlEditor {
    static let numericCells = ["X","Y","XDyn","YDyn","XCon","YCon","CanGlue"]
    static func cached(_ value:String,for key:String) throws -> String {
        guard numericCells.contains(where:{$0.caseInsensitiveCompare(key) == .orderedSame}) else { return value }
        let number = try ShapeSheet.evaluate(value){_ in throw DiagramError.invalid("Put references in the Formula column.") }
        if ["XCon","YCon"].contains(key) { guard let mode = Int(exactly:number),(0...9).contains(mode) else { throw DiagramError.invalid("Control behavior must be an integer from 0 to 9.") } }
        return CompositeGeometry.number(number)
    }
    static func replace(_ input:Diagram,controls:[ShapeControl],on id:UUID) throws -> Diagram {
        var next = input
        guard let i = next.page.nodes.firstIndex(where:{$0.id == id}),!next.page.isLocked(next.page.nodes[i]) else { throw DiagramError.invalid("Select an unlocked shape to edit controls.") }
        let old = next.page.nodes[i].formatting.controls
        var controls = controls
        let renames = old.reduce(into:[String:String]()){result,control in
            if let new = controls.first(where:{$0.index == control.index}),new.name != control.name { result[control.name.lowercased()] = new.name }
        }
        for c in controls.indices where old.contains(where:{$0.index == controls[c].index && $0.name != controls[c].name}) { controls[c].sourceIndex = nil }
        next.page.nodes[i].formatting.controls = controls
        _ = try next.validated()
        if !renames.isEmpty {
            let binding = next.visioArchive?.pages.first{$0.pageID == next.page.id},sheetID = binding?.nodeIDs[id] ?? next.page.nodes[i].formatting.sourceShapeID ?? String(i+1)
            for j in next.page.nodes.indices {
                func rewrite(_ formula:String) -> String { remap(formula,renames:renames,local:j == i,sheetID:sheetID) }
                var n = next.page.nodes[j]
                for key in n.formatting.sheet.keys { let formula = n.formatting.sheet[key]!.formula;n.formatting.sheet[key]?.formula = rewrite(formula) }
                for c in n.formatting.controls.indices { for key in n.formatting.controls[c].cells.keys { let formula = n.formatting.controls[c].cells[key]!.formula;n.formatting.controls[c].cells[key]?.formula = rewrite(formula) } }
                for c in n.formatting.connectionPoints.indices { n.formatting.connectionPoints[c].x.formula = rewrite(n.formatting.connectionPoints[c].x.formula);n.formatting.connectionPoints[c].y.formula = rewrite(n.formatting.connectionPoints[c].y.formula) }
                if var geometry = n.formatting.geometry {
                    for s in geometry.indices { for key in geometry[s].cells.keys { let formula = geometry[s].cells[key]!.formula;geometry[s].cells[key]?.formula = rewrite(formula) };for r in geometry[s].rows.indices { for key in geometry[s].rows[r].cells.keys { let formula = geometry[s].rows[r].cells[key]!.formula;geometry[s].rows[r].cells[key]?.formula = rewrite(formula) } } };n.formatting.geometry = geometry
                }
                if var fields = n.formatting.textFields { for f in fields.indices { for key in fields[f].cells.keys { let formula = fields[f].cells[key]!.formula;fields[f].cells[key]?.formula = rewrite(formula) } };n.formatting.textFields = fields }
                next.page.nodes[j] = n
            }
        }
        let before = Set(ShapeSheetEngine.recalculate(input).issues),result = ShapeSheetEngine.recalculate(next,previous:input),added = Set(result.issues).subtracting(before)
        guard added.isEmpty else { throw DiagramError.invalid(added.sorted().prefix(4).joined(separator:"\n")) }
        return try result.diagram.validated()
    }
    // Rewrite only actual references. Quoted text and references on other sheets
    // retain their exact source spelling and whitespace.
    static func remap(_ formula:String,renames:[String:String],local:Bool,sheetID:String) -> String {
        let names = renames.keys.sorted{$0.count > $1.count}.map(NSRegularExpression.escapedPattern(for:)).joined(separator:"|")
        guard !names.isEmpty,let regex = try? NSRegularExpression(pattern:"(?i)(?<![\\p{L}\\p{N}_.!])(?:(Sheet\\.([0-9]+))!)?Controls\\.("+names+")(?=\\.|[^\\p{L}\\p{N}_]|$)") else { return formula }
        let units = Array(formula.utf16);var quoted = Array(repeating:false,count:units.count),inside = false,index = 0
        while index < units.count { quoted[index] = inside;if units[index] == 34 { if inside,index+1 < units.count,units[index+1] == 34 { quoted[index+1] = true;index += 2;continue };inside.toggle() };index += 1 }
        var result = formula
        for match in regex.matches(in:formula,range:NSRange(formula.startIndex...,in:formula)).reversed() {
            guard !quoted[match.range.location],let nameRange = Range(match.range(at:3),in:formula),let name = renames[String(formula[nameRange]).lowercased()] else { continue }
            let sheet = Range(match.range(at:2),in:formula).map{String(formula[$0])}
            guard sheet.map({UInt32($0) == UInt32(sheetID)}) ?? local,let destination = Range(match.range(at:3),in:result) else { continue };result.replaceSubrange(destination,with:name)
        };return result
    }
}

extension EditorWindowController {
    func setControls(_ controls:[ShapeControl],for id:UUID) throws {
        canvas.finishEditing(commit:true);canvas.finishPageInteraction()
        diagramDocument.replaceInEditor(with:try ControlEditor.replace(diagramDocument.diagram,controls:controls,on:id),action:"Edit Control Handles")
    }
    func setControlCell(_ name:String,value:String,formula:String,for id:UUID) throws {
        let input = diagramDocument.diagram
        guard let node = input.page.nodes.first(where:{$0.id == id}),let (c,key) = ControlGeometry.address(name,on:node) else { throw DiagramError.invalid("Unknown control cell.") }
        var controls = node.formatting.controls
        let stored = controls[c].cells.keys.first{$0.caseInsensitiveCompare(key) == .orderedSame} ?? key
        controls[c].cells[stored] = ShapeSheetCell(value:try ControlEditor.cached(value,for:key),formula:formula,unit:controls[c].cell(key)?.unit ?? "")
        try setControls(controls,for:id)
    }
    @objc func editControls(_ sender:Any?) {
        canvas.finishPageInteraction();guard selection.count == 1,let node = selection.first,!diagramDocument.diagram.page.isLocked(node) else { return }
        let grid = PropertyGrid(columns:["Name","Index","X","X Formula","Y","Y Formula","X Behavior","Y Behavior","Tip"],rows:node.formatting.controls.map{[$0.name,String($0.index),$0.cell("X")?.value ?? "0",$0.cell("X")?.formula ?? "",$0.cell("Y")?.value ?? "0",$0.cell("Y")?.formula ?? "",$0.cell("XCon")?.value ?? "0",$0.cell("YCon")?.value ?? "0",$0.cell("Tip")?.value ?? ""]},width:1080)
        guard grid.run(title:"Control Handles",message:"X and Y use local inches from the lower-left corner. Behavior: 0 proportional, 1 locked, 2 offset from minimum edge, 3 center, 4 maximum edge; add 5 to hide. Keep the index when renaming a control to update its references.") else { return }
        do {
            var controls:[ShapeControl] = []
            for row in grid.rows where !row.allSatisfy(\.isEmpty) {
                guard let index = UInt32(row[1]) else { throw DiagramError.invalid("Each control needs a unique name and a zero-based index.") }
                var control = node.formatting.controls.first{$0.index == Int(index)} ?? ShapeControl(name:row[0],index:Int(index),cells:[:]);control.name = row[0]
                for (key,value,formula) in [("X",row[2],row[3]),("Y",row[4],row[5]),("XCon",row[6].isEmpty ? "0" : row[6],control.cell("XCon")?.formula ?? ""),("YCon",row[7].isEmpty ? "0" : row[7],control.cell("YCon")?.formula ?? ""),("Prompt",row[8],control.cell("Prompt")?.formula ?? "")] {
                    let stored = control.cells.keys.first{$0.caseInsensitiveCompare(key) == .orderedSame} ?? key
                    control.cells[stored] = ShapeSheetCell(value:try ControlEditor.cached(value,for:key),formula:formula,unit:control.cell(key)?.unit ?? "")
                };controls.append(control)
            };try setControls(controls,for:node.id)
        } catch { presentError(error) }
    }
    @objc func editControlCells(_ sender:Any?) {
        canvas.finishPageInteraction();guard selection.count == 1,let node = selection.first,!node.formatting.controls.isEmpty,!diagramDocument.diagram.page.isLocked(node) else { return }
        let names = node.formatting.controls.flatMap{control in Array(Set(control.cells.keys).union(ControlEditor.numericCells+["Prompt"])).sorted().map{"Controls."+control.name+"."+$0}}
        let grid = PropertyGrid(columns:["Cell","Cached value","Formula"],rows:names.map{name in let cell = ControlGeometry.cell(name,on:node);return [name,cell?.value ?? "0",cell?.formula ?? ""]},width:900)
        guard grid.run(title:"Control Cells",message:"Edit the coordinate, anchor, behavior, glue and tooltip cells. Use Control Handles to add, rename or remove rows.") else { return }
        do {
            var n = node
            for row in grid.rows {
                guard names.contains(row[0]),let (_,key) = ControlGeometry.address(row[0],on:n) else { throw DiagramError.invalid("Edit existing control cell names.") }
                let old = ControlGeometry.cell(row[0],on:n)
                if old?.value == row[1],old?.formula == row[2] { continue }
                try ControlGeometry.set(row[0],ShapeSheetCell(value:try ControlEditor.cached(row[1],for:key),formula:row[2],unit:old?.unit ?? ""),on:&n)
            };try setControls(n.formatting.controls,for:node.id)
        } catch { presentError(error) }
    }
}
