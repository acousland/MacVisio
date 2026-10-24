import Foundation
import JavaScriptCore

/// WP-04-T02 feasibility prototype: hosts a small Visio-shaped object model (Application.ActivePage,
/// Page.DrawRectangle, Page.Shapes.Count, Shape.ID, Shape.Text) in JavaScriptCore. It answers whether
/// translated automation can reproduce Visio's outcome; it is not a product feature, runs only from
/// the developer command, and cannot run unmodified VBA.
enum AutomationPrototype {
    struct Outcome {
        var diagram: Diagram
        var result: Any?
        var error: String?
    }

    /// Runs `script` against a copy of `diagram`'s active page. Coordinates follow Visio: inches, origin
    /// at the page's bottom-left.
    static func run(_ script: String, on diagram: Diagram) -> Outcome {
        final class State { var diagram: Diagram; init(_ d: Diagram) { diagram = d } }
        let state = State(diagram)
        guard let context = JSContext() else { return Outcome(diagram: diagram, result: nil, error: "JavaScriptCore unavailable") }
        var failure: String?
        context.exceptionHandler = { _, value in failure = value?.toString() }

        func shapeObject(_ id: UUID, index: Int) -> JSValue {
            let shape = JSValue(newObjectIn: context)!
            let getText: @convention(block) () -> String = { state.diagram.page.nodes.first { $0.id == id }?.text ?? "" }
            let setText: @convention(block) (String) -> Void = { text in
                if let i = state.diagram.page.nodes.firstIndex(where: { $0.id == id }) { state.diagram.page.nodes[i].text = text }
            }
            shape.defineProperty("Text", descriptor: ["get": getText, "set": setText, "enumerable": true])
            shape.setValue(index, forProperty: "ID")
            return shape
        }
        let page = JSValue(newObjectIn: context)!
        let drawRectangle: @convention(block) (Double, Double, Double, Double) -> JSValue = { x1, y1, x2, y2 in
            let height = state.diagram.page.height
            var node = DiagramNode(text: "")
            node.kind = .rectangle
            node.x = min(x1, x2) * 72; node.width = abs(x2 - x1) * 72
            node.height = abs(y2 - y1) * 72; node.y = height - max(y1, y2) * 72
            state.diagram.page.nodes.append(node)
            return shapeObject(node.id, index: state.diagram.page.nodes.count)
        }
        page.setObject(drawRectangle, forKeyedSubscript: "DrawRectangle" as NSString)
        let shapes = JSValue(newObjectIn: context)!
        let count: @convention(block) () -> Int = { state.diagram.page.nodes.count }
        shapes.defineProperty("Count", descriptor: ["get": count, "enumerable": true])
        page.setValue(shapes, forProperty: "Shapes")
        let application = JSValue(newObjectIn: context)!
        application.setValue(page, forProperty: "ActivePage")
        context.setObject(application, forKeyedSubscript: "Application" as NSString)
        let value = context.evaluateScript(script)
        return Outcome(diagram: state.diagram, result: failure == nil ? value?.toObject() : nil, error: failure)
    }

    /// Shapes on the active page in Visio terms (inches, bottom-left origin) for comparison with a run of
    /// the same steps through Visio's own COM object model.
    static func visioShapes(_ diagram: Diagram) -> [[String: Any]] {
        diagram.page.nodes.enumerated().map { index, node in
            ["id": index + 1, "text": node.text, "pinX": (node.x + node.width / 2) / 72,
             "pinY": (diagram.page.height - node.y - node.height / 2) / 72, "width": node.width / 72, "height": node.height / 72]
        }
    }
}
