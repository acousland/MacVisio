import AppKit
import MacVisioInfrastructure

extension EditorWindowController {
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
