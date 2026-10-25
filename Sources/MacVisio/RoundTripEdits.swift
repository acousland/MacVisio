import AppKit

/// Developer command for the round-trip reference (M3, G2): applies scripted edits to a drawing through
/// the document model the editor uses, then saves it with the normal VSDX save path, so Visio can show
/// whether only the edited content changed. Shapes are addressed by their Visio IDs and pages by name.
enum RoundTripEdits {
    struct Operation: Decodable {
        let op: String
        let page: String?
        let shape: String?
        let to: String?
        let cell: String?
        let formula: String?
        let text: String?
        let name: String?
        let layer: String?
        let visible: Bool?
        let dx: Double?, dy: Double?, x: Double?, y: Double?, width: Double?, height: Double?
    }

    static func apply(input: URL, operations: URL, output: URL) throws {
        let document = MacVisioDocument()
        try document.read(from: input, ofType: MacVisioDocument.visioType)
        let edits = try JSONDecoder().decode([Operation].self, from: Data(contentsOf: operations))
        for edit in edits {
            var next = document.diagram
            try apply(edit, to: &next)
            document.replace(with: next, action: "Round-trip edit \(edit.op)")
            if let error = document.lastCalculationJobError { throw error }
        }
        try VisioFormat.write(document.diagram, to: output)
    }

    private static func pageIndex(_ diagram: Diagram, _ name: String?) throws -> Int {
        guard let name else { return diagram.pages.firstIndex { $0.id == diagram.activePageID } ?? 0 }
        guard let index = diagram.pages.firstIndex(where: { $0.name == name }) else { throw DiagramError.invalid("No page named \(name).") }
        return index
    }

    private static func objectID(_ diagram: Diagram, page: Int, shape: String?) throws -> UUID {
        guard let shape, let binding = diagram.visioArchive?.pages.first(where: { $0.pageID == diagram.pages[page].id }),
              let id = binding.nodeIDs.first(where: { $0.value == shape })?.key ?? binding.edgeIDs.first(where: { $0.value == shape })?.key else {
            throw DiagramError.invalid("No shape \(shape ?? "?") on page \(diagram.pages[page].name).")
        }
        return id
    }

    private static func apply(_ edit: Operation, to diagram: inout Diagram) throws {
        let p = try pageIndex(diagram, edit.page)
        switch edit.op {
        case "move", "resize", "text", "cell":
            let id = try objectID(diagram, page: p, shape: edit.shape)
            if let n = diagram.pages[p].nodes.firstIndex(where: { $0.id == id }) {
                var node = diagram.pages[p].nodes[n]
                switch edit.op {
                case "move": node.x += (edit.dx ?? 0) * 72; node.y -= (edit.dy ?? 0) * 72  // dy is up, as in Visio
                case "resize":
                    if let width = edit.width { node.x += (node.width - width * 72) / 2; node.width = width * 72 }
                    if let height = edit.height { node.y += (node.height - height * 72) / 2; node.height = height * 72 }
                case "text": node.text = edit.text ?? ""
                default: try setCell(edit, on: &node)
                }
                diagram.pages[p].nodes[n] = node
            } else if let e = diagram.pages[p].edges.firstIndex(where: { $0.id == id }) {
                guard edit.op == "text" else { throw DiagramError.invalid("Only text edits apply to connectors here.") }
                diagram.pages[p].edges[e].label = edit.text ?? ""
            }
        case "delete":
            let id = try objectID(diagram, page: p, shape: edit.shape)
            diagram.pages[p].nodes.removeAll { $0.id == id || $0.parentID == id }
            diagram.pages[p].edges.removeAll { $0.id == id || $0.source == id || $0.target == id }
        case "addShape":
            var node = DiagramNode(text: edit.text ?? "")
            node.width = (edit.width ?? 1) * 72; node.height = (edit.height ?? 0.75) * 72
            node.x = (edit.x ?? 1) * 72 - node.width / 2
            node.y = diagram.pages[p].height - (edit.y ?? 1) * 72 - node.height / 2
            diagram.pages[p].nodes.append(node)
        case "connect":
            let from = try objectID(diagram, page: p, shape: edit.shape), to = try objectID(diagram, page: p, shape: edit.to)
            var edge = DiagramEdge(source: from, target: to); edge.label = edit.text ?? ""
            diagram.pages[p].edges.append(edge)
        case "renamePage":
            diagram.pages[p].name = edit.name ?? diagram.pages[p].name
        case "addPage":
            var page = DiagramPage(); page.name = edit.name ?? "Page"
            page.width = diagram.pages[p].width; page.height = diagram.pages[p].height
            diagram.pages.append(page)
        case "layerVisible":
            guard let index = diagram.pages[p].layers?.firstIndex(where: { $0.name == edit.layer }) else { throw DiagramError.invalid("No layer \(edit.layer ?? "?").") }
            diagram.pages[p].layers?[index].visible = edit.visible ?? true
        default:
            throw DiagramError.invalid("Unknown round-trip edit \(edit.op).")
        }
    }

    private static func setCell(_ edit: Operation, on node: inout DiagramNode) throws {
        guard let cell = edit.cell, let formula = edit.formula else { throw DiagramError.invalid("A cell edit needs a cell and a formula.") }
        if cell.hasPrefix("Prop."), let index = node.formatting.data.firstIndex(where: { $0.key == String(cell.dropFirst(5)) }) {
            // Shape Data values are stored as their result; a quoted formula is a string value.
            let value = formula.hasPrefix("\"") && formula.hasSuffix("\"") ? String(formula.dropFirst().dropLast()) : formula
            node.formatting.data[index].value = value
            return
        }
        var current = node.formatting.sheet[cell] ?? ShapeSheetCell(value: "")
        current.formula = formula
        node.formatting.sheet[cell] = current
    }
}
