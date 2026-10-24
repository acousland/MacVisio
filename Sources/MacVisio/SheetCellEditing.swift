import Foundation

enum SheetCellEditing {
    static func set(_ key:String,value:String,formula:String,unit:String,on node:inout DiagramNode) throws {
        if let reason = DiagramMemberships.managedCellReason(key) { throw DiagramError.invalid(reason) }
        guard ShapeSheetEngine.geometryKeys.contains(key) || ShapeSheetEngine.textKeys.contains(key) || key.lowercased().hasPrefix("user.") || key.lowercased().hasPrefix("prop."),unit.utf8.count <= 64 else { throw DiagramError.invalid("Use a supported transform/text cell, User.* or Prop.*.") }
        let property = key.lowercased().hasPrefix("prop.") ? node.formatting.data.firstIndex{$0.key.caseInsensitiveCompare(String(key.dropFirst(5))) == .orderedSame} : nil
        let textProperty = property.map{![2,3,5,6,7].contains(node.formatting.data[$0].type)} ?? false
        var cached = value,resolvedUnit = unit
        if formula.isEmpty {
            if unit.uppercased() == "DATE" || property.map({node.formatting.data[$0].type == 5}) == true { guard FieldFormatting.date(value) != nil else { throw DiagramError.invalid("Enter a valid date.") } }
            else if unit.uppercased() == "STR" || textProperty { cached = value;if resolvedUnit.isEmpty { resolvedUnit = "STR" } }
            else if let number = try? ShapeSheet.evaluate(value,resolve:{_ in throw DiagramError.invalid("Put references in the Formula column.")}) { cached = CompositeGeometry.number(number) }
            else if key.lowercased().hasPrefix("user.") { cached = value;resolvedUnit = "STR" }
            else { throw DiagramError.invalid("Enter a numeric cached value or a formula.") }
        }
        node.formatting.sheet[key] = ShapeSheetCell(value:cached,formula:formula,unit:resolvedUnit)
        if let property { node.formatting.data[property].value = cached }
    }
}

extension EditorWindowController {
    func setShapeSheetCell(_ key:String,value:String,formula:String,unit:String? = nil,for id:UUID) throws {
        if let reason = DiagramMemberships.managedCellReason(key) { throw DiagramError.invalid(reason) }
        canvas.finishPageInteraction();let old = diagramDocument.diagram;var next = old
        guard let i = next.page.nodes.firstIndex(where:{$0.id == id}),!next.page.isLocked(next.page.nodes[i]) else { throw DiagramError.invalid("Select an unlocked shape to edit ShapeSheet cells.") }
        try SheetCellEditing.set(key,value:value,formula:formula,unit:unit ?? next.page.nodes[i].formatting.sheet[key]?.unit ?? "",on:&next.page.nodes[i])
        let before = Set(DiagramCalculation.recalculate(old).issues),result = DiagramCalculation.recalculate(next,previous:old),added = Set(result.issues).subtracting(before)
        guard added.isEmpty else { throw DiagramError.invalid(added.sorted().prefix(4).joined(separator:"\n")) };diagramDocument.replaceInEditor(with:try result.diagram.validated(),action:"Edit ShapeSheet Cell")
    }
}
