import AppKit

/// Profiles real editor commands against an in-memory copy. Never saves input.
enum InteractionPerformance {
    static func profile(_ input:URL,to output:URL) throws {
        guard input.resolvingSymlinksInPath().standardizedFileURL != output.resolvingSymlinksInPath().standardizedFileURL else {
            throw DiagramError.invalid("The timing report must differ from the drawing.")
        }
        guard let evidenceRun = PerformanceEvidence.beginRun(heartbeatInterval:1.0/60) else {
            throw DiagramError.invalid("Another qualification run is already active.")
        }
        defer { _ = PerformanceEvidence.endRun(evidenceRun) }
        var stages:[String:Double] = [:]
        func measure(_ name:String,_ action:()->Void) {
            let began = ProcessInfo.processInfo.systemUptime
            autoreleasepool { action() }
            stages[name] = ProcessInfo.processInfo.systemUptime-began
        }
        let document = MacVisioDocument()
        let began = ProcessInfo.processInfo.systemUptime
        try document.read(from:input,ofType:MacVisioDocument.visioType)
        stages["read"] = ProcessInfo.processInfo.systemUptime-began
        document.undoManager?.groupsByEvent = false
        document.makeWindowControllers()
        defer { document.windowControllers.forEach{$0.close()} }
        guard let editor = document.windowControllers.first as? EditorWindowController,
              let view = editor.window?.contentView else { throw DiagramError.invalid("Editor creation failed.") }
        view.layoutSubtreeIfNeeded();editor.canvas.fitPage();view.layoutSubtreeIfNeeded()
        func draw() {
            guard let image = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { return }
            view.cacheDisplay(in:view.bounds,to:image)
        }
        measure("firstDraw",draw)
        let initialCount = document.diagram.page.nodes.count
        for (index,node) in document.diagram.page.nodes.prefix(3).enumerated() {
            measure("selection\(index)") { editor.canvas.select([node.id]);draw() }
        }
        measure("insertShape") {
            document.undoManager?.beginUndoGrouping()
            editor.insertShape(.rectangle)
            document.undoManager?.endUndoGrouping()
            draw()
        }
        guard document.diagram.page.nodes.count == initialCount+1 else { throw DiagramError.invalid("Insertion check failed.") }
        measure("undo") { document.undoManager?.undo();draw() }
        guard document.diagram.page.nodes.count == initialCount else { throw DiagramError.invalid("Undo check failed.") }
        measure("redo") { document.undoManager?.redo();draw() }
        guard document.diagram.page.nodes.count == initialCount+1 else { throw DiagramError.invalid("Redo check failed.") }
        for (index,page) in document.diagram.pages.enumerated().dropFirst() {
            measure("switchPage\(index)") { editor.switchPage(page.id);draw() }
            let count = document.diagram.page.nodes.count
            measure("insertOnPage\(index)") {
                document.undoManager?.beginUndoGrouping();editor.insertShape(.rectangle);document.undoManager?.endUndoGrouping();draw()
            }
            guard document.diagram.page.nodes.count == count+1 else { throw DiagramError.invalid("Page insertion check failed.") }
            measure("undoOnPage\(index)") { document.undoManager?.undo();draw() }
            guard document.diagram.page.nodes.count == count else { throw DiagramError.invalid("Page undo check failed.") }
        }
        var report:[String:Any] = ["stagesSeconds":stages,"pages":document.diagram.pages.count,"calculationIssueCount":document.calculationIssues.count,
            "nodes":document.diagram.pages.map{$0.nodes.count},"insertUndoRedoPassed":true,"inputSaved":false]
        if let evidence = PerformanceEvidence.endRun(evidenceRun) { report["instrumentation"] = try evidence.jsonObject() }
        let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:output,options:.atomic)
        print(String(decoding:data,as:UTF8.self))
    }
}
