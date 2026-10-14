import AppKit

extension EditorWindowController {
    func setGeometryCell(_ name:String,value:String,formula:String,for id:UUID) throws {
        var next = diagramDocument.diagram;guard let i = next.page.nodes.firstIndex(where:{$0.id == id}),!next.page.isLocked(next.page.nodes[i]) else { return }
        let old = GeometrySheet.cell(name,on:next.page.nodes[i]);guard old != nil else { throw DiagramError.invalid("Unknown geometry cell.") }
        let cached = try geometryCachedValue(value,formula:formula,name:name,node:next.page.nodes[i])
        try GeometrySheet.set(name,ShapeSheetCell(value:cached,formula:formula,unit:old?.unit ?? ""),on:&next.page.nodes[i])
        let before = Set(ShapeSheetEngine.recalculate(diagramDocument.diagram).issues),calculated = ShapeSheetEngine.recalculate(next,previous:diagramDocument.diagram)
        let added = Set(calculated.issues).subtracting(before);guard added.isEmpty else { throw DiagramError.invalid(added.sorted().prefix(4).joined(separator:"\n")) }
        diagramDocument.replace(with:try calculated.diagram.validated(),action:"Edit Geometry Cell")
    }
    private func geometryCachedValue(_ value:String,formula:String,name:String,node:DiagramNode) throws -> String {
        if !formula.isEmpty { return value }
        if let type = GeometrySheet.compositeType(name,on:node) {
            let data = try CompositeGeometry.evaluate(value,numeric:{_ in throw DiagramError.invalid("Put references in the Formula column")},cached:true);guard data.name == type else { throw DiagramError.invalid("Wrong composite geometry type.") };return data.formula
        }
        return ShapeSheetEngine.format(try ShapeSheet.evaluate(value){_ in throw DiagramError.invalid("Put references in the Formula column")})
    }
    @objc func editGeometry(_ sender:Any?) {
        canvas.finishEditing(commit:true);guard selection.count == 1,let node = selection.first,let sections = node.formatting.geometry,!diagramDocument.diagram.page.isLocked(node) else { return }
        let names = GeometrySheet.names(sections),grid = PropertyGrid(columns:["Cell","Cached value","Formula"],rows:names.map{name in let cell = GeometrySheet.cell(name,on:node)!;return [name,cell.value,cell.formula]},width:900)
        guard grid.run(title:"Geometry",message:"Geometry cells use local inches, radians or relative coordinates according to the row type. Formulas may refer to Width, Height, User cells, other geometry cells and Sheet IDs.") else { return }
        do {
            var next = diagramDocument.diagram;let i = next.page.nodes.firstIndex{$0.id == node.id}!
            for row in grid.rows {
                guard let old = GeometrySheet.cell(row[0],on:node) else { throw DiagramError.invalid("Edit existing geometry cell names.") }
                if old.value == row[1],old.formula == row[2] { continue }
                let value = try geometryCachedValue(row[1],formula:row[2],name:row[0],node:node)
                try GeometrySheet.set(row[0],ShapeSheetCell(value:value,formula:row[2],unit:old.unit),on:&next.page.nodes[i])
            }
            let before = Set(ShapeSheetEngine.recalculate(diagramDocument.diagram).issues),result = ShapeSheetEngine.recalculate(next,previous:diagramDocument.diagram)
            let added = Set(result.issues).subtracting(before);guard added.isEmpty else { throw DiagramError.invalid(added.sorted().prefix(4).joined(separator:"\n")) }
            diagramDocument.replace(with:try result.diagram.validated(),action:"Edit Geometry")
        } catch { presentError(error) }
    }
}
