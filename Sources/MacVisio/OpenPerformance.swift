import AppKit

enum OpenPerformance {
    static func profile(_ input:URL,to output:URL) throws {
        guard input.resolvingSymlinksInPath().standardizedFileURL != output.resolvingSymlinksInPath().standardizedFileURL else {
            throw DiagramError.invalid("The timing report must use a different file from the drawing.")
        }
        guard let evidenceRun = PerformanceEvidence.beginRun(heartbeatInterval:1.0/60) else {
            throw DiagramError.invalid("Another qualification run is already active.")
        }
        defer { _ = PerformanceEvidence.endRun(evidenceRun) }
        var stages:[String:Double] = [:]
        let start = ProcessInfo.processInfo.systemUptime
        var last = start
        func mark(_ name:String) {
            let now = ProcessInfo.processInfo.systemUptime
            stages[name] = now-last;last = now
        }
        let result = try PerformanceEvidence.measure(.open) { try VisioFormat.read(from:input,trace:mark) }
        let document = MacVisioDocument()
        document.diagram = try result.diagram.validated()
        document.importWarnings = result.warnings
        mark("documentValidation")
        document.makeWindowControllers()
        defer { document.windowControllers.forEach{$0.close()} }
        guard let editor = document.windowControllers.first as? EditorWindowController,
              let view = editor.window?.contentView else { throw DiagramError.invalid("The editor could not be created.") }
        view.layoutSubtreeIfNeeded();editor.canvas.fitPage();view.layoutSubtreeIfNeeded()
        mark("editorSetup")
        guard let image = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw DiagramError.invalid("The editor viewport could not be drawn.") }
        view.cacheDisplay(in:view.bounds,to:image)
        mark("firstViewport")
        var report:[String:Any] = ["stagesSeconds":stages,"totalSeconds":last-start,
            "pages":document.diagram.pages.count,"nodes":document.diagram.pages.map{$0.nodes.count},
            "edges":document.diagram.pages.map{$0.edges.count},"warnings":result.warnings.count,
            "viewportWidth":image.pixelsWide,"viewportHeight":image.pixelsHigh]
        if let evidence = PerformanceEvidence.endRun(evidenceRun) { report["instrumentation"] = try evidence.jsonObject() }
        let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
        try data.write(to:output,options:.atomic)
        print(String(decoding:data,as:UTF8.self))
    }
}
