import MacVisioInfrastructure
import AppKit

struct VisioLibraryEntry:Equatable {
    let url:URL
    var name:String { url.deletingPathExtension().lastPathComponent }
    var isStencil:Bool { ["vss","vssx"].contains(url.pathExtension.lowercased()) }
    var type:String { isStencil ? "Stencil" : "Template" }
}
enum VisioLibrary {
    static func entries(in directory:URL) throws -> [VisioLibraryEntry] {
        try LifecycleJobContext.current?.checkpoint()
        let keys:Set<URLResourceKey> = [.isRegularFileKey,.isSymbolicLinkKey]
        let urls = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:Array(keys),options:[.skipsHiddenFiles])
        guard urls.count <= 10000 else { throw DiagramError.invalid("This folder contains too many files to browse.") }
        return try urls.filter { url in
            try LifecycleJobContext.current?.checkpoint()
            guard ["vss","vssx","vst","vstx"].contains(url.pathExtension.lowercased()) else { return false }
            let values = try url.resourceValues(forKeys:keys)
            return values.isRegularFile == true && values.isSymbolicLink != true
        }.map {
            try LifecycleJobContext.current?.checkpoint()
            return VisioLibraryEntry(url:$0.standardizedFileURL.resolvingSymlinksInPath())
        }.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}
    }
    /// Resolve additional pinned files in the existing library worker, including
    /// metadata checks when a formerly pinned path becomes a symlink or disappears.
    static func includingPinned(_ pinned:[URL],in entries:[VisioLibraryEntry]) throws -> [VisioLibraryEntry] {
        var result = entries,seen = Set<URL>()
        for entry in entries {
            try LifecycleJobContext.current?.checkpoint()
            seen.insert(entry.url.standardizedFileURL.resolvingSymlinksInPath())
        }
        for url in pinned.prefix(256) {
            try LifecycleJobContext.current?.checkpoint()
            guard url.isFileURL,["vss","vssx","vst","vstx"].contains(url.pathExtension.lowercased()),
                  let resource = try? url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey]),
                  resource.isRegularFile == true,resource.isSymbolicLink != true else { continue }
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            guard seen.insert(canonical).inserted else { continue }
            result.append(VisioLibraryEntry(url:canonical))
        }
        return result
    }
    static func filter(_ entries:[VisioLibraryEntry],query:String) -> [VisioLibraryEntry] {
        let words = query.split(whereSeparator:{$0.isWhitespace}).map(String.init)
        return entries.filter { entry in words.allSatisfy{(entry.name+" "+entry.type).localizedCaseInsensitiveContains($0)} }
    }
}

final class VisioLibraryPicker:FlippedView,NSTableViewDataSource,NSTableViewDelegate,NSSearchFieldDelegate {
    let entries:[VisioLibraryEntry]
    var filtered:[VisioLibraryEntry]
    let table = NSTableView(),search = NSSearchField()
    let pinButton = NSButton(title:"Pin",target:nil,action:nil)
    let pinnedOnly = NSButton(checkboxWithTitle:"Pinned only",target:nil,action:nil)
    private let pins:LibraryPins
    private var observer:NSObjectProtocol?
    private var hasMarkedText:Bool { (search.currentEditor() as? NSTextView)?.hasMarkedText() == true }
    var selected:VisioLibraryEntry? { filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow] : nil }
    init(entries:[VisioLibraryEntry],pins:LibraryPins = .shared) {
        self.entries = entries;filtered = entries;self.pins = pins
        super.init(frame:CGRect(x:0,y:0,width:620,height:380))
        search.placeholderString = "Search library filenames or type";search.delegate = self;search.frame = CGRect(x:0,y:0,width:420,height:28);addSubview(search)
        pinButton.frame = CGRect(x:430,y:0,width:75,height:28);pinButton.target = self;pinButton.action = #selector(toggleSelectedPin(_:));pinButton.setAccessibilityLabel("Pin selected library");addSubview(pinButton)
        pinnedOnly.frame = CGRect(x:512,y:0,width:108,height:28);pinnedOnly.target = self;pinnedOnly.action = #selector(filterPins(_:));addSubview(pinnedOnly)
        let scroll = NSScrollView(frame:CGRect(x:0,y:38,width:620,height:342));scroll.hasVerticalScroller = true;scroll.borderType = .bezelBorder;scroll.documentView = table;addSubview(scroll)
        for (name,title,width) in [("name","Library",480.0),("type","Type",110.0)] { let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier(name));column.title = title;column.width = width;table.addTableColumn(column) }
        table.delegate = self;table.dataSource = self;table.rowHeight = 26;table.usesAlternatingRowBackgroundColors = true;table.target = self;table.doubleAction = #selector(openSelected(_:))
        table.setAccessibilityLabel("Visio libraries");search.setAccessibilityLabel("Search Visio libraries")
        observer = NotificationCenter.default.addObserver(forName:LibraryPins.didChange,object:pins,queue:.main){[weak self] _ in self?.refresh()}
        refresh()

    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func numberOfRows(in tableView:NSTableView) -> Int { filtered.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int) -> NSView? {
        let entry = filtered[row],label = NSTextField(labelWithString:tableColumn?.identifier.rawValue == "type" ? entry.type : entry.name)
        label.font = .systemFont(ofSize:12);label.textColor = .labelColor;label.toolTip = entry.url.path
        label.setAccessibilityLabel(entry.name+", "+entry.type+", "+entry.url.path);return label
    }
    func controlTextDidChange(_ notification:Notification) { if !hasMarkedText { refresh() } }
    func refresh() {
        guard !hasMarkedText else { return }
        let old = selected,state = pins.snapshot
        filtered = VisioLibrary.filter(entries,query:search.stringValue).filter{pinnedOnly.state != .on || state.libraries.contains($0.url.standardizedFileURL.absoluteString)}
        filtered.sort { first,second in
            let a = state.libraries.contains(first.url.standardizedFileURL.absoluteString),b = state.libraries.contains(second.url.standardizedFileURL.absoluteString)
            if a != b { return a }
            let order = first.name.localizedStandardCompare(second.name)
            return order == .orderedSame ? first.url.path < second.url.path : order == .orderedAscending
        }
        table.reloadData()
        if let index = old.flatMap({filtered.firstIndex(of:$0)}) ?? (filtered.isEmpty ? nil : 0) { table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }
        updatePinButton()
    }
    func tableViewSelectionDidChange(_ notification:Notification) { updatePinButton() }
    private func updatePinButton() {
        pinButton.isEnabled = selected != nil
        pinButton.title = selected.map { pins.isPinned($0) ? "Unpin" : "Pin" } ?? "Pin"
    }
    @discardableResult func toggleSelectedPin() -> Bool {
        guard !hasMarkedText else { pinButton.toolTip = "Finish text composition before changing library pins.";return false }
        guard let selected else { return false }
        do { try pins.setLibrary(selected.url,pinned:!pins.isPinned(selected));pinButton.toolTip = nil;refresh();return true }
        catch { pinButton.toolTip = error.localizedDescription;return false }
    }
    @objc private func toggleSelectedPin(_ sender:Any?) { _ = toggleSelectedPin() }
    @objc private func filterPins(_ sender:Any?) { refresh() }
    @objc private func openSelected(_ sender:Any?) { if selected != nil { NSApp.stopModal(withCode:.alertFirstButtonReturn) } }
    func run() -> VisioLibraryEntry? {
        let alert = NSAlert();alert.messageText = "Visio Libraries";alert.informativeText = "Open a stencil to add its masters to Shapes. Open a template to start a new drawing. \(entries.count) libraries in this folder.";alert.accessoryView = self
        alert.addButton(withTitle:"Open");alert.addButton(withTitle:"Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? selected : nil
    }
}
