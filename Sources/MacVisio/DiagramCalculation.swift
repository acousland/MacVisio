import Foundation

enum DiagramCalculation {
    struct Result { var diagram:Diagram;var issues:[String];var geometryIssuesByPage:[UUID:[String]] = [:] }
    static func recalculate(_ input:Diagram,previous:Diagram? = nil,previousIssues:[String] = [],previousGeometryIssuesByPage:[UUID:[String]]? = nil) -> Result {
        let evidence = PerformanceEvidence.begin(.calculation);defer { PerformanceEvidence.end(evidence) }
        var next = input,issues = Set<String>()
        var previousPassInput:Diagram?
        var geometryIssuesByPage = previousGeometryIssuesByPage ?? [:]
        for pass in 0..<8 {
            let passInput = next
            let comparison = pass == 0 ? (previousIssues.isEmpty || previousGeometryIssuesByPage != nil ? previous : nil) : previousPassInput
            let retainedIssues = pass == 0 ? previousGeometryIssuesByPage ?? [:] : geometryIssuesByPage
            let geometry = ShapeSheetEngine.recalculate(next,previous:pass == 0 ? previous : nil,skipUnchangedPagesComparedTo:comparison,retainedIssuesByPage:retainedIssues)
            geometryIssuesByPage = geometry.issuesByPage
            let fields = TextFieldEngine.recalculate(geometry.diagram)
            issues = Set(geometry.issues+fields.issues)
            if fields.diagram == next { return Result(diagram:fields.diagram,issues:issues.sorted(),geometryIssuesByPage:geometryIssuesByPage) }
            previousPassInput = passInput
            next = fields.diagram
        }
        let settlingIssue = "Text and geometry dependencies did not settle within eight calculation passes; inspect the formulas for a circular dependency."
        issues.insert(settlingIssue)
        if let previousPassInput {
            let priorPages = Dictionary(uniqueKeysWithValues:previousPassInput.pages.map{($0.id,$0)})
            for page in next.pages where priorPages[page.id] != page {
                var pageIssues = Set(geometryIssuesByPage[page.id] ?? [])
                pageIssues.insert(settlingIssue)
                geometryIssuesByPage[page.id] = pageIssues.sorted()
            }
        }
        return Result(diagram:next,issues:issues.sorted(),geometryIssuesByPage:geometryIssuesByPage)
    }
}
