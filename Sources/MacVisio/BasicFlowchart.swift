import AppKit

enum BasicFlowchart {
    static let targetPageKey = "MacVisio.TargetPageID"
    static func subprocess(at point: CGPoint) -> DiagramNode {
        var node = DiagramNode(x: point.x, y: point.y, text: "Subprocess")
        node.formatting.paths = [VectorPath(commands: [VectorCommand("M",0,0),VectorCommand("L",1,0),VectorCommand("L",1,1),VectorCommand("L",0,1),VectorCommand("Z")]),
            VectorPath(commands: [VectorCommand("M",0.1,0),VectorCommand("L",0.1,1),VectorCommand("M",0.9,0),VectorCommand("L",0.9,1)], fill: false)]
        return node
    }
    static func offPage(to target: DiagramPage, at point: CGPoint) -> DiagramNode {
        var node = DiagramNode(x: point.x, y: point.y, text: "To \(target.name)")
        node.width = 120
        node.formatting.paths = [VectorPath(commands: [VectorCommand("M",0,0),VectorCommand("L",1,0),VectorCommand("L",1,0.65),VectorCommand("L",0.5,1),VectorCommand("L",0,0.65),VectorCommand("Z")])]
        node.formatting.data = [ShapeDataProperty(key: targetPageKey, label: "Target page ID", value: target.id.uuidString)]
        node.formatting.hyperlinks = [ShapeHyperlink(address: "", subAddress: target.name, description: "Open page \(target.name)")]
        return node
    }
    static func targetID(for node: DiagramNode) -> UUID? {
        node.formatting.data.first { $0.key == targetPageKey }.flatMap { UUID(uuidString: $0.value) }
    }
    static func targetID(for node: DiagramNode, in diagram: Diagram) -> UUID? {
        if let id = targetID(for: node), diagram.pages.contains(where: { $0.id == id }) { return id }
        // A public-only reimport assigns fresh native UUIDs. The public Visio
        // hyperlink name remains usable only when it identifies exactly one page.
        let names = Set(node.formatting.hyperlinks.filter { $0.address.isEmpty }.map(\.subAddress))
        let targets = diagram.pages.filter { names.contains($0.name) }
        return targets.count == 1 ? targets[0].id : nil
    }
    static func isOffPage(_ node: DiagramNode) -> Bool { node.formatting.data.contains { $0.key == targetPageKey } }
    static func refreshLinkNames(in diagram: inout Diagram, previous: Diagram? = nil) {
        let baseline = previous ?? diagram
        let pages = Dictionary(diagram.pages.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for p in diagram.pages.indices {
            for n in diagram.pages[p].nodes.indices {
                guard isOffPage(diagram.pages[p].nodes[n]),
                      let id = targetID(for: diagram.pages[p].nodes[n], in: baseline), let name = pages[id] else { continue }
                if let dataIndex = diagram.pages[p].nodes[n].formatting.data.firstIndex(where: { $0.key == targetPageKey }) {
                    diagram.pages[p].nodes[n].formatting.data[dataIndex].value = id.uuidString
                }
                for h in diagram.pages[p].nodes[n].formatting.hyperlinks.indices
                where diagram.pages[p].nodes[n].formatting.hyperlinks[h].address.isEmpty {
                    diagram.pages[p].nodes[n].formatting.hyperlinks[h].subAddress = name
                }
            }
        }
    }
}

extension EditorWindowController {
    @objc func insertProcess(_ sender: Any?) { insertBasicShape(.rectangle) }
    @objc func insertDecision(_ sender: Any?) { insertBasicShape(.diamond) }
    @objc func insertTerminator(_ sender: Any?) { insertBasicShape(.roundedRectangle) }
    @objc func insertData(_ sender: Any?) { insertBasicShape(.parallelogram) }
    private func insertBasicShape(_ kind: ShapeKind) {
        diagramDocument.commitTextEditing(); canvas.finishPageInteraction()
        guard !diagramDocument.isCalculating else { root.showMessage("Wait for the current edit to finish."); return }
        insertShape(kind)
    }
    @objc func insertSubprocess(_ sender: Any?) { insertBasicFlowNode(BasicFlowchart.subprocess(at: visibleCenter())) }
    private func insertBasicFlowNode(_ input: DiagramNode) {
        diagramDocument.commitTextEditing(); canvas.finishPageInteraction()
        guard !diagramDocument.isCalculating else { root.showMessage("Wait for the current edit to finish."); return }
        var node = input, next = diagramDocument.diagram
        node.x = max(0, min(next.page.width-node.width, node.x-node.width/2))
        node.y = max(0, min(next.page.height-node.height, node.y-node.height/2))
        next.page.nodes.append(node)
        diagramDocument.replaceInEditor(with: next, action: "Insert \(node.text)")
        canvas.select([node.id])
    }
    @discardableResult func insertOffPageLink(to targetID: UUID) -> Bool {
        diagramDocument.commitTextEditing(); canvas.finishPageInteraction()
        guard let target = diagramDocument.diagram.pages.first(where: { $0.id == targetID }),
              target.id != diagramDocument.diagram.page.id, !diagramDocument.isCalculating else { return false }
        insertBasicFlowNode(BasicFlowchart.offPage(to: target, at: visibleCenter())); return true
    }
    @objc func chooseOffPageTarget(_ sender: Any?) {
        diagramDocument.commitTextEditing(); canvas.finishPageInteraction()
        let targets = diagramDocument.diagram.pages.filter { $0.id != diagramDocument.diagram.page.id }
        guard !targets.isEmpty else { root.showMessage("Add another page before inserting an off-page link."); return }
        let replacing = selection.count == 1 && BasicFlowchart.isOffPage(selection[0])
        let alert = NSAlert(); alert.messageText = replacing ? "Change Off-page Destination" : "Insert Off-page Link"
        alert.informativeText = "Choose the destination page. Follow Link opens it; the native link keeps its page identity when renamed."
        alert.addButton(withTitle: replacing ? "Change Destination" : "Insert Link"); alert.addButton(withTitle: "Cancel")
        let picker = NSPopUpButton(frame: CGRect(x:0,y:0,width:360,height:28))
        picker.addItems(withTitles: targets.map(\.name)); picker.setAccessibilityLabel("Destination page")
        alert.accessoryView = picker
        guard alert.runModal() == .alertFirstButtonReturn, targets.indices.contains(picker.indexOfSelectedItem) else { return }
        let target = targets[picker.indexOfSelectedItem]
        if replacing {
            modifySelection("Change Off-page Destination") { node in
                if let index = node.formatting.data.firstIndex(where: { $0.key == BasicFlowchart.targetPageKey }) {
                    node.formatting.data[index].value = target.id.uuidString
                }
                if let index = node.formatting.hyperlinks.firstIndex(where: { $0.address.isEmpty }) {
                    node.formatting.hyperlinks[index].subAddress = target.name
                } else {
                    node.formatting.hyperlinks.append(ShapeHyperlink(address: "", subAddress: target.name, description: "Open page \(target.name)"))
                }
            }
        } else { _ = insertOffPageLink(to: target.id) }
    }
}
