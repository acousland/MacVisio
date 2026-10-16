import AppKit
import ApplicationServices

/// One owned synthetic run. The Python adapter verifies the immutable public
/// corpus before invoking this entry point; no input is ever saved in place.
enum BenchmarkProfile {
    static var nativeRoutingUnavailableReason: String? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return "Native event routing requires an interactive graphics session."
        }
        if (session["CGSSessionScreenIsLocked"] as? Bool) == true {
            return
                "Native event routing requires an unlocked desktop; the graphics session reports a locked screen."
        }
        return nil
    }

    static let phaseNames = [
        "open", "event", "commit", "calculation", "textLayout", "scenePreparation", "route", "draw",
        "snapshot", "encoding", "save", "close",
    ]
    static func sample(_ input: URL, to output: URL) throws -> Bool {
        guard Thread.isMainThread else {
            throw DiagramError.invalid("Benchmark must run on the main thread.")
        }
        let source = input.resolvingSymlinksInPath().standardizedFileURL
        let result = output.resolvingSymlinksInPath().standardizedFileURL
        guard source != result, !FileManager.default.fileExists(atPath: output.path) else {
            throw DiagramError.invalid("Benchmark result must be a new path distinct from its input.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacVisio-benchmark-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        guard let run = PerformanceEvidence.beginRun(heartbeatInterval: 0.002) else {
            throw DiagramError.invalid("A benchmark run is already active.")
        }
        defer { _ = PerformanceEvidence.endRun(run) }
        let document = MacVisioDocument()
        var completed: [String: Double] = [:]
        var failure: String?
        var failurePhase = "open"
        var activePageShapes = 0
        var metrics: [String: Double] = [:]
        func now() -> Double { ProcessInfo.processInfo.systemUptime }
        func pump(until condition: () -> Bool, timeout: Double = 30) throws {
            let deadline = now() + timeout
            while !condition() {
                guard now() < deadline else { throw DiagramError.invalid("Benchmark callback timed out.") }
                _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.002))
            }
        }
        func heartbeatTurn() throws {
            let until = now() + 0.008
            try pump(until: { now() >= until }, timeout: 1)
        }
        do {
            try heartbeatTurn()
            let opened = now()
            try document.read(from: input, ofType: MacVisioDocument.visioType)
            guard !document.diagram.page.nodes.isEmpty,
                document.diagram.pages.allSatisfy({
                    $0.name.hasPrefix("Synthetic ") && $0.nodes.allSatisfy { $0.text.hasPrefix("Synthetic ") }
                })
            else {
                throw DiagramError.invalid("Benchmark requires generated synthetic pages and shapes.")
            }
            activePageShapes = document.diagram.page.nodes.count
            document.undoManager?.groupsByEvent = false
            document.makeWindowControllers()
            guard let editor = document.windowControllers.first as? EditorWindowController,
                let view = editor.window?.contentView
            else { throw DiagramError.invalid("Benchmark editor was not created.") }
            view.layoutSubtreeIfNeeded()
            editor.canvas.fitPage()
            view.layoutSubtreeIfNeeded()
            func viewport() throws {
                guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    throw DiagramError.invalid("Benchmark viewport rasterization failed.")
                }
                view.cacheDisplay(in: view.bounds, to: image)
            }
            try viewport()
            completed["open"] = now() - opened  // Read, editor layout and first rasterized viewport.
            try heartbeatTurn()
            failurePhase = "event"
            guard
                let node = document.diagram.page.nodes.first(where: {
                    document.diagram.page.isVisible($0) && !document.diagram.page.isLocked($0)
                }), let window = editor.window
            else {
                throw DiagramError.invalid("Benchmark has no editable visible shape.")
            }
            if let reason = nativeRoutingUnavailableReason { throw DiagramError.invalid(reason) }
            let canvas = editor.canvas
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try pump(until: { window.isKeyWindow }, timeout: 3)
            guard window.makeFirstResponder(canvas), window.firstResponder === canvas else {
                throw DiagramError.invalid("Benchmark canvas did not receive keyboard focus.")
            }
            var dispatchedEvents = 0
            func dispatch(_ event: NSEvent) throws {
                NSApp.postEvent(event, atStart: false)
                let deadline = Date(timeIntervalSinceNow: 2)
                while let queued = NSApp.nextEvent(
                    matching: .any, until: deadline, inMode: .default, dequeue: true)
                {
                    NSApp.sendEvent(queued)
                    // AppKit may copy an event when posting; match the owned
                    // immutable type/window/timestamp instead of object identity.
                    if queued.type == event.type && queued.windowNumber == event.windowNumber
                        && abs(queued.timestamp - event.timestamp) < 0.000001
                    {

                        dispatchedEvents += 1
                        return
                    }
                    guard Date() < deadline else { break }
                }
                throw DiagramError.invalid("Benchmark event queue did not deliver its owned event.")
            }
            let target = CGPoint(
                x: canvas.pageOrigin.x + node.center.x * canvas.coordinateZoom,
                y: canvas.pageOrigin.y + node.center.y * canvas.coordinateZoom)
            canvas.scrollToVisible(CGRect(x: target.x - 20, y: target.y - 20, width: 40, height: 40))
            guard canvas.visibleRect.contains(target) else {
                throw DiagramError.invalid("Benchmark target could not be scrolled into the viewport.")
            }
            let location = canvas.convert(target, to: nil)
            let before = document.diagram
            let eventStarted = now()
            document.undoManager?.beginUndoGrouping()
            defer {
                if (document.undoManager?.groupingLevel ?? 0) > 0 { document.undoManager?.endUndoGrouping() }
            }
            for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
                guard
                    let event = NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: [], timestamp: now(),
                        windowNumber: window.windowNumber, context: nil, eventNumber: 61001 + index,
                        clickCount: 1,
                        pressure: 1)
                else { throw DiagramError.invalid("Benchmark mouse event creation failed.") }
                try dispatch(event)
            }
            guard !canvas.selectedNodes.isEmpty else {
                let hit = window.contentView?.superview?.hitTest(location)
                let name = hit.map { String(describing: type(of: $0)) } ?? "nil"
                throw DiagramError.invalid(
                    "Benchmark routed mouse produced no selection (hit=\(name), location=\(location), canvasVisible=\(canvas.visibleRect), geometricHit=\(canvas.node(at:node.center) != nil), windowKey=\(window.isKeyWindow), appActive=\(NSApp.isActive))."
                )
            }
            guard
                let key = NSEvent.keyEvent(
                    with: .keyDown, location: location, modifierFlags: [], timestamp: now(),
                    windowNumber: window.windowNumber, context: nil, characters: "\u{F703}",
                    charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124)
            else {
                throw DiagramError.invalid("Benchmark selection or key event creation failed.")
            }
            try dispatch(key)
            try pump(until: { !document.isCalculating })
            if let error = document.lastCalculationJobError { throw error }
            guard document.diagram != before, document.calculationIssues.isEmpty else {
                throw DiagramError.invalid("Benchmark event did not produce a clean committed edit.")
            }
            try viewport()
            guard dispatchedEvents == 3, window.firstResponder === canvas else {
                throw DiagramError.invalid("Benchmark native event routing changed unexpectedly.")
            }
            metrics["routedEvents"] = Double(dispatchedEvents)
            completed["event"] = now() - eventStarted
            metrics["inputToFeedbackMs"] = (now() - eventStarted) * 1000
            document.undoManager?.endUndoGrouping()
            try heartbeatTurn()
            failurePhase = "save"
            let destination = directory.appendingPathComponent("snapshot.macvisio")
            let saved = document.diagram
            let saveStarted = now()
            var saveCompleted = false
            var saveError: Error?
            document.save(to: destination, ofType: MacVisioDocument.nativeType, for: .saveAsOperation) {
                error in
                saveError = error
                saveCompleted = true
            }
            try pump(until: { saveCompleted })
            if let saveError { throw saveError }
            completed["save"] = now() - saveStarted
            let restored = try JSONDecoder().decode(Diagram.self, from: Data(contentsOf: destination))
            guard restored == saved else {
                throw DiagramError.invalid("Benchmark saved snapshot did not match committed state.")
            }
            try heartbeatTurn()
        } catch { failure = error.localizedDescription }
        let closing = now()
        document.close()
        completed["close"] = now() - closing
        let evidence = PerformanceEvidence.endRun(run)!
        var phases: [String: Any] = [:]
        for name in phaseNames {
            if let seconds = completed[name] {
                phases[name] = ["status": "passed", "elapsedMs": seconds * 1000]
            } else if let summary = evidence.stages[name], summary.count > 0 {
                phases[name] = [
                    "status": "passed", "elapsedMs": summary.totalSeconds * 1000,
                    "timingScope": "inclusive instrumented work total",
                ]
            } else {
                phases[name] = ["status": "not_observed", "reason": "No instrumented work observed"]
            }
        }
        if let failure { phases[failurePhase] = ["status": "failed", "reason": failure] }
        if !document.calculationIssues.isEmpty {
            phases["calculation"] = ["status": "failed", "issueCount": document.calculationIssues.count]
        }
        if evidence.stages["encoding"] != nil, evidence.workCounts["encodedDocuments"] == nil {
            phases["encoding"] = ["status": "failed", "reason": "No successful document encoding"]
        }
        if evidence.unfinishedSpans > 0 {
            phases["driver"] = ["status": "failed", "reason": "Unfinished instrumentation spans"]
        }
        let passed = failure == nil && evidence.unfinishedSpans == 0
        let report: [String: Any] = [
            "schemaVersion": 1, "status": passed ? "passed" : "failed", "phases": phases,
            "workCounts": evidence.workCounts, "metrics": metrics,
            "activePageShapes": activePageShapes, "instrumentation": try evidence.jsonObject(),
            "inputSaved": false,
            "importWarningCount": document.importWarnings.count,
            "calculationIssueCount": document.calculationIssues.count,
            "eventTrace":
                "Owned synthesized mouse down/up and right-arrow events posted to NSApplication queue, dispatched through NSApplication/NSWindow hit testing and responder routing, committed state verified then rasterized feedback; no hardware input or compositor timing",
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(
            to: output, options: .atomic)
        return passed
    }
}
