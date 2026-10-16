import AppKit

struct DrawingOperationProposal {
    let baselineStateID: UUID
    let snapshot: Diagram
    let changedShapes: Int
    let skippedProtectedGroups: Int
    static func grid(_ input: Diagram, stateID: UUID, spacing: Double = 40) throws -> Self {
        guard spacing.isFinite, spacing > 0, input.pages.reduce(0, { $0+$1.nodes.count }) <= 10_000 else {
            throw DiagramError.invalid("Grid preview supports up to 10,000 shapes and a positive spacing.")
        }
        var result = input, changed = Set<UUID>(), skipped = 0
        for p in result.pages.indices {
            for id in input.pages[p].nodes.filter({ $0.parentID == nil }).map(\.id) {
                guard let i = result.pages[p].nodes.firstIndex(where: { $0.id == id }) else { continue }
                let oldPage = result.pages[p], old = oldPage.nodes[i]
                var moved = old
                moved.x = max(0, min(oldPage.width-old.width, (old.x/spacing).rounded()*spacing))
                moved.y = max(0, min(oldPage.height-old.height, (old.y/spacing).rounded()*spacing))
                if old.rect == moved.rect { continue }
                var candidate = oldPage; candidate.nodes[i] = moved
                DiagramOperations.transformChildren(in: &candidate, from: old, to: moved)
                let oldByID = Dictionary(oldPage.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let protected = candidate.nodes.contains { node in
                    oldByID[node.id].map { NativeEditProtection.blockReason(changing: $0, to: node, in: oldPage) != nil } ?? true
                } || oldPage.edges.contains { $0.parentID == old.id && oldPage.isLocked($0) }
                if protected { skipped += 1; continue }
                for node in candidate.nodes where oldByID[node.id] != node { changed.insert(node.id) }
                result.pages[p] = candidate
            }
        }
        return Self(baselineStateID: stateID, snapshot: result, changedShapes: changed.count, skippedProtectedGroups: skipped)
    }
}

extension EditorWindowController {
    @discardableResult func applyDrawingProposal(_ proposal: DrawingOperationProposal) -> Bool {
        diagramDocument.commitTextEditing(); canvas.finishPageInteraction()
        guard diagramDocument.stateID == proposal.baselineStateID, !diagramDocument.isCalculating else { return false }
        diagramDocument.replaceInEditor(with: proposal.snapshot, action: "Align Drawing to Grid")
        return true
    }
    @objc func previewDrawingGrid(_ sender: Any?) {
        diagramDocument.commitTextEditing(); canvas.finishPageInteraction()
        guard !diagramDocument.isCalculating else { root.showMessage("Wait for the current edit before previewing the drawing."); return }
        do {
            let baseline = diagramDocument.diagram
            let proposal = try DrawingOperationProposal.grid(baseline, stateID: diagramDocument.stateID)
            let alert = NSAlert(); alert.messageText = "Preview Align Drawing to Grid"
            alert.informativeText = "All \(baseline.pages.count) pages: \(proposal.changedShapes) shapes change; \(proposal.skippedProtectedGroups) protected groups/shapes stay unchanged. Positions align to a 40-point drawing grid. Formulas and routing update on Apply."
            alert.addButton(withTitle: "Apply"); alert.addButton(withTitle: "Cancel")
            let preview = DrawingOperationPreviewView(before: baseline, after: proposal.snapshot)
            alert.accessoryView = preview
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            if !applyDrawingProposal(proposal) { root.showMessage("The drawing changed. Open a new preview before applying.") }
        } catch { presentError(error) }
    }
    @objc func toggleShapeLibrary(_ sender: Any?) {
        root.libraryRequestedInNarrowWindow.toggle(); root.needsLayout = true
        root.layoutSubtreeIfNeeded()
    }
}

private final class DrawingOperationPreviewView: FlippedView {
    private let before: Diagram
    private let after: Diagram
    private var prepared: RetainedRenderScene!
    private let mode = NSSegmentedControl(labels: ["Before", "Preview"], trackingMode: .selectOne, target: nil, action: nil)
    private let pages = NSPopUpButton()
    init(before: Diagram, after: Diagram) {
        self.before = before; self.after = after
        super.init(frame: CGRect(x:0,y:0,width:480,height:340))
        mode.frame = CGRect(x:0,y:0,width:220,height:28); mode.selectedSegment = 1
        mode.target = self; mode.action = #selector(updatePreview(_:)); mode.setAccessibilityLabel("Before or proposed drawing")
        pages.frame = CGRect(x:230,y:0,width:250,height:28); pages.addItems(withTitles: before.pages.map(\.name))
        pages.selectItem(at: before.pages.firstIndex(where: { $0.id == before.activePageID }) ?? 0)
        pages.target = self; pages.action = #selector(updatePreview(_:)); pages.setAccessibilityLabel("Preview page")
        addSubview(mode); addSubview(pages); updatePreview(nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func updatePreview(_ sender: Any?) {
        let input = mode.selectedSegment == 0 ? before : after
        guard input.pages.indices.contains(pages.indexOfSelectedItem) else { return }
        prepared = RetainedRenderScene(scene: input.scene(for: input.pages[pages.indexOfSelectedItem].id))
        needsDisplay = true
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let prepared else { return }
        let page = prepared.scene.page
        let scale = min(460/page.paperWidth, 295/page.paperHeight)
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform(); transform.translateX(by:10,yBy:35); transform.scale(by:scale); transform.concat()
        DiagramDrawing.drawPage(prepared)
        NSGraphicsContext.restoreGraphicsState()
    }
}
