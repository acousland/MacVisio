import AppKit
import UniformTypeIdentifiers
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let updates = AppUpdates()
    private var openedAtLaunch = false
    private weak var diagnosticDocument:MacVisioDocument?
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
            else if NSDocumentController.shared.documents.isEmpty && !self.openedAtLaunch { self.newDiagram(template:.flowchart) }
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
        NSDocumentController.shared.addDocument(doc); doc.makeWindowControllers(); doc.showWindows()
        return doc
    }
    @objc func newDocument(_ sender:Any?) { newDiagram(template:.blank) }
    @objc func newFlowchart(_ sender:Any?) { newDiagram(template:.flowchart) }
    @objc func newOrganization(_ sender:Any?) { newDiagram(template:.organization) }
    @objc func newNetwork(_ sender:Any?) { newDiagram(template:.network) }
    @objc func newSwimlane(_ sender:Any?) { newDiagram(template:.swimlane) }
    @objc func openDocument(_ sender:Any?) {
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
        do {
            let entries = try VisioLibrary.entries(in:directory)
            guard !entries.isEmpty else { throw DiagramError.invalid("This folder has no supported Visio stencils or templates.") }
            defaults.set(directory.path,forKey:key)
            if let chosen = VisioLibraryPicker(entries:entries).run() { open(chosen.url) }
        } catch { NSApp.presentError(error) }
    }
    @objc func chooseVisioLibraryFolder(_ sender:Any?) {
        let panel = NSOpenPanel();panel.canChooseFiles = false;panel.canChooseDirectories = true;panel.prompt = "Choose Library Folder"
        guard panel.runModal() == .OK,let url = panel.url else { return }
        do { guard !(try VisioLibrary.entries(in:url)).isEmpty else { throw DiagramError.invalid("This folder has no supported Visio stencils or templates.") };UserDefaults.standard.set(url.path,forKey:"MacVisioLibraryDirectory");openVisioLibrary(sender) } catch { NSApp.presentError(error) }
    }
    func open(_ url:URL) {
        if let existing = NSDocumentController.shared.documents.first(where:{$0.fileURL == url}) { existing.showWindows(); return }
        do {
            let ext = url.pathExtension.lowercased()
            if ext == "vssx" || ext == "vss" {
                if NSDocumentController.shared.documents.isEmpty { newDiagram(template:.blank) }
                let editor = (NSApp.keyWindow?.windowController as? EditorWindowController) ?? NSDocumentController.shared.documents.compactMap{$0.windowControllers.first as? EditorWindowController}.last
                editor?.showWindow(nil);editor?.loadStencil(url);return
            }
            let type = (ext == "vsdx" || ext == "vstx") ? MacVisioDocument.visioType : (ext == "vsd" || ext == "vst") ? MacVisioDocument.legacyType : MacVisioDocument.nativeType
            let doc = try MacVisioDocument(contentsOf:url,ofType:type)
            let asNew = ext == "vstx" || ext == "vst" || ext == "vsd" && !doc.legacyNative
            doc.fileURL = asNew ? nil : url; doc.fileType = asNew ? MacVisioDocument.visioType : type
            if asNew { doc.updateChangeCount(.changeDone) }
            NSDocumentController.shared.addDocument(doc); doc.makeWindowControllers(); doc.showWindows()
        } catch { NSApp.presentError(error) }
    }
    func application(_ sender:NSApplication,openFiles filenames:[String]) {
        // Diagnostic arguments include paths which AppKit may also deliver as
        // opening events at launch. The diagnostic opens its input explicitly.
        if CommandLine.arguments.contains("--open-check") { sender.reply(toOpenOrPrint:.success);return }
        openedAtLaunch = true; for name in filenames { open(URL(fileURLWithPath:name)) }; sender.reply(toOpenOrPrint:.success)
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool) -> Bool { if !flag { newDiagram(template:.blank) }; return true }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        for document in NSDocumentController.shared.documents { (document as? MacVisioDocument)?.commitTextEditing() }
        guard NSDocumentController.shared.documents.contains(where:{$0.isDocumentEdited}) else { return .terminateNow }
        NSDocumentController.shared.closeAllDocuments(withDelegate:self,didCloseAllSelector:#selector(documentsClosed(_:didCloseAll:contextInfo:)),contextInfo:nil)
        return .terminateLater
    }
    @objc func documentsClosed(_ controller:NSDocumentController,didCloseAll:Bool,contextInfo:UnsafeMutableRawPointer?) { NSApp.reply(toApplicationShouldTerminate:didCloseAll) }
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
        item(file,"New Diagram",#selector(newDocument(_:)),"n",target:self)
        let examples = NSMenuItem(title:"New from Template",action:nil,keyEquivalent:""); let ex = NSMenu(title:"New from Template"); examples.submenu = ex; file.addItem(examples)
        item(ex,"Flowchart",#selector(newFlowchart(_:)),target:self); item(ex,"Organization Chart",#selector(newOrganization(_:)),target:self); item(ex,"Network",#selector(newNetwork(_:)),target:self); item(ex,"Swimlanes",#selector(newSwimlane(_:)),target:self)
        item(file,"Open…",#selector(openDocument(_:)),"o",target:self)
        file.addItem(.separator()); item(file,"Close",#selector(NSWindow.performClose(_:)),"w"); item(file,"Save…",#selector(NSDocument.save(_:)),"s"); item(file,"Save As…",#selector(NSDocument.saveAs(_:)),"s",modifiers:[.command,.shift]); item(file,"Revert to Saved…",#selector(NSDocument.revertToSaved(_:)))
        item(file,"Visio Libraries…",#selector(openVisioLibrary(_:)),target:self);item(file,"Choose Visio Library Folder…",#selector(chooseVisioLibraryFolder(_:)),target:self)
        file.addItem(.separator()); item(file,"Export PDF…",#selector(EditorWindowController.exportPDF(_:))); item(file,"Export All Pages to PDF…",#selector(EditorWindowController.exportAllPagesPDF(_:))); item(file,"Export PNG…",#selector(EditorWindowController.exportPNG(_:))); item(file,"Export SVG…",#selector(EditorWindowController.exportSVG(_:))); item(file,"Export VSDX Drawing…",#selector(EditorWindowController.exportVSDX(_:))); item(file,"Export Binary VSD (Experimental)…",#selector(EditorWindowController.exportVSD(_:)));item(file,"Export Visio Template…",#selector(EditorWindowController.exportTemplate(_:)))
        file.addItem(.separator()); item(file,"Print…",#selector(EditorWindowController.printDiagram(_:)),"p")
        let edit = menu("Edit")
        item(edit,"Undo",Selector(("undo:")),"z"); item(edit,"Redo",Selector(("redo:")),"z",modifiers:[.command,.shift]); edit.addItem(.separator())
        item(edit,"Cut",#selector(NSText.cut(_:)),"x"); item(edit,"Copy",#selector(NSText.copy(_:)),"c"); item(edit,"Paste",#selector(NSText.paste(_:)),"v"); item(edit,"Select All",#selector(NSText.selectAll(_:)),"a")
        edit.addItem(.separator()); item(edit,"Duplicate",#selector(EditorWindowController.duplicateSelection(_:)),"d"); item(edit,"Delete",#selector(EditorWindowController.deleteSelection(_:))); item(edit,"Edit Text…",#selector(EditorWindowController.editText(_:)))
        item(edit,"Find Shapes…",#selector(EditorWindowController.findShapes(_:)),"f")
        let shape = menu("Shape")
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
        let window = menu("Window"); item(window,"Minimize",#selector(NSWindow.performMiniaturize(_:)),"m"); item(window,"Zoom",#selector(NSWindow.performZoom(_:))); window.addItem(.separator()); item(window,"Bring All to Front",#selector(NSApplication.arrangeInFront(_:)),target:NSApp); NSApp.windowsMenu = window
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
if let index = CommandLine.arguments.firstIndex(of:"--prepare-interchange-fixtures"),CommandLine.arguments.indices.contains(index+1) {
    do { try InterchangeFixtures.generate(in:URL(fileURLWithPath:CommandLine.arguments[index+1]));print("Generated synthetic public-content interchange fixtures");exit(0) }
    catch { fputs("Interchange fixture generation failed: \(error.localizedDescription)\n",stderr);exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of:"--inspect-calculation"),CommandLine.arguments.indices.contains(index+2) {
    do { try CalculationAudit.inspect(URL(fileURLWithPath:CommandLine.arguments[index+1]),to:URL(fileURLWithPath:CommandLine.arguments[index+2]));exit(0) }
    catch { fputs("Calculation inspection failed: \(error.localizedDescription)\n",stderr);exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of:"--inspect-geometry"),CommandLine.arguments.indices.contains(index+2) {
    do { try GeometryAudit.inspect(URL(fileURLWithPath:CommandLine.arguments[index+1]),to:URL(fileURLWithPath:CommandLine.arguments[index+2]));exit(0) }
    catch { fputs("Geometry inspection failed: \(error.localizedDescription)\n",stderr);exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of:"--generate-curve-example"),CommandLine.arguments.indices.contains(index+1) {
    do { try CurveExample.generate(in:URL(fileURLWithPath:CommandLine.arguments[index+1]));print("Generated curve example");exit(0) }
    catch { fputs("Curve example failed: \(error.localizedDescription)\n",stderr);exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of:"--generate-curve-library-example"),CommandLine.arguments.indices.contains(index+2) {
    do { try CurveExample.generateLibrary(from:URL(fileURLWithPath:CommandLine.arguments[index+1]),in:URL(fileURLWithPath:CommandLine.arguments[index+2]));print("Generated installer curve example");exit(0) }
    catch { fputs("Installer curve example failed: \(error.localizedDescription)\n",stderr);exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of:"--generate-text-context-example"),CommandLine.arguments.indices.contains(index+1) {
    do { try TextContextExample.generate(in:URL(fileURLWithPath:CommandLine.arguments[index+1]));print("Generated text-context example");exit(0) }
    catch { fputs("Text-context example failed: \(error.localizedDescription)\n",stderr);exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of:"--generate-control-example"),CommandLine.arguments.indices.contains(index+1) {
    do { try ControlExample.generate(in:URL(fileURLWithPath:CommandLine.arguments[index+1]));print("Generated control-handle example");exit(0) }
    catch { fputs("Control example failed: \(error.localizedDescription)\n",stderr);exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of:"--generate-geometry-example"),CommandLine.arguments.indices.contains(index+1) {
    do { try GeometryExample.generate(in:URL(fileURLWithPath:CommandLine.arguments[index+1]));print("Generated geometry example");exit(0) }
    catch { fputs("Geometry example failed: \(error.localizedDescription)\n",stderr);exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of:"--generate-field-example"),CommandLine.arguments.indices.contains(index+1) {
    do { try FieldExample.generate(in:URL(fileURLWithPath:CommandLine.arguments[index+1]));print("Generated field example");exit(0) }
    catch { fputs("Field example failed: \(error.localizedDescription)\n",stderr);exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of:"--generate-rich-text-example"),CommandLine.arguments.indices.contains(index+1) {
    do { try RichTextExample.generate(in:URL(fileURLWithPath:CommandLine.arguments[index+1]));print("Generated rich text example");exit(0) }
    catch { fputs("Rich text example failed: \(error.localizedDescription)\n",stderr);exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of:"--generate-engineering-example"),CommandLine.arguments.indices.contains(index+2) {
    do { try EngineeringExample.generate(library:URL(fileURLWithPath:CommandLine.arguments[index+1]),in:URL(fileURLWithPath:CommandLine.arguments[index+2]));print("Generated engineering example");exit(0) }
    catch { fputs("Engineering example failed: \(error.localizedDescription)\n",stderr);exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of:"--generate-library-example"),CommandLine.arguments.indices.contains(index+2) {
    do { try LibraryExample.generate(from:URL(fileURLWithPath:CommandLine.arguments[index+1]),in:URL(fileURLWithPath:CommandLine.arguments[index+2]));print("Generated installer library example");exit(0) }
    catch { fputs("Library example failed: \(error.localizedDescription)\n",stderr);exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of:"--inspect-libraries"),CommandLine.arguments.indices.contains(index+2) {
    do {
        let entries = try VisioLibrary.entries(in:URL(fileURLWithPath:CommandLine.arguments[index+1]))
        var results:[[String:Any]] = []
        for entry in entries {
            autoreleasepool {
                do {
                    if entry.isStencil { let imported = try VisioStencil.read(from:entry.url);results.append(["file":entry.url.lastPathComponent,"masters":imported.items.count,"shapes":imported.items.reduce(0){$0+$1.fragment.nodes.count},"controls":imported.items.reduce(0){$0+$1.fragment.nodes.reduce(0){$0+$1.formatting.controls.count}},"warnings":imported.warnings,"imported":true]) }
                    else { let doc = MacVisioDocument();try doc.read(from:entry.url,ofType:["vst"].contains(entry.url.pathExtension.lowercased()) ? MacVisioDocument.legacyType : MacVisioDocument.visioType);results.append(["file":entry.url.lastPathComponent,"pages":doc.diagram.pages.count,"shapes":doc.diagram.pages.reduce(0){$0+$1.nodes.count},"controls":doc.diagram.pages.reduce(0){$0+$1.nodes.reduce(0){$0+$1.formatting.controls.count}},"warnings":doc.importWarnings,"imported":true]) }
                } catch { results.append(["file":entry.url.lastPathComponent,"imported":false,"error":error.localizedDescription]) }
            }
        }
        let failed = results.filter{$0["imported"] as? Bool != true}.count
        let report:[String:Any] = ["files":results,"count":results.count,"failed":failed,"windowsValidated":false,"fullBehavioralParity":false]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[index+2]),options:.atomic)
        print("Imported \(results.count-failed)/\(results.count) libraries; \(failed) failed.");exit(failed == 0 ? 0 : 1)
    } catch { fputs("Library inspection failed: \(error.localizedDescription)\n",stderr);exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of:"--profile-open"),CommandLine.arguments.indices.contains(index+2) {
    do { try OpenPerformance.profile(URL(fileURLWithPath:CommandLine.arguments[index+1]),to:URL(fileURLWithPath:CommandLine.arguments[index+2]));exit(0) }
    catch { fputs("Open profiling failed: \(error.localizedDescription)\n",stderr);exit(1) }
}
if let index = CommandLine.arguments.firstIndex(where:{$0 == "--convert" || $0 == "--render-document" || $0 == "--export-all-pdf"}),CommandLine.arguments.indices.contains(index+2) {
    do {
        let input = URL(fileURLWithPath:CommandLine.arguments[index+1]),output = URL(fileURLWithPath:CommandLine.arguments[index+2])
        let doc = MacVisioDocument();try doc.read(from:input,ofType:["vsd","vst"].contains(input.pathExtension.lowercased()) ? MacVisioDocument.legacyType : input.pathExtension.lowercased() == "macvisio" ? MacVisioDocument.nativeType : MacVisioDocument.visioType)
        if CommandLine.arguments[index] == "--export-all-pdf" {
            guard output.pathExtension.lowercased() == "pdf" else { throw DiagramError.invalid("All-page export must produce a PDF file.") };try DiagramExport.pdf(doc.diagram).write(to:output,options:.atomic)
        } else if CommandLine.arguments[index] == "--convert" {
            switch output.pathExtension.lowercased() { case "vsdx":try VisioFormat.write(doc.diagram,to:output);case "vsd":try VSDBinaryFormat.write(doc.diagram,to:output);case "vstx":try VisioReusableFormat.writeTemplate(doc.diagram,to:output);default:throw DiagramError.invalid("Conversion output must be a .vsdx drawing, .vsd drawing or .vstx template.") }
        } else {
            switch output.pathExtension.lowercased() {
            case "png":try DiagramExport.png(doc.diagram.scene(),scale:1).write(to:output,options:.atomic)
            case "pdf":try DiagramExport.pdf(doc.diagram.scene()).write(to:output,options:.atomic)
            case "svg":try DiagramDrawing.svg(doc.diagram.scene()).write(to:output,atomically:true,encoding:.utf8)
            default:throw DiagramError.invalid("Rendering output must be PNG, PDF or SVG.")
            }
        }
        for warning in doc.importWarnings { fputs("\(warning)\n",stderr) };print("Wrote \(output.path)");exit(0)
    } catch { fputs("Document processing failed: \(error.localizedDescription)\n",stderr);exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of:"--render-ui"),CommandLine.arguments.indices.contains(index+1) {
    let doc = MacVisioDocument(); doc.diagram = CommandLine.arguments.contains("--page-example") ? PageExample.make() : DiagramTemplate.flowchart.makeDiagram(); doc.makeWindowControllers()
    if let controller = doc.windowControllers.first as? EditorWindowController,let view = controller.window?.contentView {
        if CommandLine.arguments.contains("--compact-ui") { controller.window?.setContentSize(CGSize(width:1000,height:680)) }
        if let tab = CommandLine.arguments.firstIndex(of:"--ribbon-tab"),CommandLine.arguments.indices.contains(tab+1) {
            controller.root.ribbon.selectTab(CommandLine.arguments[tab+1])
        }
        view.layoutSubtreeIfNeeded(); controller.canvas.fitPage(); view.layoutSubtreeIfNeeded()
        if let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
            view.cacheDisplay(in:view.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]))
            print("Rendered native editor to \(CommandLine.arguments[index+1])")
            exit(0)
        }
    }
    fputs("Could not render native editor\n",stderr); exit(1)
}
if let index = CommandLine.arguments.firstIndex(of:"--generate-page-example"),CommandLine.arguments.indices.contains(index+1) {
    do {
        let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let diagram = try PageExample.make().validated()
        try JSONEncoder().encode(diagram).write(to:directory.appendingPathComponent("shared-pages.macvisio"),options:.atomic)
        try VisioFormat.write(diagram,to:directory.appendingPathComponent("shared-pages.vsdx"));try VSDBinaryFormat.write(diagram,to:directory.appendingPathComponent("shared-pages.vsd"))
        try DiagramExport.pdf(diagram).write(to:directory.appendingPathComponent("shared-pages.pdf"),options:.atomic)
        for page in diagram.pages where page.isBackground != true {
            let stem = page.name.replacingOccurrences(of:" ",with:"-").lowercased()
            try DiagramExport.png(diagram.scene(for:page.id),scale:1).write(to:directory.appendingPathComponent(stem+".png"),options:.atomic)
            try DiagramDrawing.svg(diagram.scene(for:page.id)).write(to:directory.appendingPathComponent(stem+".svg"),atomically:true,encoding:.utf8)
        }
        print("Generated shared-background example in \(directory.path)");exit(0)
    } catch { fputs("Page example generation failed: \(error.localizedDescription)\n",stderr);exit(1) }
}
if let index = CommandLine.arguments.firstIndex(of:"--generate-examples"),CommandLine.arguments.indices.contains(index+1) {
    do {
        let directory = URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        for template in DiagramTemplate.allCases {
            let diagram = template.makeDiagram()
            try encoder.encode(diagram.validated()).write(to:directory.appendingPathComponent(template.rawValue+".macvisio"),options:.atomic)
            try VisioFormat.write(diagram,to:directory.appendingPathComponent(template.rawValue+".vsdx"))
            try VSDBinaryFormat.write(diagram,to:directory.appendingPathComponent(template.rawValue+".vsd"))
            try DiagramExport.pdf(diagram.page).write(to:directory.appendingPathComponent(template.rawValue+".pdf"),options:.atomic)
            try DiagramDrawing.svg(diagram.page).write(to:directory.appendingPathComponent(template.rawValue+".svg"),atomically:true,encoding:.utf8)
            try DiagramExport.png(diagram.page).write(to:directory.appendingPathComponent(template.rawValue+".png"),options:.atomic)
        }
        print("Generated five examples in \(directory.path)")
        exit(0)
    } catch { fputs("Example generation failed: \(error.localizedDescription)\n",stderr); exit(1) }
}
let delegate = AppDelegate()
application.delegate = delegate
application.run()
