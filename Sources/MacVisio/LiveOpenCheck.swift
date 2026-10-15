import AppKit

/// Exercises normal window opening and its deferred focus/layout actions.
/// Unlike the offscreen importer profile, this also detects unintended edits
/// and stalls after the window has been shown. Never saves the drawing.
enum LiveOpenCheck {
    static func run(_ delegate:AppDelegate,input:URL,output:URL) {
        guard input.resolvingSymlinksInPath().standardizedFileURL != output.resolvingSymlinksInPath().standardizedFileURL else { fputs("Opening report must differ from its input.\n",stderr);exit(1) }
        let began = ProcessInfo.processInfo.systemUptime
        NSApp.activate(ignoringOtherApps:true)
        delegate.open(input)
        guard let document = NSDocumentController.shared.documents.compactMap({$0 as? MacVisioDocument}).first(where:{$0.fileURL == input}),
              let editor = document.windowControllers.first as? EditorWindowController else { fputs("Document opening failed.\n",stderr);exit(1) }
        let loaded = ProcessInfo.processInfo.systemUptime,original = document.diagram
        var lastPulse = loaded,maxGap = 0.0,pulses = 0
        let pulse = Timer(timeInterval:0.05,repeats:true) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            maxGap = max(maxGap,now-lastPulse);lastPulse = now;pulses += 1
        }
        RunLoop.main.add(pulse,forMode:.common)
        DispatchQueue.main.asyncAfter(deadline:.now()+2) {
            pulse.invalidate()
            let now = ProcessInfo.processInfo.systemUptime
            maxGap = max(maxGap,now-lastPulse)
            let unchanged = document.diagram == original
            let ready = editor.window?.isVisible == true && editor.window?.firstResponder === editor.canvas
            let report:[String:Any] = ["openSeconds":loaded-began,"postOpenSeconds":now-loaded,
                "maximumMainThreadGapSeconds":maxGap,"heartbeatCount":pulses,
                "diagramUnchanged":unchanged,"documentEdited":document.isDocumentEdited,
                "fileModificationDateKnown":document.fileModificationDate != nil,
                "windowReady":ready,"sheetAttached":editor.window?.attachedSheet != nil,
                "pages":document.diagram.pages.count,"nodes":document.diagram.pages.map{$0.nodes.count}]
            do {
                let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
                try data.write(to:output,options:.atomic);print(String(decoding:data,as:UTF8.self))
                exit(ready && unchanged && !document.isDocumentEdited && document.fileModificationDate != nil && maxGap < 0.5 ? 0 : 1)
            } catch { fputs("Opening report failed: \(error.localizedDescription)\n",stderr);exit(1) }
        }
    }
}
