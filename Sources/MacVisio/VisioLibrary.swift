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
        }.map{VisioLibraryEntry(url:$0)}.sorted{$0.name.localizedStandardCompare($1.name) == .orderedAscending}
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
    var selected:VisioLibraryEntry? { filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow] : nil }
    init(entries:[VisioLibraryEntry]) {
        self.entries = entries;filtered = entries
        super.init(frame:CGRect(x:0,y:0,width:620,height:380))
        search.placeholderString = "Search library filenames or type";search.delegate = self;search.frame = CGRect(x:0,y:0,width:620,height:28);addSubview(search)
        let scroll = NSScrollView(frame:CGRect(x:0,y:38,width:620,height:342));scroll.hasVerticalScroller = true;scroll.borderType = .bezelBorder;scroll.documentView = table;addSubview(scroll)
        for (name,title,width) in [("name","Library",480.0),("type","Type",110.0)] { let column = NSTableColumn(identifier:NSUserInterfaceItemIdentifier(name));column.title = title;column.width = width;table.addTableColumn(column) }
        table.delegate = self;table.dataSource = self;table.rowHeight = 26;table.usesAlternatingRowBackgroundColors = true;table.target = self;table.doubleAction = #selector(openSelected(_:))
        table.setAccessibilityLabel("Visio libraries");search.setAccessibilityLabel("Search Visio libraries")
        if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false) }
    }
    required init?(coder:NSCoder) { fatalError() }
    func numberOfRows(in tableView:NSTableView) -> Int { filtered.count }
    func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int) -> NSView? {
        let entry = filtered[row],label = NSTextField(labelWithString:tableColumn?.identifier.rawValue == "type" ? entry.type : entry.name)
        label.font = .systemFont(ofSize:12);label.textColor = .labelColor;return label
    }
    func controlTextDidChange(_ notification:Notification) {
        let old = selected;filtered = VisioLibrary.filter(entries,query:search.stringValue);table.reloadData()
        if let index = old.flatMap({filtered.firstIndex(of:$0)}) ?? (filtered.isEmpty ? nil : 0) { table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false) }
    }
    @objc private func openSelected(_ sender:Any?) { if selected != nil { NSApp.stopModal(withCode:.alertFirstButtonReturn) } }
    func run() -> VisioLibraryEntry? {
        let alert = NSAlert();alert.messageText = "Visio Libraries";alert.informativeText = "Open a stencil to add its masters to Shapes. Open a template to start a new drawing. \(entries.count) libraries in this folder.";alert.accessoryView = self
        alert.addButton(withTitle:"Open");alert.addButton(withTitle:"Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? selected : nil
    }
}
