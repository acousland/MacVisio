import AppKit

/// Exercises normal window opening and its deferred focus/layout actions.
/// Heartbeats run throughout import so background load time is not reported as
/// a main-thread stall. Never saves the drawing.
enum LiveOpenCheck {
    static func run(_ delegate:AppDelegate,input:URL,output:URL) {
        guard input.resolvingSymlinksInPath().standardizedFileURL != output.resolvingSymlinksInPath().standardizedFileURL else {
            fputs("Opening report must differ from its input.\n",stderr);exit(1)
        }
        let began = ProcessInfo.processInfo.systemUptime
        var phaseIsOpening = true,lastPulse = began,openMaxGap = 0.0,postOpenMaxGap = 0.0,openPulses = 0,postOpenPulses = 0
        let pulse = Timer(timeInterval:0.05,repeats:true) { _ in
            let now = ProcessInfo.processInfo.systemUptime,gap = now-lastPulse
            if phaseIsOpening { openMaxGap = max(openMaxGap,gap);openPulses += 1 }
            else { postOpenMaxGap = max(postOpenMaxGap,gap);postOpenPulses += 1 }
            lastPulse = now
        }
        RunLoop.main.add(pulse,forMode:.common)
        NSApp.activate(ignoringOtherApps:true)
        delegate.open(input) { document,error in
            let loaded = ProcessInfo.processInfo.systemUptime
            openMaxGap = max(openMaxGap,loaded-lastPulse)
            guard let document,error == nil,
                  let editor = document.windowControllers.first as? EditorWindowController else {
                pulse.invalidate()
                let report:[String:Any] = ["openSeconds":loaded-began,"maximumMainThreadGapDuringOpenSeconds":openMaxGap,
                    "openingError":error?.localizedDescription ?? "Document opening failed."]
                do {
                    let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
                    try data.write(to:output,options:.atomic);print(String(decoding:data,as:UTF8.self));exit(1)
                } catch { fputs("Opening report failed: \(error.localizedDescription)\n",stderr);exit(1) }
            }
            let original = document.diagram
            phaseIsOpening = false;lastPulse = loaded
            DispatchQueue.main.asyncAfter(deadline:.now()+2) {
                pulse.invalidate()
                let now = ProcessInfo.processInfo.systemUptime
                postOpenMaxGap = max(postOpenMaxGap,now-lastPulse)
                let unchanged = document.diagram == original
                let ready = editor.window?.isVisible == true && editor.window?.firstResponder === editor.canvas
                let maximumGap = max(openMaxGap,postOpenMaxGap)
                let report:[String:Any] = ["openSeconds":loaded-began,"postOpenSeconds":now-loaded,
                    "maximumMainThreadGapSeconds":maximumGap,
                    "maximumMainThreadGapDuringOpenSeconds":openMaxGap,
                    "maximumPostOpenMainThreadGapSeconds":postOpenMaxGap,
                    "openingHeartbeatCount":openPulses,"postOpenHeartbeatCount":postOpenPulses,
                    "diagramUnchanged":unchanged,"documentEdited":document.isDocumentEdited,
                    "fileModificationDateKnown":document.fileModificationDate != nil,
                    "windowReady":ready,"sheetAttached":editor.window?.attachedSheet != nil,
                    "pages":document.diagram.pages.count,"nodes":document.diagram.pages.map{$0.nodes.count}]
                do {
                    let data = try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys])
                    try data.write(to:output,options:.atomic);print(String(decoding:data,as:UTF8.self))
                    exit(ready && unchanged && !document.isDocumentEdited && document.fileModificationDate != nil && maximumGap < 0.5 ? 0 : 1)
                } catch { fputs("Opening report failed: \(error.localizedDescription)\n",stderr);exit(1) }
            }
        }
    }
}
