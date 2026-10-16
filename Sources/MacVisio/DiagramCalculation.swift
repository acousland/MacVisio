import MacVisioInfrastructure
import Foundation

enum DiagramCalculation {
    struct Result {
        var diagram: Diagram
        var issues: [String]
        var geometryIssuesByPage: [UUID: [String]] = [:]
        var fieldIssuesByPage: [UUID: [String]] = [:]
        var work = CalculationWork()
    }

    static func recalculate(
        _ input: Diagram,
        previous: Diagram? = nil,
        previousIssues: [String] = [],
        previousGeometryIssuesByPage: [UUID: [String]]? = nil,
        previousFieldIssuesByPage: [UUID: [String]]? = nil,
        session: CalculationSession? = nil,
        changes: DocumentChangeSet? = nil,
        now: Date = Date()
    ) -> Result {
        guard let result = calculate(input, previous:previous, previousIssues:previousIssues,
            previousGeometryIssuesByPage:previousGeometryIssuesByPage, previousFieldIssuesByPage:previousFieldIssuesByPage,
            session:session, changes:changes, now:now, cancellation:nil) else {
            preconditionFailure("A noncancellable calculation cannot be cancelled.")
        }
        return result
    }

    static func calculate(
        _ input: Diagram, previous: Diagram? = nil, previousIssues: [String] = [],
        previousGeometryIssuesByPage: [UUID: [String]]? = nil,
        previousFieldIssuesByPage: [UUID: [String]]? = nil,
        session: CalculationSession? = nil, changes: DocumentChangeSet? = nil,
        now: Date = Date(), cancellation: LifecycleJobCancellation?
    ) -> Result? {
        let span = PerformanceEvidence.begin(.calculation)
        defer { PerformanceEvidence.end(span) }
        var next = input, issues = Set<String>()
        var previousPassInput: Diagram?
        var geometryIssuesByPage = previousGeometryIssuesByPage ?? [:]
        var fieldIssuesByPage = previousFieldIssuesByPage ?? [:]
        var work = CalculationWork()
        let session = session ?? CalculationSession()
        var passChanges = changes
        func adding(_ changedNodes: [UUID: Set<UUID>], to input: DocumentChangeSet?) -> DocumentChangeSet? {
            guard var result = input else { return nil }
            for (id, nodes) in changedNodes where !nodes.isEmpty {
                var page = result.pages[id] ?? PageChangeSet(pageID: id)
                page.changedNodeIDs.formUnion(nodes)
                result.pages[id] = page
            }
            return result
        }
        for pass in 0..<8 {
            if cancellation?.isCancelled == true { return nil }
            work.geometryPasses += 1
            let passInput = next
            let comparison = pass == 0
                ? (previousIssues.isEmpty || previousGeometryIssuesByPage != nil ? previous : nil)
                : previousPassInput
            let retainedIssues = pass == 0 ? previousGeometryIssuesByPage ?? [:] : geometryIssuesByPage
            let geometry = ShapeSheetEngine.recalculate(
                next, previous: pass == 0 ? previous : nil,
                skipUnchangedPagesComparedTo: comparison,
                retainedIssuesByPage: retainedIssues,
                incrementalNodes: true, session: session, changes: passChanges, cancellation: cancellation
            )
            if geometry.cancelled { return nil }
            geometryIssuesByPage = geometry.issuesByPage
            work.add(geometry.work)
            let fieldComparison = pass == 0
                ? (previousIssues.isEmpty || previousFieldIssuesByPage != nil ? previous : nil)
                : previousPassInput
            let fields = TextFieldEngine.recalculate(
                geometry.diagram, now: now, previous: fieldComparison,
                retainedIssuesByPage: pass == 0 ? previousFieldIssuesByPage ?? [:] : fieldIssuesByPage,
                session: session, changes: fieldComparison == nil ? nil : adding(geometry.changedNodeIDsByPage, to: passChanges), cancellation: cancellation
            )
            if fields.cancelled { return nil }
            fieldIssuesByPage = fields.issuesByPage
            work.add(fields.work)
            issues = Set(geometry.issues + fields.issues)
            if geometry.changedNodeIDsByPage.isEmpty && fields.changedNodeIDsByPage.isEmpty {
                return Result(diagram: fields.diagram, issues: issues.sorted(),
                              geometryIssuesByPage: geometryIssuesByPage,
                              fieldIssuesByPage: fieldIssuesByPage, work: work)
            }
            previousPassInput = passInput
            var produced = DocumentChangeSet()
            for changes in [geometry.changedNodeIDsByPage, fields.changedNodeIDsByPage] {
                for (id, nodes) in changes where !nodes.isEmpty {
                    var page = produced.pages[id] ?? PageChangeSet(pageID: id)
                    page.changedNodeIDs.formUnion(nodes)
                    produced.pages[id] = page
                }
            }
            passChanges = produced
            next = fields.diagram
        }
        let settlingIssue = "Text and geometry dependencies did not settle within eight calculation passes; inspect the formulas for a circular dependency."
        issues.insert(settlingIssue)
        if let previousPassInput {
            let priorPages = Dictionary(uniqueKeysWithValues: previousPassInput.pages.map { ($0.id, $0) })
            for page in next.pages where priorPages[page.id] != page {
                var pageIssues = Set(geometryIssuesByPage[page.id] ?? [])
                pageIssues.insert(settlingIssue)
                geometryIssuesByPage[page.id] = pageIssues.sorted()
            }
        }
        return Result(diagram: next, issues: issues.sorted(),
                      geometryIssuesByPage: geometryIssuesByPage,
                      fieldIssuesByPage: fieldIssuesByPage, work: work)
    }
}
