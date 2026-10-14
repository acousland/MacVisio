import Foundation

enum DiagramCalculation {
    struct Result { var diagram:Diagram;var issues:[String] }
    static func recalculate(_ input:Diagram,previous:Diagram? = nil) -> Result {
        var next = input,issues = Set<String>()
        for pass in 0..<8 {
            let geometry = ShapeSheetEngine.recalculate(next,previous:pass == 0 ? previous : nil),fields = TextFieldEngine.recalculate(geometry.diagram)
            issues = Set(geometry.issues+fields.issues)
            if fields.diagram == next { return Result(diagram:fields.diagram,issues:issues.sorted()) }
            next = fields.diagram
        }
        issues.insert("Text and geometry dependencies did not settle within eight calculation passes; inspect the formulas for a circular dependency.")
        return Result(diagram:next,issues:issues.sorted())
    }
}
