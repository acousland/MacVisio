import AppKit
import UniformTypeIdentifiers

/// Owns document navigation; Home is not a document and never owns drawing data.
final class DocumentWorkflow:NSObject,NSMenuDelegate {
    unowned let delegate:AppDelegate
    let recentStore:RecentDrawingStore
    private let recordsSystemRecents:Bool
    private(set) var welcome:WelcomeWindowController?
    private weak var lastDrawing:MacVisioDocument?
    private var started = false
    var isTerminating = false
    private var closingAll = false
    init(delegate:AppDelegate,recentStore:RecentDrawingStore = RecentDrawingStore(),recordsSystemRecents:Bool = true) { self.delegate = delegate;self.recentStore = recentStore;self.recordsSystemRecents = recordsSystemRecents }
    /// Explicit-open identity resolves symlink aliases without changing how
    /// history entries are displayed or reading drawing contents on Home.
    static func canonicalDrawingURL(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    var drawings:[MacVisioDocument] { NSDocumentController.shared.documents.compactMap{$0 as? MacVisioDocument} }
    var activeDrawing:MacVisioDocument? {
        if let editor = NSApp.keyWindow?.windowController as? EditorWindowController { return editor.diagramDocument }
        if let lastDrawing,drawings.contains(where:{$0 === lastDrawing}) { return lastDrawing }
        return drawings.last
    }
    var recents:[RecentDrawing] { recentStore.entries(including:recordsSystemRecents ? NSDocumentController.shared.recentDocumentURLs : []) }
    func start(showHome:Bool = false) {
        started = true
        for document in drawings { document.documentWorkflow = self }
        if drawings.isEmpty || showHome { showWelcome() }
    }
    func showWelcome(_ section:WelcomeSection = .home) {
        activeDrawing?.commitTextEditing()
        if welcome == nil {
            welcome = WelcomeWindowController(onNew:{[weak self] in self?.delegate.newDiagram(template:$0)},onOpen:{[weak self] in self?.delegate.browseDocuments(nil)},onRecent:{[weak self] in self?.openRecentDrawing($0)},onPin:{[weak self] url in
                self?.recentStore.togglePin(url);self?.refreshWelcome()
            },onBack:{[weak self] in self?.backToDrawing()},onSave:{[weak self] in self?.saveDrawing(asNew:false)},onSaveAs:{[weak self] in self?.saveDrawing(asNew:true)},onClose:{[weak self] in self?.closeDrawing()},onLocate:{[weak self] in self?.locateRecentDrawing($0)},onRemove:{[weak self] in self?.removeRecentDrawing($0)})
        }
        welcome?.refresh(recents:recents,section:section,canGoBack:activeDrawing != nil);welcome?.showWindow(nil);welcome?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }
    func refreshWelcome() { welcome?.refresh(recents:recents,canGoBack:activeDrawing != nil) }
    func documentOpened(_ document:MacVisioDocument,sourceURL:URL? = nil) {
        document.documentWorkflow = self
        lastDrawing = document
        if let sourceURL { noteRecent(sourceURL) }
        welcome?.window?.orderOut(nil)
    }
    func noteRecent(_ url:URL) {
        guard url.isFileURL else { return }
        recentStore.record(url)
        if recordsSystemRecents { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
        refreshWelcome()
    }
    func documentActivated(_ document:MacVisioDocument) { lastDrawing = document }
    func documentClosed(_ document:MacVisioDocument) {
        if lastDrawing === document { lastDrawing = nil }
        DispatchQueue.main.async { [weak self] in
            guard let self,self.started,!self.isTerminating,!self.closingAll else { return }
            if self.drawings.isEmpty { self.showWelcome() } else { self.refreshWelcome() }
        }
    }
    func activate(_ document:MacVisioDocument) {
        guard drawings.contains(where:{$0 === document}) else { return }
        lastDrawing = document;welcome?.window?.orderOut(nil)
        for controller in document.windowControllers where controller.window?.isMiniaturized == true { controller.window?.deminiaturize(nil) }
        document.showWindows()
    }
    func backToDrawing() { if let activeDrawing { activate(activeDrawing) } }
    func switchDrawing(forward:Bool) {
        let documents = drawings
        guard !documents.isEmpty else { showWelcome();return }
        let index = activeDrawing.flatMap{active in documents.firstIndex{$0 === active}} ?? (forward ? documents.count-1 : 0)
        activate(documents[(index+(forward ? 1 : documents.count-1))%documents.count])
    }
    @objc func nextDrawing(_ sender:Any?) { switchDrawing(forward:true) }
    @objc func previousDrawing(_ sender:Any?) { switchDrawing(forward:false) }
    @objc func showHome(_ sender:Any?) { showWelcome() }
    @objc func showNew(_ sender:Any?) { showWelcome(.new) }
    @objc func showOpen(_ sender:Any?) { showWelcome(.open) }
    private func saveDrawing(asNew:Bool) {
        guard let document = activeDrawing else { return }
        activate(document)
        if asNew { document.saveAs(nil) } else { document.save(nil) }
    }
    private func closeDrawing() {
        guard let document = activeDrawing else { return }
        activate(document);document.windowControllers.first?.window?.performClose(nil)
    }
    @objc func closeAllDrawings(_ sender:Any?) {
        guard !drawings.isEmpty else { showWelcome();return }
        closingAll = true
        NSDocumentController.shared.closeAllDocuments(withDelegate:self,didCloseAllSelector:#selector(finishedClosingAll(_:didCloseAll:contextInfo:)),contextInfo:nil)
    }
    @objc private func finishedClosingAll(_ controller:NSDocumentController,didCloseAll:Bool,contextInfo:UnsafeMutableRawPointer?) {
        closingAll = false
        if drawings.isEmpty { showWelcome() } else { refreshWelcome() }
    }
    func makeSwitchMenu() -> NSMenu {
        let menu = NSMenu(title:"Switch Windows");menu.delegate = self;rebuildSwitchMenu(menu);return menu
    }
    func makeRecentMenu() -> NSMenu {
        let menu = NSMenu(title:"Open Recent");menu.delegate = self;rebuildRecentMenu(menu);return menu
    }
    func menuNeedsUpdate(_ menu:NSMenu) {
        if menu.title == "Switch Windows" { rebuildSwitchMenu(menu) }
        if menu.title == "Open Recent" { rebuildRecentMenu(menu) }
    }
    private func rebuildSwitchMenu(_ menu:NSMenu) {
        menu.removeAllItems()
        let documents = drawings
        for document in documents {
            let duplicate = documents.filter{$0.displayName == document.displayName}.count > 1
            let title = document.displayName+(duplicate ? " — "+(document.fileURL?.deletingLastPathComponent().lastPathComponent ?? "Unsaved drawing") : "")
            let item = NSMenuItem(title:title,action:#selector(switchFromMenu(_:)),keyEquivalent:"")
            item.target = self;item.representedObject = DrawingMenuReference(document);item.state = document === activeDrawing ? .on : .off;item.toolTip = document.fileURL?.path;menu.addItem(item)
        }
        if documents.isEmpty { let item = NSMenuItem(title:"No open drawings",action:nil,keyEquivalent:"");item.isEnabled = false;menu.addItem(item) }
    }
    private func rebuildRecentMenu(_ menu:NSMenu) {
        menu.removeAllItems()
        for entry in recents {
            let item = NSMenuItem(title:(entry.isPinned ? "★ " : "")+entry.title,action:#selector(openRecent(_:)),keyEquivalent:"")
            item.target = self;item.representedObject = entry.url;item.toolTip = entry.url.path;menu.addItem(item)
        }
        if menu.items.isEmpty { let item = NSMenuItem(title:"No recent drawings",action:nil,keyEquivalent:"");item.isEnabled = false;menu.addItem(item) }
        menu.addItem(.separator())
        let clear = NSMenuItem(title:"Clear Recent History",action:#selector(clearRecentHistory(_:)),keyEquivalent:"");clear.target = self;menu.addItem(clear)
    }
    @objc private func switchFromMenu(_ sender:NSMenuItem) { if let document = (sender.representedObject as? DrawingMenuReference)?.document { activate(document) } }
    @objc private func openRecent(_ sender:NSMenuItem) { if let url = sender.representedObject as? URL { openRecentDrawing(url) } }
    func removeRecentDrawing(_ url: URL) {
        recentStore.remove(url); refreshWelcome()
    }
    func locateRecentDrawing(_ oldURL: URL) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "Locate Drawing"; panel.message = "Select the drawing's new location. This updates its recent entry and opens it."
        panel.allowedContentTypes = ["macvisio", "vsdx", "vstx", "vsd", "vst"].compactMap { UTType(filenameExtension: $0) }
        panel.nameFieldStringValue = oldURL.lastPathComponent
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.recentStore.relocate(oldURL, to: url); self.refreshWelcome(); self.delegate.open(url)
        }
        if let window = welcome?.window, window.isVisible { panel.beginSheetModal(for: window, completionHandler: finish) }
        else { panel.begin(completionHandler: finish) }
    }
    func openRecentDrawing(_ url: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { delegate.open(url); return }
        let alert = NSAlert(); alert.messageText = "This drawing could not be found."
        alert.informativeText = "Locate it if it moved, or remove its recent entry. Removing an entry does not delete a file."
        alert.addButton(withTitle: "Locate…"); alert.addButton(withTitle: "Remove from Recents"); alert.addButton(withTitle: "Cancel")
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            if response == .alertFirstButtonReturn { self?.locateRecentDrawing(url) }
            else if response == .alertSecondButtonReturn { self?.removeRecentDrawing(url) }
        }
        if let window = welcome?.window, window.isVisible { alert.beginSheetModal(for: window, completionHandler: finish) }
        else if let window = NSApp.keyWindow { alert.beginSheetModal(for: window, completionHandler: finish) }
        else { finish(alert.runModal()) }
    }
    @objc func clearRecentHistory(_ sender:Any?) {
        recentStore.clearHistory()
        if recordsSystemRecents { NSDocumentController.shared.clearRecentDocuments(sender) }
        refreshWelcome()
    }
}
private final class DrawingMenuReference {
    weak var document:MacVisioDocument?
    init(_ document:MacVisioDocument) { self.document = document }
}
