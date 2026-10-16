import MacVisioInfrastructure
import AppKit
import UniformTypeIdentifiers
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let updates = AppUpdates()
    private var openedAtLaunch = false
    private weak var diagnosticDocument:MacVisioDocument?
    private var openingTokens:[UUID:String] = [:]
    private var openingOrder:[UUID] = []
    private struct PendingDocumentOpen {
        let token:UUID
        let progress:LifecycleProgressController
        var handle:LifecycleJobHandle?
        var completions:[(MacVisioDocument?,Error?)->Void]
    }
    private var pendingDocumentOpens:[URL:PendingDocumentOpen] = [:]
    private let openJobOwner = LifecycleJobOwner()
    private let libraryJobOwner = LifecycleJobOwner()
    private var libraryRequestID = UUID()
    lazy var workflow = DocumentWorkflow(delegate:self,recordsSystemRecents:!CommandLine.arguments.contains("--open-check") && !CommandLine.arguments.contains("--launch-check"))
    // This delegate owns startup templates and file-opening behavior. Letting
    // AppKit also create an untitled document produces a second blank window.
    func applicationShouldOpenUntitledFile(_ sender:NSApplication) -> Bool { false }
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSColorPanel.shared.showsAlpha = true
        buildMenus()
        if !CommandLine.arguments.contains("--launch-check") && !CommandLine.arguments.contains("--open-check") { updates.start() }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let index = CommandLine.arguments.firstIndex(of:"--open-check"),CommandLine.arguments.indices.contains(index+2) {
                LiveOpenCheck.run(self,input:URL(fileURLWithPath:CommandLine.arguments[index+1]),output:URL(fileURLWithPath:CommandLine.arguments[index+2]));return
            }
            if CommandLine.arguments.contains("--launch-check") { self.diagnosticDocument = self.newDiagram(template:.flowchart) }
            else { self.workflow.start(showHome:!self.openedAtLaunch); self.refreshOpeningIndicator() }
            NSApp.activate(ignoringOtherApps:true)
            if let index = CommandLine.arguments.firstIndex(of:"--launch-check"),CommandLine.arguments.indices.contains(index+1) {
                DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
                    let documents = NSDocumentController.shared.documents
                    let document = self.diagnosticDocument
                    let controller = document?.windowControllers.first as? EditorWindowController
                    let visible = controller?.window?.isVisible == true
                    let actionTarget = NSApp.target(forAction:#selector(NSDocument.save(_:)))
                    let saveTarget = actionTarget as? MacVisioDocument
                    let controllerSaveTarget = controller?.supplementalTarget(forAction:#selector(NSDocument.save(_:)),sender:nil) as? MacVisioDocument
                    var chain: [String] = []; var responder = controller?.window?.firstResponder
                    while let current = responder,chain.count < 20 { chain.append(NSStringFromClass(type(of:current))); responder = current.nextResponder }
                    let checks: [String:Any] = [
                        "windowVisible":visible,
                        "documentRegistered":document.map{doc in documents.contains(where:{$0 === doc})} ?? false,
                        "documentsInDiagnosticInstance":documents.count,
                        "diagnosticDocumentHasExpectedShapes":document?.diagram.page.nodes.count == 8,
                        "controllerRegistered":document?.windowControllers.count == 1,
                        "canvasHasSize":(controller?.canvas.bounds.width ?? 0) > 0,
                        "canvasIsFirstResponder":controller?.window?.firstResponder === controller?.canvas,
                        "foregroundMenuRoutingVerified":NSApp.isActive && saveTarget === document,
                        "saveActionRoutesViaController":controllerSaveTarget === document,
                        "saveActionTargetClass":actionTarget.map { NSStringFromClass(type(of:$0 as AnyObject)) } ?? "nil",
                        "keyWindowIsEditor":NSApp.keyWindow === controller?.window,
                        "applicationActive":NSApp.isActive,
                        "windowCanBecomeKey":controller?.window?.canBecomeKey == true,
                        "mainWindowIsEditor":NSApp.mainWindow === controller?.window,
                        "activationPolicy":NSApp.activationPolicy().rawValue,
                        "controllerHasDocument":controller?.document === document,
                        "responderChain":chain,
                        "menuCount":NSApp.mainMenu?.numberOfItems ?? 0,
                        "shapeCount":document?.diagram.page.nodes.count ?? 0
                    ]
                    do {
                        let data = try JSONSerialization.data(withJSONObject:checks,options:[.prettyPrinted,.sortedKeys])
                        try data.write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]),options:.atomic)
                        let passed = visible && document != nil && documents.contains(where:{$0 === document}) && document?.diagram.page.nodes.count == 8 && controllerSaveTarget === document && controller?.window?.firstResponder === controller?.canvas
                        print(passed ? "Native launch checks passed" : "Native launch checks failed")
                        exit(passed ? 0 : 1)
                    } catch { fputs("Launch check failed: \(error)\n",stderr); exit(1) }
                }
            }
        }
    }
    @discardableResult func newDiagram(template:DiagramTemplate) -> MacVisioDocument {
        let doc = MacVisioDocument(); doc.diagram = template.makeDiagram(); doc.fileType = MacVisioDocument.visioType
        NSDocumentController.shared.addDocument(doc);workflow.documentOpened(doc); doc.makeWindowControllers(); doc.showWindows()
        return doc
    }
    @objc func newDocument(_ sender:Any?) { workflow.showWelcome(.new) }
    @objc func newBlankDocument(_ sender:Any?) { newDiagram(template:.blank) }
    @objc func newFlowchart(_ sender:Any?) { newDiagram(template:.flowchart) }
    @objc func newOrganization(_ sender:Any?) { newDiagram(template:.organization) }
    @objc func newNetwork(_ sender:Any?) { newDiagram(template:.network) }
    @objc func newSwimlane(_ sender:Any?) { newDiagram(template:.swimlane) }
    @objc func openDocument(_ sender:Any?) { workflow.showWelcome(.open) }
    @objc func browseDocuments(_ sender:Any?) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = ["macvisio","vsdx","vsd","vstx","vst","vssx","vss"].map{UTType(filenameExtension:$0) ?? .data}; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }
    @objc func openVisioLibrary(_ sender:Any?) {
        let defaults = UserDefaults.standard,key = "MacVisioLibraryDirectory"
        let adjacent = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Visio2019-Libraries")
        var directory = defaults.string(forKey:key).map{URL(fileURLWithPath:$0)} ?? adjacent
        if !FileManager.default.fileExists(atPath:directory.path) {
            let panel = NSOpenPanel();panel.canChooseFiles = false;panel.canChooseDirectories = true;panel.prompt = "Choose Library Folder";panel.message = "Choose a folder containing Visio stencils and templates."
            guard panel.runModal() == .OK,let chosen = panel.url else { return };directory = chosen
        }
        loadVisioLibrary(directory)
    }
    @objc func chooseVisioLibraryFolder(_ sender:Any?) {
        let panel = NSOpenPanel();panel.canChooseFiles = false;panel.canChooseDirectories = true;panel.prompt = "Choose Library Folder"
        guard panel.runModal() == .OK,let url = panel.url else { return }
        loadVisioLibrary(url)
    }
    private func loadVisioLibrary(_ directory:URL) {
        let requestID = UUID();libraryRequestID = requestID
        let owner = libraryJobOwner
        let jobID = UUID()
        let progress = LifecycleProgressController(title:"Scanning library",detail:directory.lastPathComponent)
        do {
            let input = LifecycleJobInput(ownerID:owner.id,snapshotID:requestID,revision:0)
            let handle = try LifecycleJobService.shared.submit(id:jobID,kind:.library,input:input,accepts:{ [weak self] candidate in
                self?.libraryRequestID == candidate.snapshotID && owner.isActive
            },progress:{ progress.update($0) },work:{ context in
                context.progress("Scanning \(directory.lastPathComponent)")
                let entries = try VisioLibrary.entries(in:directory)
                guard !entries.isEmpty else { throw DiagramError.invalid("This folder has no supported Visio stencils or templates.") }
                return entries
            },completion:{ [weak self] result in
                progress.finish()
                owner.finish(jobID)
                switch result {
                case .success(let entries):
                    guard let self else { return }
                    UserDefaults.standard.set(directory.path,forKey:"MacVisioLibraryDirectory")
                    if let chosen = VisioLibraryPicker(entries:entries).run() { self.open(chosen.url) }
                case .failure(let error):
                    if (error as? LifecycleJobError) != .cancelled && (error as? LifecycleJobError) != .staleInput { NSApp.presentError(error) }
                }
            })
            owner.track(handle,replacing:"library-scan")
            progress.onCancel = { [weak handle] in handle?.cancel() }
            progress.show()
        } catch { progress.finish();NSApp.presentError(error) }
    }
    @discardableResult private func beginOpening(_ url:URL) -> UUID {
        let token = UUID();openingTokens[token] = url.lastPathComponent;openingOrder.append(token)
        refreshOpeningIndicator();workflow.welcome?.window?.displayIfNeeded();return token
    }
    private func finishOpening(_ token:UUID) {
        openingTokens.removeValue(forKey:token);openingOrder.removeAll{$0 == token};refreshOpeningIndicator()
    }
    private func refreshOpeningIndicator() {
        let name = openingOrder.compactMap{openingTokens[$0]}.first
        workflow.welcome?.showOpening(name)
    }
    func open(_ url:URL,completion:((MacVisioDocument?,Error?)->Void)? = nil) {
        if let existing = workflow.drawings.first(where:{$0.fileURL.map(DocumentWorkflow.canonicalDrawingURL) == DocumentWorkflow.canonicalDrawingURL(url)}) {
            workflow.noteRecent(url);workflow.activate(existing);completion?(existing,nil);return
        }
        let ext = url.pathExtension.lowercased()
        if ext != "vssx" && ext != "vss" {
            let key = DocumentWorkflow.canonicalDrawingURL(url)
            if var pending = pendingDocumentOpens[key] {
                if let completion { pending.completions.append(completion) }
                pendingDocumentOpens[key] = pending
                return
            }
            let token = beginOpening(url)
            let progress = LifecycleProgressController(title:"Opening drawing",detail:url.lastPathComponent)
            pendingDocumentOpens[key] = PendingDocumentOpen(token:token,progress:progress,completions:completion.map{[$0]} ?? [])
            let type = ["vsdx","vstx"].contains(ext) ? MacVisioDocument.visioType : ["vsd","vst"].contains(ext) ? MacVisioDocument.legacyType : MacVisioDocument.nativeType
            // Initialize explicitly on a worker, retaining NSDocument's file
            // bookkeeping. Controller-managed opening adds file coordination
            // that can stall before the actual reader is reached.
            do {
                let input = LifecycleJobInput(ownerID:openJobOwner.id,snapshotID:token,revision:0)
                let handle = try LifecycleJobService.shared.submit(kind:.open,input:input,accepts:{ [weak self] candidate in
                    self?.pendingDocumentOpens[key]?.token == candidate.snapshotID && self?.openJobOwner.isActive == true
                },progress:{ progress.update($0) },work:{ context in
                    context.progress("Reading \(url.lastPathComponent)")
                    return try MacVisioDocument(contentsOf:url,ofType:type)
                },completion:{ [weak self] result in
                    guard let self else { progress.finish();return }
                    switch result {
                    case .success(let document):
                        let asNew = ext == "vstx" || ext == "vst" || ext == "vsd" && !document.legacyNative
                        if asNew { document.fileURL = nil;document.fileType = MacVisioDocument.visioType;document.updateChangeCount(.changeDone) }
                        NSDocumentController.shared.addDocument(document)
                        self.finishAsyncOpen(document,wasAlreadyOpen:false,error:nil,url:url,key:key)
                    case .failure(let error):
                        self.finishAsyncOpen(nil,wasAlreadyOpen:false,error:error,url:url,key:key)
                    }
                })
                pendingDocumentOpens[key]?.handle = handle
                openJobOwner.track(handle)
                progress.onCancel = { [weak handle] in handle?.cancel() }
                progress.show()
            } catch {
                finishAsyncOpen(nil,wasAlreadyOpen:false,error:error,url:url,key:key)
            }
            return
        }
        let token = beginOpening(url)
        if NSDocumentController.shared.documents.isEmpty { newDiagram(template:.blank) }
        let editor = (NSApp.keyWindow?.windowController as? EditorWindowController) ?? NSDocumentController.shared.documents.compactMap{$0.windowControllers.first as? EditorWindowController}.last
        guard let editor else { finishOpening(token);completion?(nil,DiagramError.invalid("No drawing is available for this stencil."));return }
        editor.showWindow(nil)
        editor.loadStencil(url) { [weak self] error in self?.finishOpening(token);completion?(nil,error) }
    }
    private func finishAsyncOpen(_ document:MacVisioDocument?,wasAlreadyOpen:Bool,error:Error?,url:URL,key:URL) {
        guard let pending = pendingDocumentOpens.removeValue(forKey:key) else { return }
        pending.progress.finish()
        if let handle = pending.handle { openJobOwner.finish(handle.id) }
        finishOpening(pending.token)
        var resultDocument:MacVisioDocument?,resultError = error
        if let error {
            if (error as? LifecycleJobError) != .cancelled && (error as? LifecycleJobError) != .staleInput { NSApp.presentError(error) }
        } else if let document {
            resultDocument = document
            let alreadyManaged = workflow.drawings.contains{$0 === document}
            if wasAlreadyOpen || alreadyManaged {
                workflow.documentOpened(document,sourceURL:url)
                if document.windowControllers.isEmpty { document.makeWindowControllers();document.showWindows() }
                else { workflow.activate(document) }
            } else {
                workflow.documentOpened(document,sourceURL:url)
                document.makeWindowControllers();document.showWindows()
            }
        } else {
            let failure = DiagramError.invalid("This file could not be opened as a MacVisio drawing.")
            resultError = failure;NSApp.presentError(failure)
        }
        for completion in pending.completions { completion(resultDocument,resultError) }
    }
    func application(_ sender:NSApplication,openFiles filenames:[String]) {
        // Diagnostic arguments include paths which AppKit may also deliver as
        // opening events at launch. The diagnostic opens its input explicitly.
        if CommandLine.arguments.contains("--open-check") { sender.reply(toOpenOrPrint:.success);return }
        openedAtLaunch = true
        guard !filenames.isEmpty else { sender.reply(toOpenOrPrint:.success);return }
        var remaining = filenames.count,failed = false
        for name in filenames {
            open(URL(fileURLWithPath:name)) { _,error in
                if error != nil { failed = true }
                remaining -= 1
                if remaining == 0 { sender.reply(toOpenOrPrint:failed ? .failure : .success) }
            }
        }
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool) -> Bool {
        if !flag { if let document = workflow.activeDrawing { workflow.activate(document) } else { workflow.showWelcome() } };return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        workflow.isTerminating = true
        openJobOwner.cancelAll();libraryJobOwner.cancelAll()
        for document in NSDocumentController.shared.documents { (document as? MacVisioDocument)?.commitTextEditing() }
        guard NSDocumentController.shared.documents.contains(where:{$0.isDocumentEdited}) else { return .terminateNow }
        NSDocumentController.shared.closeAllDocuments(withDelegate:self,didCloseAllSelector:#selector(documentsClosed(_:didCloseAll:contextInfo:)),contextInfo:nil)
        return .terminateLater
    }
    @objc func documentsClosed(_ controller:NSDocumentController,didCloseAll:Bool,contextInfo:UnsafeMutableRawPointer?) { workflow.isTerminating = didCloseAll;NSApp.reply(toApplicationShouldTerminate:didCloseAll) }
    @objc func showHelp(_ sender:Any?) {
        let alert = NSAlert(); alert.messageText = "Drawing with MacVisio"
        alert.informativeText = "Drag a shape from the left library, or click it to add it. Double-click any shape to edit its text. Select text and use ⌘B, ⌘I or ⌘U for bold, italic or underline. Shape > Text Format > Show Fonts changes the selected font. Press ⌘Return to finish editing.\n\nPress C and click two shapes to connect them. Switch back to the pointer with V. T adds a text box. Drag selection handles to resize.\n\nShift-click or drag a rectangle to select multiple shapes. ⌘D duplicates; Delete removes. Arrow keys nudge; Shift moves 10 points. Hold Option to bypass snapping.\n\nSave editable drawings as .vsdx or .macvisio. Open .vssx stencils from the Shape menu. Press L to draw a free line. Use Group, Layers, Shape Data and ShapeSheet from the menus. Export pages to PDF, PNG or SVG. Legacy .vsd imports are converted and saved as .vsdx."
        alert.addButton(withTitle:"Got it"); alert.runModal()
    }
    @objc func showCompatibility(_ sender:Any?) {
        let alert = NSAlert(); alert.messageText = "Visio compatibility"
        alert.informativeText = "MacVisio reads and writes VSDX drawings and retains source package parts for supported edits. It supports cached vector geometry, nested groups, images, layers, Shape Data, hyperlinks, numeric ShapeSheet formulas and VSSX stencil loading.\n\nLegacy VSD import converts saved graphics into editable shapes using libvisio. Binary VSD writing is experimental. It writes cached graphics and text; full legacy formula, data and glue semantics are incomplete. Output has not been validated in Microsoft Visio. Legacy formula logic, shape data and connector glue are not retained.\n\nFull Microsoft Visio feature parity is not implemented. Advanced ShapeSheet functions, text fields and advanced layout, some geometry and effects, data linking, macros and add-ins remain incomplete. VSDX output has not been tested in Windows Visio. Keep original files while evaluating compatibility."
        alert.addButton(withTitle:"OK"); alert.runModal()
    }
    private func buildMenus() {
        let main = NSMenu(); NSApp.mainMenu = main
        func menu(_ title:String) -> NSMenu { let item = NSMenuItem(); item.title = title; let result = NSMenu(title:title); item.submenu = result; main.addItem(item); return result }
        func item(_ menu:NSMenu,_ title:String,_ action:Selector,_ key:String = "",modifiers:NSEvent.ModifierFlags = .command,target:AnyObject? = nil) {
            let i = NSMenuItem(title:title,action:action,keyEquivalent:key); i.keyEquivalentModifierMask = modifiers; i.target = target; menu.addItem(i)
        }
        let app = menu("MacVisio")
        item(app,"About MacVisio",#selector(NSApplication.orderFrontStandardAboutPanel(_:)),target:NSApp)
        item(app,"Check for Updates…",#selector(SPUStandardUpdaterController.checkForUpdates(_:)),target:updates.controller)
        item(app,"Automatically Check for Updates",#selector(AppUpdates.toggleAutomaticChecks(_:)),target:updates)
        app.addItem(.separator()); let services = NSMenuItem(title:"Services",action:nil,keyEquivalent:""); services.submenu = NSMenu(title:"Services"); app.addItem(services); NSApp.servicesMenu = services.submenu
        app.addItem(.separator()); item(app,"Hide MacVisio",#selector(NSApplication.hide(_:)),"h",target:NSApp); item(app,"Hide Others",#selector(NSApplication.hideOtherApplications(_:)),"h",modifiers:[.command,.option],target:NSApp); item(app,"Show All",#selector(NSApplication.unhideAllApplications(_:)),target:NSApp)
        app.addItem(.separator()); item(app,"Quit MacVisio",#selector(NSApplication.terminate(_:)),"q",target:NSApp)
        let file = menu("File")
        item(file,"Home",#selector(DocumentWorkflow.showHome(_:)),target:workflow)
        item(file,"New Diagram",#selector(newDocument(_:)),"n",target:self)
        item(file,"New Blank Drawing",#selector(newBlankDocument(_:)),"n",modifiers:[.command,.shift],target:self)
        let examples = NSMenuItem(title:"New from Template",action:nil,keyEquivalent:""); let ex = NSMenu(title:"New from Template"); examples.submenu = ex; file.addItem(examples)
        item(ex,"Flowchart",#selector(newFlowchart(_:)),target:self); item(ex,"Organization Chart",#selector(newOrganization(_:)),target:self); item(ex,"Network",#selector(newNetwork(_:)),target:self); item(ex,"Swimlanes",#selector(newSwimlane(_:)),target:self)
        item(file,"Open…",#selector(openDocument(_:)),"o",target:self)
        item(file,"Browse Files…",#selector(browseDocuments(_:)),"o",modifiers:[.command,.shift],target:self)
        let recent = NSMenuItem(title:"Open Recent",action:nil,keyEquivalent:"");recent.submenu = workflow.makeRecentMenu();file.addItem(recent)
        file.addItem(.separator()); item(file,"Close",#selector(NSWindow.performClose(_:)),"w"); item(file,"Save…",#selector(NSDocument.save(_:)),"s"); item(file,"Save As…",#selector(NSDocument.saveAs(_:)),"s",modifiers:[.command,.shift]); item(file,"Revert to Saved…",#selector(NSDocument.revertToSaved(_:)))
        item(file,"Close All Drawings",#selector(DocumentWorkflow.closeAllDrawings(_:)),"w",modifiers:[.command,.option],target:workflow)
        item(file,"Visio Libraries…",#selector(openVisioLibrary(_:)),target:self);item(file,"Choose Visio Library Folder…",#selector(chooseVisioLibraryFolder(_:)),target:self)
        file.addItem(.separator()); item(file,"Export PDF…",#selector(EditorWindowController.exportPDF(_:))); item(file,"Export All Pages to PDF…",#selector(EditorWindowController.exportAllPagesPDF(_:))); item(file,"Export PNG…",#selector(EditorWindowController.exportPNG(_:))); item(file,"Export SVG…",#selector(EditorWindowController.exportSVG(_:))); item(file,"Export VSDX Drawing…",#selector(EditorWindowController.exportVSDX(_:))); item(file,"Export Binary VSD (Experimental)…",#selector(EditorWindowController.exportVSD(_:)));item(file,"Export Visio Template…",#selector(EditorWindowController.exportTemplate(_:)))
        file.addItem(.separator()); item(file,"Print…",#selector(EditorWindowController.printDiagram(_:)),"p")
        let edit = menu("Edit")
        item(edit,"Undo",Selector(("undo:")),"z"); item(edit,"Redo",Selector(("redo:")),"z",modifiers:[.command,.shift]); edit.addItem(.separator())
        item(edit,"Cut",#selector(NSText.cut(_:)),"x"); item(edit,"Copy",#selector(NSText.copy(_:)),"c"); item(edit,"Paste",#selector(NSText.paste(_:)),"v"); item(edit,"Select All",#selector(NSText.selectAll(_:)),"a")
        edit.addItem(.separator()); item(edit,"Duplicate",#selector(EditorWindowController.duplicateSelection(_:)),"d"); item(edit,"Delete",#selector(EditorWindowController.deleteSelection(_:))); item(edit,"Edit Text…",#selector(EditorWindowController.editText(_:)))
        item(edit,"Find and Replace…",#selector(EditorWindowController.findShapes(_:)),"f")
        item(edit,"Search Commands…",#selector(EditorWindowController.showCommandSearch(_:)),"p",modifiers:[.command,.shift])
        let spelling = NSMenu(title:"Spelling and Grammar"), spellingItem = NSMenuItem(title:"Spelling and Grammar",action:nil,keyEquivalent:"")
        spellingItem.submenu = spelling; edit.addItem(spellingItem)
        item(spelling,"Show Spelling and Grammar",#selector(NSTextView.showGuessPanel(_:)))
        item(spelling,"Check Document Now",#selector(NSTextView.checkSpelling(_:)))
        item(spelling,"Check Spelling While Typing",#selector(NSTextView.toggleContinuousSpellChecking(_:)))
        let shape = menu("Shape")
        item(shape,"Insert Process",#selector(EditorWindowController.insertProcess(_:)))
        item(shape,"Insert Decision",#selector(EditorWindowController.insertDecision(_:)))
        item(shape,"Insert Start / End",#selector(EditorWindowController.insertTerminator(_:)))
        item(shape,"Insert Data",#selector(EditorWindowController.insertData(_:)))
        item(shape,"Insert Subprocess",#selector(EditorWindowController.insertSubprocess(_:)))
        item(shape,"Insert Off-page Link…",#selector(EditorWindowController.chooseOffPageTarget(_:)))
        item(shape,"Preview Align Drawing to Grid…",#selector(EditorWindowController.previewDrawingGrid(_:)))
        let textFormat = NSMenu(title:"Text Format"),textItem = NSMenuItem(title:"Text Format",action:nil,keyEquivalent:"");textItem.submenu = textFormat;shape.addItem(textItem)
        item(textFormat,"Bold",#selector(EditorWindowController.boldText(_:)),"b");item(textFormat,"Italic",#selector(EditorWindowController.italicText(_:)),"i");item(textFormat,"Underline",#selector(EditorWindowController.underlineText(_:)),"u")
        item(textFormat,"Show Fonts…",#selector(NSFontManager.orderFrontFontPanel(_:)),"t",modifiers:[.command,.shift],target:NSFontManager.shared)
        item(shape,"Pointer Tool",#selector(EditorWindowController.pointerTool(_:))); item(shape,"Connector Tool",#selector(EditorWindowController.connectorTool(_:))); item(shape,"Text Tool",#selector(EditorWindowController.textTool(_:)))
        item(shape,"Open Stencil…",#selector(EditorWindowController.openStencil(_:)));item(shape,"Export Selection as Stencil…",#selector(EditorWindowController.exportSelectionStencil(_:))); item(shape,"Line Tool",#selector(EditorWindowController.lineTool(_:))); item(shape,"Insert Image…",#selector(EditorWindowController.insertImage(_:)))
        shape.addItem(.separator()); item(shape,"Group",#selector(EditorWindowController.groupSelection(_:)),"g"); item(shape,"Ungroup",#selector(EditorWindowController.ungroupSelection(_:)),"g",modifiers:[.command,.shift]); item(shape,"Rotate Left",#selector(EditorWindowController.rotateLeft(_:))); item(shape,"Rotate Right",#selector(EditorWindowController.rotateRight(_:))); item(shape,"Flip Horizontal",#selector(EditorWindowController.flipHorizontal(_:))); item(shape,"Flip Vertical",#selector(EditorWindowController.flipVertical(_:)))
        shape.addItem(.separator()); item(shape,"Shape Data…",#selector(EditorWindowController.editShapeData(_:))); item(shape,"Hyperlinks…",#selector(EditorWindowController.editHyperlinks(_:))); item(shape,"Follow Hyperlink",#selector(EditorWindowController.followHyperlink(_:)))
        item(shape,"ShapeSheet…",#selector(EditorWindowController.showShapeSheet(_:)))
        item(shape,"Geometry…",#selector(EditorWindowController.editGeometry(_:)))
        item(shape,"Control Handles…",#selector(EditorWindowController.editControls(_:)))
        item(shape,"Control Cells…",#selector(EditorWindowController.editControlCells(_:)))
        item(shape,"Connection Points…",#selector(EditorWindowController.editConnectionPoints(_:)))
        item(shape,"Insert Text Field…",#selector(EditorWindowController.insertField(_:)));item(shape,"Text Fields…",#selector(EditorWindowController.editTextFields(_:)))
        shape.addItem(.separator()); item(shape,"Align Left",#selector(EditorWindowController.alignLeft(_:))); item(shape,"Align Center",#selector(EditorWindowController.alignCenter(_:))); item(shape,"Align Top",#selector(EditorWindowController.alignTop(_:))); item(shape,"Distribute Horizontally",#selector(EditorWindowController.distributeHorizontal(_:))); item(shape,"Distribute Vertically",#selector(EditorWindowController.distributeVertical(_:)))
        shape.addItem(.separator()); item(shape,"Bring to Front",#selector(EditorWindowController.bringToFront(_:)),"]",modifiers:[.command,.shift]); item(shape,"Send to Back",#selector(EditorWindowController.sendToBack(_:)),"[",modifiers:[.command,.shift]); item(shape,"Lock / Unlock",#selector(EditorWindowController.toggleLock(_:)),"l",modifiers:[.command,.shift])
        let page = menu("Page"); item(page,"Add Page",#selector(EditorWindowController.addPage(_:))); item(page,"Duplicate Page",#selector(EditorWindowController.duplicatePage(_:))); item(page,"Delete Page…",#selector(EditorWindowController.deletePage(_:)))
        item(page,"Page Setup…",#selector(EditorWindowController.showPageSetup(_:))); item(page,"Add Background Page",#selector(EditorWindowController.addBackgroundPage(_:))); item(page,"Edit Background",#selector(EditorWindowController.editBackgroundPage(_:))); item(page,"Match Background Size",#selector(EditorWindowController.matchBackgroundSize(_:))); item(page,"Go to Page…",#selector(EditorWindowController.goToPage(_:)))
        item(page,"Layers…",#selector(EditorWindowController.editLayers(_:)))
        let view = menu("View"); item(view,"Zoom In",#selector(EditorWindowController.zoomIn(_:)),"+"); item(view,"Zoom Out",#selector(EditorWindowController.zoomOut(_:)),"-"); item(view,"Fit Page",#selector(EditorWindowController.fitPage(_:)),"0"); item(view,"Actual Size",#selector(EditorWindowController.actualSize(_:)),"1")
        view.addItem(.separator()); item(view,"Show Grid",#selector(EditorWindowController.toggleGrid(_:))); item(view,"Snap to Grid",#selector(EditorWindowController.toggleSnap(_:)))
        let drawingWindows = NSMenuItem(title:"Switch Windows",action:nil,keyEquivalent:"");drawingWindows.submenu = workflow.makeSwitchMenu();view.addItem(drawingWindows)
        let window = menu("Window"); item(window,"Minimize",#selector(NSWindow.performMiniaturize(_:)),"m"); item(window,"Zoom",#selector(NSWindow.performZoom(_:))); window.addItem(.separator())
        item(window,"Next Drawing",#selector(DocumentWorkflow.nextDrawing(_:)),"\t",modifiers:[.control],target:workflow);item(window,"Previous Drawing",#selector(DocumentWorkflow.previousDrawing(_:)),"\t",modifiers:[.control,.shift],target:workflow)
        item(window,"Next Drawing",#selector(DocumentWorkflow.nextDrawing(_:)),String(UnicodeScalar(NSF6FunctionKey)!),modifiers:[.control],target:workflow);window.items.last?.isAlternate = true
        item(window,"Previous Drawing",#selector(DocumentWorkflow.previousDrawing(_:)),String(UnicodeScalar(NSF6FunctionKey)!),modifiers:[.control,.shift],target:workflow);window.items.last?.isAlternate = true
        item(window,"Bring All to Front",#selector(NSApplication.arrangeInFront(_:)),target:NSApp); NSApp.windowsMenu = window
        item(view,"Shapes Library",#selector(EditorWindowController.toggleShapeLibrary(_:)))
        item(view,"Drawing Issues…",#selector(EditorWindowController.showDocumentIssues(_:)))
        item(view,"Check Drawing Content…",#selector(EditorWindowController.checkDrawingContent(_:)))
        item(file,"Export Redacted Support Report…",#selector(EditorWindowController.exportRedactedSupportReport(_:)))
        let help = menu("Help"); item(help,"MacVisio Help",#selector(showHelp(_:)),"?",target:self); item(help,"Visio Compatibility",#selector(showCompatibility(_:)),target:self); NSApp.helpMenu = help
    }
}

if CommandLine.arguments.contains("--launch-check") {
    // Process-local argument preferences isolate diagnostics from the user's saved
    // windows. They do not alter the app's persistent preferences or normal restore.
    var arguments = UserDefaults.standard.volatileDomain(forName:UserDefaults.argumentDomain)
    arguments["ApplePersistenceIgnoreState"] = true;arguments["NSQuitAlwaysKeepsWindows"] = false
    UserDefaults.standard.setVolatileDomain(arguments,forName:UserDefaults.argumentDomain)
}
if let index = CommandLine.arguments.firstIndex(of:"--appearance"),CommandLine.arguments.indices.contains(index+1),
   ["dark","light","system"].contains(CommandLine.arguments[index+1]) {
    var arguments = UserDefaults.standard.volatileDomain(forName:UserDefaults.argumentDomain)
    arguments[EditorAppearance.preferenceKey] = CommandLine.arguments[index+1]
    UserDefaults.standard.setVolatileDomain(arguments,forName:UserDefaults.argumentDomain)
}
let application = NSApplication.shared
application.setActivationPolicy(.regular)
EditorAppearance.apply()
try DeveloperCommands.dispatch()

let delegate = AppDelegate()
application.delegate = delegate
application.run()
