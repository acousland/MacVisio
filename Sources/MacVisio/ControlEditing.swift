import CoreGraphics
import Foundation

enum ControlEditing {
    static func expression(_ e: ShapeSheet.Expression) -> String {
        switch e {
        case .number(let n), .measure(let n, _): return CompositeGeometry.number(n)
        case .string(let s): return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        case .reference(let s): return s
        case .omitted: return ""
        case .unary(let op, let e): return "(" + op + expression(e) + ")"
        case .binary(let op, let a, let b): return "(" + expression(a) + op + expression(b) + ")"
        case .call(let name, let args): return name + "(" + args.map(expression).joined(separator: ",") + ")"
        }
    }
    /// Frozen at gesture start. Values are never shared with a different input.
    struct Baseline {
        let input: Diagram
        let issues: Set<String>
        let geometryIssuesByPage: [UUID: [String]]
        let session: CalculationSession
        let work: CalculationWork
        let inputIdentity: LifecycleJobInput?
    }
    static func prepare(_ input: Diagram) -> Baseline {
        let session = CalculationSession()
        let result = ShapeSheetEngine.recalculate(input, incrementalNodes: true, session: session)
        return Baseline(
            input: input, issues: Set(result.issues),
            geometryIssuesByPage: result.issuesByPage, session: session, work: result.work, inputIdentity: nil
        )
    }
    /// A committed document already owns its diagnostic baseline and retained
    /// index. Fork runtime state so previews cannot pollute committed hosts.
    static func prepare(
        _ input: Diagram, geometryIssuesByPage: [UUID: [String]], session: CalculationSession,
        inputIdentity: LifecycleJobInput? = nil
    ) -> Baseline {
        Baseline(
            input: input, issues: Set(geometryIssuesByPage.values.flatMap { $0 }),
            geometryIssuesByPage: geometryIssuesByPage, session: session.fork(), work: CalculationWork(),
            inputIdentity: inputIdentity)
    }
    static func moved(
        _ input: Diagram, node id: UUID, control name: String, to world: CGPoint,
        baseline prepared: Baseline? = nil
    ) throws -> Diagram {
        try preview(input, node: id, control: name, to: world, baseline: prepared).diagram.validated()
    }
    static func moved(
        baseline: Baseline, node id: UUID, control name: String, to world: CGPoint,
        cancellation: LifecycleJobCancellation? = nil
    ) throws -> Diagram {
        try preview(baseline: baseline, node: id, control: name, to: world, cancellation: cancellation)
            .diagram
    }
    struct Preview {
        var diagram: Diagram
        var work: CalculationWork
    }
    /// Compatibility adapter: validates a separately supplied baseline by full
    /// value comparison. Gesture callers use the baseline-only overload below.
    static func preview(
        _ input: Diagram, node id: UUID, control name: String, to world: CGPoint,
        baseline prepared: Baseline? = nil
    ) throws -> Preview {
        let baseline = prepared.flatMap { $0.input == input ? $0 : nil } ?? prepare(input)
        var result = try preview(baseline: baseline, node: id, control: name, to: world)
        if prepared != nil {
            result.work.inputComparisonNodes += input.pages.reduce(0) { $0 + $1.nodes.count }
        }
        return result
    }
    static func preview(
        baseline: Baseline, node id: UUID, control name: String, to world: CGPoint,
        cancellation: LifecycleJobCancellation? = nil
    ) throws -> Preview {
        try cancellation?.check()
        let evidence = PerformanceEvidence.begin(.calculation)
        defer { PerformanceEvidence.end(evidence) }
        // A reusable baseline remains a frozen semantic input. Each solve owns
        // its host updates, including SETATREFEVAL reads of redirected targets.
        let session = baseline.session.fork()
        let input = baseline.input
        var next = input
        var writeWork = CalculationWork()
        let indexedBefore = session.indexedNodes
        let comparedBefore = session.comparedSources
        let dependency = session.index(
            for: input.page, binding: input.visioArchive?.pages.first { $0.pageID == input.page.id },
            trustChanges: true)
        writeWork.dependencyNodesIndexed += session.indexedNodes - indexedBefore
        writeWork.dependencySourcesCompared += session.comparedSources - comparedBefore
        guard let index = dependency.nodeIndices[id], !next.page.isLocked(next.page.nodes[index]),
            let control = next.page.nodes[index].formatting.controls.first(where: { $0.name == name }),
            control.visible
        else {
            return Preview(diagram: input, work: writeWork)
        }
        let preparedBefore = session.preparedHostNodes
        var controlNodes = session.nodes(for: input.page, trustChanges: true)
        writeWork.hostNodesPrepared += session.preparedHostNodes - preparedBefore
        var writtenNodeIDs = Set<UUID>()
        let node = next.page.nodes[index]
        let p = DiagramCoordinates.local(world, in: node)
        let values = [
            "X": (p.x + node.sheetOrigin.x) / 72, "Y": (node.height - p.y + node.sheetOrigin.y) / 72,
        ]
        guard values.values.allSatisfy({ $0.isFinite && abs($0) < 100000 }) else {
            throw DiagramError.invalid("The control position is outside the supported range.")
        }
        let colorPalette = ShapeSheetColorPalette(documentArchive: next.visioArchive)
        func target(_ reference: String, from i: Int) throws -> (Int, String) {
            if let bang = reference.firstIndex(of: "!") {
                let sheet = String(reference[..<bang])
                let key = String(reference[reference.index(after: bang)...])
                guard sheet.uppercased().hasPrefix("SHEET."),
                    let target = dependency.identifiers[String(sheet.dropFirst(6))],
                    let other = dependency.nodeIndices[target]
                else { throw DiagramError.invalid("Unknown control target: \(reference)") }
                return (other, key)
            }
            return (i, reference)
        }
        func read(_ i: Int, _ key: String, _ depth: Int = 0) throws -> Double {
            let context = ShapeSheetContext(
                page: next.page, binding: next.visioArchive?.pages.first { $0.pageID == next.page.id },
                colorPalette: colorPalette, nodesByID: controlNodes, identifiers: dependency.identifiers,
                cancellation: cancellation)
            defer { writeWork.add(context.work) }
            return try context.number(next.page.nodes[i].id, key)
        }
        func evaluate(_ expression: ShapeSheet.Expression, _ i: Int) throws -> Double {
            let context = ShapeSheetContext(
                page: next.page, binding: next.visioArchive?.pages.first { $0.pageID == next.page.id },
                colorPalette: colorPalette, nodesByID: controlNodes, identifiers: dependency.identifiers,
                cancellation: cancellation)
            defer { writeWork.add(context.work) }
            return try context.evaluate(expression, on: next.page.nodes[i].id).numeric()
        }
        func contains(_ e: ShapeSheet.Expression, _ name: String) -> Bool {
            switch e {
            case .call(let f, let args): return f.uppercased() == name || args.contains { contains($0, name) }
            case .unary(_, let e): return contains(e, name)
            case .binary(_, let a, let b): return contains(a, name) || contains(b, name)
            default: return false
            }
        }
        func replacement(_ e: ShapeSheet.Expression, _ value: Double, _ i: Int, _ preserveStore: Bool = false)
            throws -> ShapeSheet.Expression
        {
            switch e {
            case .call(let name, let args):
                if name.uppercased() == "SETATREFEXPR" {
                    return preserveStore ? .call(name, [.number(value)]) : .number(value)
                }
                let converted = try args.map { try replacement($0, value, i, preserveStore) }
                if name.uppercased() == "SETATREFEVAL", converted.count == 1 {
                    return .number(try evaluate(converted[0], i))
                }
                return .call(name, converted)
            case .unary(let op, let e): return .unary(op, try replacement(e, value, i, preserveStore))
            case .binary(let op, let a, let b):
                return .binary(
                    op, try replacement(a, value, i, preserveStore),
                    try replacement(b, value, i, preserveStore))
            default: return e
            }
        }
        var writing = Set<String>()
        func store(_ i: Int, _ key: String, _ cell: ShapeSheetCell) throws {
            defer {
                let node = next.page.nodes[i]
                controlNodes[node.id] = node
                writtenNodeIDs.insert(node.id)
                writeWork.hostNodesPrepared += 1
            }
            if ControlGeometry.cell(key, on: next.page.nodes[i]) != nil {
                try ControlGeometry.set(key, cell, on: &next.page.nodes[i])
            } else if GeometrySheet.cell(key, on: next.page.nodes[i]) != nil {
                try GeometrySheet.set(key, cell, on: &next.page.nodes[i])
            } else {
                let name =
                    next.page.nodes[i].formatting.sheet.keys.first {
                        $0.caseInsensitiveCompare(key) == .orderedSame
                    } ?? key
                guard
                    next.page.nodes[i].formatting.sheet[name] != nil
                        || ShapeSheetEngine.geometryKeys.contains(name)
                else { throw DiagramError.invalid("Unknown control update target: \(key)") }
                next.page.nodes[i].formatting.sheet[name] = cell
            }
        }
        func write(_ i: Int, _ key: String, _ value: Double, _ formula: String? = nil, _ depth: Int = 0)
            throws
        {
            try cancellation?.check()
            guard !next.page.isLocked(next.page.nodes[i]), depth <= 10,
                writing.insert("\(i)!" + key.lowercased()).inserted
            else { throw DiagramError.invalid("Locked or circular control update target.") }
            defer { writing.remove("\(i)!" + key.lowercased()) }
            let n = next.page.nodes[i]
            let old =
                ControlGeometry.cell(key, on: n) ?? GeometrySheet.cell(key, on: n) ?? n.formatting.sheet.first
            { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value ?? ShapeSheetCell(value: "")
            let ast =
                old.formula.isEmpty || ["Inh", "No Formula"].contains(old.formula)
                ? nil : try ShapeSheet.parse(old.formula)
            func redirect(_ e: ShapeSheet.Expression) throws {
                switch e {
                case .call(let name, let args):
                    if name.uppercased() == "SETATREF", (1...3).contains(args.count) {
                        let reference: String
                        switch args[0] {
                        case .reference(let r), .string(let r): reference = r
                        default: throw DiagramError.invalid("SETATREF requires a cell reference.")
                        }
                        let (j, k) = try target(reference, from: i)
                        if args.count >= 2 {
                            let assigned = try replacement(args[1], value, i)
                            let f = expression(assigned)
                            let number = try evaluate(assigned, i)
                            try write(j, k, number, f, depth + 1)
                        } else {
                            try write(j, k, value, nil, depth + 1)
                        }
                        return
                    }
                    if name.uppercased() == "IF", args.count == 3 {
                        let condition = try evaluate(args[0], i)
                        try redirect(condition != 0 ? args[1] : args[2])
                        return
                    }
                    if name.uppercased() == "IFERROR", args.count == 2 {
                        let active: ShapeSheet.Expression
                        do {
                            _ = try evaluate(args[0], i)
                            active = args[0]
                        } catch { active = args[1] }
                        try redirect(active)
                        return
                    }
                    for e in args { try redirect(e) }
                case .unary(_, let e): try redirect(e)
                case .binary(_, let a, let b):
                    try redirect(a)
                    try redirect(b)
                default: break
                }
            }
            if let ast, contains(ast, "SETATREF") {
                try redirect(ast)
                // Only stored input markers outside SETATREF's assignment expression
                // belong to this cell; assignment markers remain reusable templates.
                func updateMarkers(_ e: ShapeSheet.Expression) throws -> ShapeSheet.Expression {
                    switch e {
                    case .call(let f, _) where f.uppercased() == "SETATREF": return e
                    case .call(let f, _) where f.uppercased() == "SETATREFEXPR":
                        return .call(f, [.number(value)])
                    case .call(let f, let args) where f.uppercased() == "BOUND" && args.count >= 5:
                        return .call(f, [.number(value)] + Array(args.dropFirst()))
                    case .call(let f, let args): return .call(f, try args.map(updateMarkers))
                    case .unary(let op, let e): return .unary(op, try updateMarkers(e))
                    case .binary(let op, let a, let b):
                        return .binary(op, try updateMarkers(a), try updateMarkers(b))
                    default: return e
                    }
                }
                let updated = expression(try updateMarkers(ast))
                if (contains(ast, "SETATREFEXPR") || contains(ast, "BOUND")), updated != expression(ast) {
                    var cell = old
                    cell.formula = updated
                    try store(i, key, cell)
                }
                return
            }
            if let ast, contains(ast, "GUARD") {
                throw DiagramError.invalid("This control coordinate is guarded.")
            }
            let result: String
            if let ast, contains(ast, "BOUND") {
                let input: ShapeSheet.Expression
                if let (c, axis) = ControlGeometry.address(key, on: n), ["X", "Y"].contains(axis) {
                    let size = (axis == "X" ? n.sheetWidth : n.sheetHeight) / 72
                    let dimension = axis == "X" ? "Width" : "Height"
                    let behavior = n.formatting.controls[c].behavior(axis) % 5
                    let formula =
                        behavior == 0 && size != 0
                        ? dimension + "*" + CompositeGeometry.number(value / size)
                        : behavior == 3
                            ? dimension + "/2+" + CompositeGeometry.number(value - size / 2)
                            : behavior == 4
                                ? dimension + "+" + CompositeGeometry.number(value - size)
                                : CompositeGeometry.number(value)
                    input = try ShapeSheet.parse(formula)
                } else {
                    input = .number(value)
                }
                func boundInput(_ e: ShapeSheet.Expression) -> ShapeSheet.Expression {
                    switch e {
                    case .call(let f, let args) where f.uppercased() == "BOUND" && args.count >= 5:
                        return .call(f, [input] + Array(args.dropFirst()))
                    case .call(let f, let args): return .call(f, args.map(boundInput))
                    case .unary(let op, let e): return .unary(op, boundInput(e))
                    case .binary(let op, let a, let b): return .binary(op, boundInput(a), boundInput(b))
                    default: return e
                    }
                }
                result = expression(boundInput(ast))
            } else if let ast, contains(ast, "SETATREFEXPR") {
                result = expression(try replacement(ast, value, i, true))
            } else if let formula {
                result = formula
            } else if let (c, axis) = ControlGeometry.address(key, on: n), ["X", "Y"].contains(axis) {
                let size = (axis == "X" ? n.sheetWidth : n.sheetHeight) / 72
                let dimension = axis == "X" ? "Width" : "Height"
                let behavior = n.formatting.controls[c].behavior(axis) % 5
                result =
                    behavior == 0 && size != 0
                    ? dimension + "*" + CompositeGeometry.number(value / size)
                    : behavior == 3
                        ? dimension + "/2+" + CompositeGeometry.number(value - size / 2)
                        : behavior == 4 ? dimension + "+" + CompositeGeometry.number(value - size) : ""
            } else {
                result = ""
            }
            try store(
                i, key,
                ShapeSheetCell(value: CompositeGeometry.number(value), formula: result, unit: old.unit))
        }
        for axis in ["X", "Y"] where control.behavior(axis) % 5 != 1 {
            try write(index, "Controls." + name + "." + axis, values[axis]!)
        }
        var changes = DocumentChangeSet()
        changes.pages[input.page.id] = PageChangeSet(pageID: input.page.id, changedNodeIDs: writtenNodeIDs)
        let calculated = ShapeSheetEngine.recalculate(
            next, previous: input,
            skipUnchangedPagesComparedTo: input, retainedIssuesByPage: baseline.geometryIssuesByPage,
            incrementalNodes: true, session: session, changes: changes, cancellation: cancellation)
        if calculated.cancelled { throw LifecycleJobError.cancelled }
        try cancellation?.check()
        let added = Set(calculated.issues).subtracting(baseline.issues)
        guard added.isEmpty else {
            throw DiagramError.invalid(added.sorted().prefix(4).joined(separator: "\n"))
        }
        writeWork.add(calculated.work)
        // The frozen committed input already passed validation. Evaluator and
        // control writes bound the changed cells/geometry; the commit boundary
        // performs document validation once, rather than scanning every preview.
        return Preview(diagram: calculated.diagram, work: writeWork)
    }
}

extension EditorWindowController {
    func moveControl(_ name: String, on id: UUID, to point: CGPoint) throws {
        canvas.finishEditing(commit: true)
        diagramDocument.adjustControlInEditor(
            baseline: diagramDocument.prepareControlGesture(), node: id, control: name, to: point)
        if !diagramDocument.isCalculating, let error = diagramDocument.lastCalculationJobError { throw error }
    }
}
