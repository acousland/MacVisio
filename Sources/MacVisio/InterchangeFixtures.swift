import Foundation

/// Synthetic, public-content-only inputs for testing with an independent Visio installation.
/// Expected values come from the authored VSDX XML, never MacVisio's private model on reopen.
enum InterchangeFixtures {
    static func generate(in directory: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue, try manager.contentsOfDirectory(atPath: directory.path).isEmpty else {
                throw DiagramError.invalid("Interchange fixtures require a new or empty output directory.")
            }
        } else { try manager.createDirectory(at: directory, withIntermediateDirectories: true) }

        let cases = DiagramTemplate.allCases.map { ($0.rawValue, $0.makeDiagram()) }
            + [("background-pages", PageExample.make()), ("public-semantics", semanticExample())]
        var fixtures: [[String: Any]] = []
        for (name, raw) in cases {
            let model = try raw.validated()
            let modern = directory.appendingPathComponent(name + ".vsdx")
            try VisioFormat.write(model, to: modern)
            var parts = try VisioPackage.read(modern)
            parts.removeValue(forKey: "macvisio/document.json")
            // Remove the corresponding relationship as well; do not leave a dangling OPC target.
            let relations = try VisioXML.document(parts["_rels/.rels"]!)
            for relation in relations.rootElement()?.elementsLocal("Relationship") ?? [] {
                if relation.attr("Type") == "urn:macvisio:relationships:diagram" { relation.detach() }
            }
            parts["_rels/.rels"] = relations.xmlData(options: .nodePreserveAll)
            try VisioPackage.write(parts, to: modern)
            let expected = try expectedPages(parts)
            for ext in ["vsdx", "vsd"] {
                let file = directory.appendingPathComponent(name + "." + ext)
                if ext == "vsd" { try VSDBinaryFormat.encoded(model, includeMetadata: false).write(to: file, options: .atomic) }
                let bytes = try Data(contentsOf: file)
                // Binary serialization currently carries saved graphics rather than all public semantics.
                let pages: [[String: Any]] = ext == "vsdx" ? expected : expected.map { page in
                    var page = page
                    page["connects"] = nil
                    page["shapes"] = (page["shapes"] as! [[String: Any]]).map { shape in
                        ["id": shape["id"]!, "parentID": shape["parentID"]!, "text": shape["text"]!]
                    }
                    return page
                }
                fixtures.append(["file": file.lastPathComponent, "case": name, "format": ext,
                    "sha256": VisioFormat.hash(bytes), "bytes": bytes.count,
                    "expected": ["pages": pages], "containsNativeMetadata": false])
            }
        }
        let manifest: [String: Any] = ["schemaVersion": 1, "syntheticOnly": true,
            "scope": "Authored public cached content. Windows execution, rendered fidelity, and complete behavior must be assessed separately.",
            "fixtures": fixtures]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private static func expectedPages(_ parts: [String: Data]) throws -> [[String: Any]] {
        let index = try VisioXML.document(parts["visio/pages/pages.xml"]!)
        let rels = try VisioXML.document(parts["visio/pages/_rels/pages.xml.rels"]!)
        let targets = Dictionary(uniqueKeysWithValues: (rels.rootElement()?.elementsLocal("Relationship") ?? []).map {
            ($0.attr("Id")!, $0.attr("Target")!)
        })
        return try (index.rootElement()?.elementsLocal("Page") ?? []).enumerated().map { offset, page in
            let relation = page.firstLocal("Rel")?.attr("r:id") ?? ""
            guard let target = targets[relation], let content = parts["visio/pages/" + target] else {
                throw DiagramError.invalid("A generated fixture has a missing page relationship.")
            }
            let root = try VisioXML.document(content)
            var shapes: [[String: Any]] = []
            func collect(_ container: XMLElement?, parent: String?) {
                for shape in container?.elementsLocal("Shape") ?? [] {
                    var cells: [String: Double] = [:]
                    for name in ["PinX", "PinY", "Width", "Height", "LocPinX", "LocPinY", "Angle", "FlipX", "FlipY"] {
                        if let value = VisioXML.value(shape, name).flatMap(Double.init) { cells[name] = value }
                    }
                    shapes.append(["id": shape.attr("ID")!, "parentID": parent as Any? ?? NSNull(),
                        "text": shape.firstLocal("Text")?.stringValue ?? "", "cells": cells])
                    collect(shape.firstLocal("Shapes"), parent: shape.attr("ID"))
                }
            }
            collect(root.rootElement()?.firstLocal("Shapes"), parent: nil)
            // Glue as authored; an independent Visio must report the same connections after opening.
            let connects: [[String: String]] = (root.rootElement()?.firstLocal("Connects")?.elementsLocal("Connect") ?? []).map {
                ["fromShape": $0.attr("FromSheet") ?? "", "fromCell": $0.attr("FromCell") ?? "",
                 "toShape": $0.attr("ToSheet") ?? "", "toCell": $0.attr("ToCell") ?? ""]
            }
            return ["index": offset + 1, "name": page.attr("Name") ?? "", "background": page.attr("Background") == "1",
                "width": VisioXML.number(page.firstLocal("PageSheet"), "PageWidth"),
                "height": VisioXML.number(page.firstLocal("PageSheet"), "PageHeight"), "shapes": shapes, "connects": connects]
        }
    }

    private static func semanticExample() -> Diagram {
        var diagram = Diagram(); diagram.title = "Synthetic public semantics"
        diagram.page.name = "Groups, ports and Unicode"; diagram.page.width = 900; diagram.page.height = 600
        diagram.page.layers = [DiagramLayer(name: "Services"), DiagramLayer(name: "Connections")]
        var group = DiagramNode(x: 60, y: 70, text: ""); group.width = 350; group.height = 250
        group.formatting.isGroup = true; group.fill = "#F3F6FD"
        var first = DiagramNode(x: 100, y: 140, text: "Café 東京 🙂\nSecond line")
        first.parentID = group.id; first.layer = "Services"; first.formatting.fontName = "Arial"
        first.formatting.data = [ShapeDataProperty(key: "Owner", label: "Owner", value: "Architecture")]
        first.formatting.connectionPoints = [ShapeConnectionPoint(index: 0, name: "Out", x: ShapeSheetCell(value: String(first.width / 72)), y: ShapeSheetCell(value: String(first.height / 144)))]
        var second = DiagramNode(kind: .roundedRectangle, x: 560, y: 160, text: "Target")
        second.formatting.connectionPoints = [ShapeConnectionPoint(index: 0, name: "In", x: ShapeSheetCell(value: "0"), y: ShapeSheetCell(value: String(second.height / 144)))]
        diagram.page.nodes = [group, first, second]
        var edge = DiagramEdge(source: first.id, target: second.id, label: "Named ports")
        edge.layer = "Connections"; edge.sourcePort = first.formatting.connectionPoints[0].id; edge.targetPort = second.formatting.connectionPoints[0].id
        diagram.page.edges = [edge]
        var scaled = DiagramPage(name: "Scale 1 to 50", width: 45000, height: 30000)
        scaled.drawingScale = DrawingScale(page: 1, drawing: 50, type: 3)
        var large = DiagramNode(x: 5000, y: 5000, text: "Measured drawing")
        large.width = 10000; large.height = 4000; large.formatting.fontName = "Arial"; scaled.nodes = [large]
        diagram.pages.append(scaled)
        return diagram
    }
}
