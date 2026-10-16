import Foundation
import MacVisioInfrastructure

enum CalculationExecutionPolicy: Equatable {
    case pureWorker
    case mainThreadTextMeasurement

    /// The only evaluator entry into AppKit is the explicit text measurement
    /// host. All branches are inspected; inactive IF branches are included.
    static func inspect(_ diagram: Diagram) -> CalculationExecutionPolicy {
        func measures(_ expression: ShapeSheet.Expression) -> Bool {
            switch expression {
            case .call(let name, let arguments):
                return ["TEXTWIDTH", "TEXTHEIGHT"].contains(name.uppercased())
                    || arguments.contains(where: measures)
            case .unary(_, let child): return measures(child)
            case .binary(_, let a, let b): return measures(a) || measures(b)
            case .number, .measure, .string, .reference, .omitted: return false
            }
        }
        for page in diagram.pages {
            let sources = CalculationDependencyIndex.sources(
                page: page, binding: diagram.visioArchive?.pages.first { $0.pageID == page.id })
            var formulas = sources.flatMap(\.formulas).compactMap {
                $0.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false).last.map(
                    String.init)
            }
            formulas += page.sheet?.values.map(\.formula) ?? []
            for formula in formulas {
                if let expression = try? ShapeSheet.parse(formula), measures(expression) {
                    return .mainThreadTextMeasurement
                }
            }
        }
        return .pureWorker
    }
}

/// Results carry the owner, exact committed snapshot identity and revision.
/// Publication must use accepted(ifCurrent:), after the execution owner's gate.
struct CalculationJobOutput {
    let input: LifecycleJobInput
    private let value: DiagramCalculation.Result
    init(input: LifecycleJobInput, value: DiagramCalculation.Result) {
        self.input = input
        self.value = value
    }
    func includingPreparationWork(_ work: CalculationWork) -> CalculationJobOutput {
        var result = value
        result.work.add(work)
        return CalculationJobOutput(input: input, value: result)
    }
    func accepted(ifCurrent current: LifecycleJobInput) throws -> DiagramCalculation.Result {
        guard input == current else { throw LifecycleJobError.staleInput }
        return value
    }
}

enum CalculationJobs {
    /// Numeric/string/geometry evaluation stays on an owned worker. Explicit
    /// text measurement uses individual ShapeTextMeasurementService main-queue
    /// records. A fresh/forked session belongs exclusively to this request.
    /// The owner schedules this API through LifecycleJobService and gates its
    /// completion; this function does not mutate a live NSDocument or undo stack.
    static func evaluate(
        _ diagram: Diagram, input: LifecycleJobInput,
        previous: Diagram? = nil, previousIssues: [String] = [],
        previousGeometryIssuesByPage: [UUID: [String]]? = nil,
        previousFieldIssuesByPage: [UUID: [String]]? = nil,
        previousGeometryDiagnosticsByPage: [UUID: [DocumentDiagnostic]] = [:],
        previousFieldDiagnosticsByPage: [UUID: [DocumentDiagnostic]] = [:],
        refreshDiagnostics: Bool = false,
        session: CalculationSession? = nil, changes: DocumentChangeSet? = nil,
        now: Date = Date(), cancellation: LifecycleJobCancellation
    ) throws -> CalculationJobOutput {
        try cancellation.check()
        guard
            let result = DiagramCalculation.calculate(
                diagram, previous: previous, previousIssues: previousIssues,
                previousGeometryIssuesByPage: previousGeometryIssuesByPage,
                previousFieldIssuesByPage: previousFieldIssuesByPage,
                previousGeometryDiagnosticsByPage: previousGeometryDiagnosticsByPage,
                previousFieldDiagnosticsByPage: previousFieldDiagnosticsByPage,
                refreshDiagnostics: refreshDiagnostics,
                session: session, changes: changes, now: now, cancellation: cancellation)
        else {
            throw LifecycleJobError.cancelled
        }
        try cancellation.check()
        return CalculationJobOutput(input: input, value: result)
    }
}
