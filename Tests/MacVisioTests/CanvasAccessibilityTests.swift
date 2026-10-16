import AppKit
import XCTest
@testable import MacVisio

/// Prepared-scene semantics and synthetic native responder-chain evidence.
/// These checks do not substitute for real VoiceOver, IME or physical input.
final class CanvasAccessibilityTests: XCTestCase {
    func testComposedSceneVisibilityStableIdentityAndGraphRelations() throws {
        try onMain {
            var drawing = Diagram()
            var group = DiagramNode(text: "Order group"); group.formatting.isGroup = true
            var child = DiagramNode(text: "Approve"); child.parentID = group.id
            child.formatting.data = [ShapeDataProperty(key: "aLtTeXt", label: "Alternative text", value: "  Approval alternative  "),
                                     ShapeDataProperty(key: "Owner", label: "Owner", value: "Never infer this as the label")]
            var hidden = DiagramNode(text: "Hidden"); hidden.layer = "Hidden"
            let edge = DiagramEdge(source: group.id, target: child.id, label: "Yes")
            drawing.page.nodes = [group, child, hidden]
            drawing.page.edges = [edge]
            drawing.page.layers = [DiagramLayer(name: "Default"), DiagramLayer(name: "Hidden", visible: false)]
            // Deliberately reuse a UUID across pages. Provenance must stay scoped.
            var backgroundNode = DiagramNode(text: "Background notice"); backgroundNode.id = child.id
            var background = DiagramPage(name: "Backdrop", nodes: [backgroundNode]); background.isBackground = true
            drawing.page.backgroundPageID = background.id
            drawing.pages.append(background)
            try withEditor(drawing) { document, editor, _ in
                let graph = editor.canvas.accessibilityGraph
                let childKey = CanvasObjectKey(pageID: drawing.page.id, element: .node(child.id))
                let groupKey = CanvasObjectKey(pageID: drawing.page.id, element: .node(group.id))
                let edgeKey = CanvasObjectKey(pageID: drawing.page.id, element: .edge(edge.id))
                let backKey = CanvasObjectKey(pageID: background.id, element: .node(child.id))
                let childElement = graph.element(childKey)
                XCTAssertEqual(graph.elements().count, 4)
                XCTAssertFalse(graph.keys.contains(CanvasObjectKey(pageID: drawing.page.id, element: .node(hidden.id))))
                XCTAssertNotEqual(childElement.accessibilityIdentifier(), graph.element(backKey).accessibilityIdentifier())
                XCTAssertEqual(childElement.accessibilityLabel(), "Approval alternative, Process")
                XCTAssertTrue(graph.element(backKey).accessibilityLabel()?.contains("Backdrop") == true)
                XCTAssertFalse(graph.element(backKey).accessibilityPerformPress())
                XCTAssertEqual(graph.relations(edgeKey).map(\.key), [groupKey, childKey])
                XCTAssertTrue(graph.relations(childKey).map(\.key).contains(groupKey))
                XCTAssertTrue(graph.element(edgeKey).accessibilityLabel()?.contains("from Order group to Approval alternative") == true)
                var next = document.diagram
                next.page.nodes.swapAt(0, 1)
                document.replace(with: next, action: "Reorder")
                XCTAssertTrue(graph.element(childKey) === childElement)
                next = document.diagram
                next.page.nodes.removeAll { $0.id == child.id }
                next.page.edges = []
                document.replace(with: next, action: "Remove")
                XCTAssertFalse(childElement.accessibilityPerformPress(), "Retained stale AX objects cannot select or edit deleted targets.")
            }
        }
    }

    func testAccessibilityFramesUseLiveCanvasWindowScreenAndBackgroundTransforms() throws {
        try onMain {
            var drawing = Diagram()
            let node = DiagramNode(x: 220, y: 180, text: "Foreground")
            let backgroundNode = DiagramNode(x: 40, y: 60, text: "Background")
            var background = DiagramPage(name: "Background", width: 600, height: 400, nodes: [backgroundNode])
            background.isBackground = true
            drawing.page.nodes = [node]; drawing.page.backgroundPageID = background.id
            drawing.pages.append(background)
            try withEditor(drawing) { _, editor, window in
                let canvas = editor.canvas, graph = canvas.accessibilityGraph
                let key = CanvasObjectKey(pageID: background.id, element: .node(backgroundNode.id))
                let element = graph.element(key)
                canvas.setZoom(1.4)
                canvas.scroll(CGPoint(x: 90, y: 130))
                let bounds = try XCTUnwrap(graph.drawingBounds(key))
                let offset = canvas.renderScene.scene.offset(for: background)
                let local = CGRect(x: canvas.pageOrigin.x + (bounds.minX * background.paperScale + offset.x) * canvas.zoom,
                                   y: canvas.pageOrigin.y + (bounds.minY * background.paperScale + offset.y) * canvas.zoom,
                                   width: bounds.width * background.paperScale * canvas.zoom,
                                   height: bounds.height * background.paperScale * canvas.zoom)
                let expected = window.convertToScreen(canvas.convert(local, to: nil))
                XCTAssertEqual(element.accessibilityFrame(), expected)
                let old = element.accessibilityFrame()
                let oldWindowOrigin = window.frame.origin
                window.setFrameOrigin(CGPoint(x: window.frame.minX + 30, y: window.frame.minY + 20))
                // AppKit may constrain the requested move at a screen edge.
                XCTAssertEqual(element.accessibilityFrame().minX, old.minX + window.frame.minX - oldWindowOrigin.x, accuracy: 0.001)
                XCTAssertEqual(element.accessibilityFrame().minY, old.minY + window.frame.minY - oldWindowOrigin.y, accuracy: 0.001)
            }
        }
    }

    func testObjectTraversalAndTabCanLeaveCanvasThroughWindowResponderChain() throws {
        try onMain {
            var drawing = Diagram()
            drawing.page.nodes = [DiagramNode(text: "First"), DiagramNode(x: 350, text: "Second")]
            try withEditor(drawing) { _, editor, window in
                let canvas = editor.canvas
                // Editable fields remain eligible under the default system
                // keyboard-access policy; an empty-frame button does not.
                let before = NSTextField(frame: NSRect(x: 20, y: 20, width: 130, height: 24))
                let after = NSTextField(frame: NSRect(x: 170, y: 20, width: 130, height: 24))
                before.stringValue = "Before canvas"; after.stringValue = "After canvas"
                editor.root.addSubview(before); editor.root.addSubview(after)
                before.nextKeyView = canvas; canvas.nextKeyView = after
                window.makeFirstResponder(canvas)
                window.sendEvent(try key("\t", code: 48, flags: .option, window: window))
                XCTAssertEqual(canvas.selectedNodes, [drawing.page.nodes[0].id])
                XCTAssertEqual(canvas.keyboardFocusedObject?.element, .node(drawing.page.nodes[0].id))
                XCTAssertTrue(canvas.accessibilityGraph.element(try XCTUnwrap(canvas.keyboardFocusedObject)).isAccessibilityFocused())
                window.sendEvent(try key("\t", code: 48, flags: .option, window: window))
                XCTAssertEqual(canvas.selectedNodes, [drawing.page.nodes[1].id])
                window.sendEvent(try key("\t", code: 48, window: window))
                XCTAssertFalse(window.firstResponder === canvas)
                XCTAssertTrue(window.firstResponder === after.currentEditor())
                XCTAssertNil(canvas.keyboardFocusedObject)
                window.makeFirstResponder(canvas)
                _ = canvas.focusCanvasObject(CanvasObjectKey(pageID: drawing.page.id, element: .node(drawing.page.nodes[1].id)))
                window.sendEvent(try key("\t", code: 48, flags: .option, window: window))
                XCTAssertFalse(window.firstResponder === canvas, "Traversal also exits at its last object.")
                window.makeFirstResponder(canvas)
                window.sendEvent(try key("\t", code: 48, flags: .shift, window: window))
                XCTAssertTrue(window.firstResponder === before.currentEditor())
                window.makeFirstResponder(canvas)
                canvas.nextKeyView = canvas
                window.sendEvent(try key("\t", code: 48, window: window))
                XCTAssertFalse(window.firstResponder === canvas, "No eligible destination still cannot trap focus in the graph.")
            }
        }
    }

    func testArrowMoveResizeAndUndoUseCommittedTransactions() throws {
        try onMain {
            var drawing = Diagram(); let node = DiagramNode(x: 200, y: 150)
            drawing.page.nodes = [node]
            try withEditor(drawing) { document, editor, window in
                document.undoManager?.groupsByEvent = false
                _ = editor.canvas.focusCanvasObject(CanvasObjectKey(pageID: drawing.page.id, element: .node(node.id)))
                document.undoManager?.beginUndoGrouping()
                window.sendEvent(try key("", code: 124, flags: .shift, window: window))
                document.undoManager?.endUndoGrouping()
                XCTAssertEqual(document.diagram.page.nodes[0].x, 210)
                XCTAssertEqual(document.diagram.page.nodes[0].width, node.width)
                document.undoManager?.beginUndoGrouping()
                window.sendEvent(try key("", code: 125, flags: [.option, .shift], window: window))
                document.undoManager?.endUndoGrouping()
                XCTAssertEqual(document.diagram.page.nodes[0].height, node.height + 10)
                XCTAssertEqual(document.diagram.page.nodes[0].y, node.y)
                document.undoManager?.undo()
                XCTAssertEqual(document.diagram.page.nodes[0].height, node.height)
                XCTAssertEqual(document.diagram.page.nodes[0].x, 210)
                document.undoManager?.undo()
                XCTAssertEqual(document.diagram.page.nodes[0], node)
            }
        }
    }

    func testProtectedDescendantBlocksGroupTransformAndTextWithoutDirtying() throws {
        try onMain {
            var drawing = Diagram()
            var group = DiagramNode(text: "Group"); group.formatting.isGroup = true
            var child = DiagramNode(x: 120, y: 120, text: "Protected")
            child.parentID = group.id
            child.formatting.sheet["LockMoveX"] = ShapeSheetCell(value: "1")
            child.formatting.sheet["LockTextEdit"] = ShapeSheetCell(value: "1")
            drawing.page.nodes = [group, child]
            try withEditor(drawing) { document, editor, window in
                let state = document.stateID
                _ = editor.canvas.focusCanvasObject(CanvasObjectKey(pageID: drawing.page.id, element: .node(group.id)))
                window.sendEvent(try key("", code: 124, window: window))
                window.sendEvent(try key("", code: 124, flags: .option, window: window))
                XCTAssertEqual(document.stateID, state)
                XCTAssertEqual(document.diagram.page.nodes, drawing.page.nodes)
                _ = editor.canvas.focusCanvasObject(CanvasObjectKey(pageID: drawing.page.id, element: .node(child.id)))
                window.sendEvent(try key("\r", code: 36, window: window))
                XCTAssertFalse(editor.canvas.isEditingText)
                XCTAssertEqual(document.stateID, state)
                XCTAssertTrue(editor.root.status.stringValue.contains("LockTextEdit"))
            }
        }
    }

    func testKeyboardConnectionConfirmUndoAndCancelThroughWindowResponderChain() throws {
        try onMain {
            var drawing = Diagram()
            let source = DiagramNode(x: 100, y: 100, text: "Start")
            let target = DiagramNode(x: 400, y: 100, text: "End")
            drawing.page.nodes = [source, target]
            try withEditor(drawing) { document, editor, window in
                document.undoManager?.groupsByEvent = false
                let canvas = editor.canvas
                _ = canvas.focusCanvasObject(CanvasObjectKey(pageID: drawing.page.id, element: .node(source.id)))
                window.sendEvent(try key("c", code: 8, window: window))
                XCTAssertEqual(canvas.pendingSource, source.id)
                window.sendEvent(try key("\t", code: 48, flags: .option, window: window))
                document.undoManager?.beginUndoGrouping()
                window.sendEvent(try key("\r", code: 36, window: window))
                document.undoManager?.endUndoGrouping()
                XCTAssertEqual(document.diagram.page.edges.count, 1)
                XCTAssertEqual(document.diagram.page.edges[0].source, source.id)
                XCTAssertEqual(document.diagram.page.edges[0].target, target.id)
                XCTAssertNil(canvas.pendingSource)
                document.undoManager?.undo()
                XCTAssertTrue(document.diagram.page.edges.isEmpty)
                let state = document.stateID
                _ = canvas.focusCanvasObject(CanvasObjectKey(pageID: drawing.page.id, element: .node(source.id)))
                window.sendEvent(try key("c", code: 8, window: window))
                window.sendEvent(try key("\t", code: 48, flags: .option, window: window))
                window.sendEvent(try key("\u{1b}", code: 53, window: window))
                XCTAssertNil(canvas.pendingSource)
                XCTAssertEqual(canvas.tool, .pointer)
                XCTAssertEqual(document.stateID, state)
                XCTAssertTrue(document.diagram.page.edges.isEmpty)
            }
        }
    }

    func testLockedGroupedConnectorPreventsIndirectKeyboardGeometryEdit() throws {
        try onMain {
            var drawing = Diagram()
            var group = DiagramNode(text: "Group"); group.formatting.isGroup = true
            var child = DiagramNode(x: 130, y: 130, text: "Child"); child.parentID = group.id
            var edge = DiagramEdge(source: group.id, target: child.id)
            edge.parentID = group.id; edge.layer = "Locked connectors"
            drawing.page.nodes = [group, child]; drawing.page.edges = [edge]
            drawing.page.layers = [DiagramLayer(name: "Default"), DiagramLayer(name: "Locked connectors", locked: true)]
            try withEditor(drawing) { document, editor, window in
                let state = document.stateID
                _ = editor.canvas.focusCanvasObject(CanvasObjectKey(pageID: drawing.page.id, element: .node(group.id)))
                window.sendEvent(try key("", code: 124, window: window))
                XCTAssertEqual(document.stateID, state)
                XCTAssertEqual(document.diagram.page.edges, drawing.page.edges)
                XCTAssertTrue(editor.root.status.stringValue.contains("locked layer"))
            }
        }
    }

    func testInlineKeyboardCancelAndCommitRestoreCanvasCommandRouting() throws {
        try onMain {
            var drawing = Diagram(); let node = DiagramNode(text: "Original")
            drawing.page.nodes = [node]
            try withEditor(drawing) { document, editor, window in
                let canvas = editor.canvas
                let state = document.stateID
                _ = canvas.focusCanvasObject(CanvasObjectKey(pageID: drawing.page.id, element: .node(node.id)))
                window.sendEvent(try key("\r", code: 36, window: window))
                let field = try XCTUnwrap(window.firstResponder as? InlineTextView)
                window.sendEvent(try key("c", code: 8, window: window))
                XCTAssertEqual(field.string, "c")
                XCTAssertNil(canvas.pendingSource, "A letter in the native text editor is text input.")
                window.sendEvent(try key("\u{1b}", code: 53, window: window))
                XCTAssertTrue(window.firstResponder === canvas)
                XCTAssertEqual(document.stateID, state)
                window.sendEvent(try key("c", code: 8, window: window))
                XCTAssertEqual(canvas.pendingSource, node.id, "The same letter resumes a canvas command only after text editing ends.")
                window.sendEvent(try key("\u{1b}", code: 53, window: window))
                window.sendEvent(try key("\r", code: 36, window: window))
                window.sendEvent(try key("t", code: 17, window: window))
                window.sendEvent(try key("\r", code: 36, flags: .command, window: window))
                XCTAssertFalse(canvas.isEditingText)
                XCTAssertTrue(window.firstResponder === canvas)
                XCTAssertEqual(document.diagram.page.nodes[0].text, "t")
                XCTAssertEqual(canvas.tool, .pointer)
            }
        }
    }

    private func withEditor(_ drawing: Diagram, _ body: (MacVisioDocument, EditorWindowController, NSWindow) throws -> Void) throws {
        _ = NSApplication.shared
        let document = MacVisioDocument(); document.diagram = drawing
        document.makeWindowControllers()
        let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
        let window = try XCTUnwrap(editor.window)
        defer {
            editor.canvas.finishEditing(commit: false)
            window.orderOut(nil); window.delegate = nil
            document.removeWindowController(editor); editor.close()
        }
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        editor.canvas.refreshSize()
        window.makeFirstResponder(editor.canvas)
        try body(document, editor, window)
    }
    private func key(_ text: String, code: UInt16, flags: NSEvent.ModifierFlags = [], window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil,
                                      characters: text, charactersIgnoringModifiers: text,
                                      isARepeat: false, keyCode: code))
    }
    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}
