import AppKit
import MacVisioInfrastructure

extension EditorWindowController {
    var intersectUnavailableReason: String? { setOperationUnavailableReason(title: "Intersect") }
    var subtractUnavailableReason: String? { setOperationUnavailableReason(title: "Subtract") }

    private func setOperationUnavailableReason(title: String) -> String? {
        guard lifecycleJobs.isActive else { return "The drawing window is closed." }
        if diagramDocument.isCalculating { return "Wait for calculation to finish or cancel it." }
        if (window?.firstResponder as? NSTextView)?.hasMarkedText() == true || hasMarkedBooleanOperandText { return "Finish text composition before \(title)." }
        if canvas.selectedEdge != nil { return "Select two filled shapes without a connector for \(title)." }
        return BooleanGeometry.unavailableReason(canvas.selectedNodes, in: diagramDocument.diagram, operation: .intersect)?.replacingOccurrences(of: "Intersect", with: title)
    }

    @objc func intersectSelection(_ sender: Any?) {
        guard lifecycleJobs.isActive else { return }
        if (window?.firstResponder as? NSTextView)?.hasMarkedText() == true || hasMarkedBooleanOperandText { root.showMessage("Finish text composition before Intersect."); return }
        canvas.finishEditing(commit: true)
        if let reason = intersectUnavailableReason { root.showMessage(reason); return }
        let drawing = diagramDocument
        let input = LifecycleJobInput(ownerID: drawing.lifecycleOwnerID, snapshotID: drawing.stateID, revision: drawing.revision)
        _ = submitSetOperation(.intersect, selected: canvas.selectedNodes, expected: input, pageID: drawing.diagram.activePageID)
    }

    @objc func subtractSelection(_ sender: Any?) {
        guard lifecycleJobs.isActive else { return }
        if (window?.firstResponder as? NSTextView)?.hasMarkedText() == true || hasMarkedBooleanOperandText { root.showMessage("Finish text composition before Subtract."); return }
        canvas.finishEditing(commit: true)
        if let reason = subtractUnavailableReason { root.showMessage(reason); return }
        _ = subtractionChooserController.presentCurrentSelection()
    }

    /// The chooser owns no alternate edit path. This immutable proposal enters
    /// the same owned calculation/publication/undo transaction as native Union.
    @discardableResult func submitSetOperation(_ operation: BooleanGeometry.Operation, selected: Set<UUID>,
                                              expected: LifecycleJobInput, pageID: UUID) -> Bool {
        guard lifecycleJobs.isActive else { return false }
        let drawing = diagramDocument
        guard operation != .union, drawing.lifecycleOwnerID == expected.ownerID,
              drawing.stateID == expected.snapshotID, drawing.revision == expected.revision,
              drawing.diagram.activePageID == pageID, canvas.selectedNodes == selected, canvas.selectedEdge == nil else {
            root.showMessage("The drawing or selection changed. Review the current operands before applying."); return false
        }
        if let reason = setOperationUnavailableReason(title: operation.title) { root.showMessage(reason); return false }
        if let reason = BooleanGeometry.unavailableReason(selected, in: drawing.diagram, operation: operation) { root.showMessage(reason); return false }
        let snapshot = drawing.diagram, resultID = UUID()
        drawing.replaceInEditor(with: snapshot, action: "\(operation.title) Shapes", forceAsync: true, presentFailureAlert: false, preparation: { cancellation in
            let result: Diagram
            switch operation {
            case .intersect: result = try BooleanGeometry.intersect(selected, in: snapshot, resultID: resultID, cancellation: cancellation)
            case .subtract(let baseID): result = try BooleanGeometry.subtract(selected, in: snapshot, baseID: baseID, resultID: resultID, cancellation: cancellation)
            case .union: throw DiagramError.invalid("Use the Union command for Union.")
            }
            return (result, CalculationWork())
        })
        guard drawing.isCalculating else {
            if let error = drawing.lastCalculationJobError { root.showMessage(error.localizedDescription) }
            return false
        }
        canvas.select([resultID]); return true
    }

    var unionUnavailableReason: String? {
        guard lifecycleJobs.isActive else { return "The drawing window is closed." }
        if diagramDocument.isCalculating { return "Wait for calculation to finish or cancel it." }
        if (window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return "Finish text composition before Union." }
        if canvas.selectedEdge != nil { return "Select filled shapes without a connector for Union." }
        return BooleanGeometry.unavailableReason(canvas.selectedNodes, in: diagramDocument.diagram)
    }

    @objc func unionSelection(_ sender: Any?) {
        guard lifecycleJobs.isActive else { return }
        if (window?.firstResponder as? NSTextView)?.hasMarkedText() == true { root.showMessage("Finish text composition before Union."); return }
        canvas.finishEditing(commit: true)
        guard !diagramDocument.isCalculating else { root.showMessage("Wait for calculation to finish or cancel it."); return }
        if let reason = unionUnavailableReason { root.showMessage(reason); return }
        let snapshot = diagramDocument.diagram, selected = canvas.selectedNodes, resultID = UUID()
        diagramDocument.replaceInEditor(with: snapshot, action: "Union Shapes", forceAsync: true, presentFailureAlert: false, preparation: { cancellation in
            let next = try BooleanGeometry.union(selected, in: snapshot, resultID: resultID, cancellation: cancellation)
            return (next, CalculationWork())
        })
        // The owned transaction restores the prior selection on cancellation,
        // failure or stale publication, and resolves this ID when it commits.
        if diagramDocument.isCalculating { canvas.select([resultID]) }
    }
}
