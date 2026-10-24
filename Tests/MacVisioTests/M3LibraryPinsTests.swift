import AppKit
import XCTest
@testable import MacVisio

final class M3LibraryPinsTests: XCTestCase {
    private var temporary: [URL] = []
    private var suites: [String] = []
    override func tearDown() {
        for url in temporary { try? FileManager.default.removeItem(at: url) }
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
        super.tearDown()
    }
    private func defaults() throws -> UserDefaults {
        let suite = "MacVisio.M3LibraryPinsTests.\(UUID())"; suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("M3-library-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        temporary.append(url); return url
    }
    private func definition(_ name: String = "Same name", family: String = "Tests", id: String = "1", file: URL) -> StencilDefinition {
        var page = DiagramPage(); page.nodes = [DiagramNode(x: 10, y: 10, text: name)]
        return StencilDefinition(name: name, family: family, fragment: page,
            source: StencilSource(url: file, masterID: id, universalName: "Unique.\(id)"))
    }
    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }

    func testPinsPersistByFileAndPublicIDInsteadOfDisplayName() throws {
        let preferences = try defaults(), pins = LibraryPins(defaults: preferences), directory = try folder()
        let first = directory.appendingPathComponent("first.vssx"), second = directory.appendingPathComponent("second.vssx")
        let source = StencilSource(url: first, masterID: "010", universalName: "First")
        try pins.setLibrary(first, pinned: true); try pins.setMaster(source, pinned: true)
        let restored = LibraryPins(defaults: preferences)
        XCTAssertTrue(restored.isPinned(VisioLibraryEntry(url: first)))
        XCTAssertTrue(restored.isPinned(StencilSource(url: first, masterID: "10", universalName: "Renamed")))
        XCTAssertFalse(restored.isPinned(StencilSource(url: second, masterID: "10", universalName: "First")))
        XCTAssertFalse(restored.isPinned(StencilSource(url: first, masterID: "11", universalName: "First")))
        XCTAssertEqual(restored.snapshot.libraryURLs, [first])
        try restored.setMaster(source, pinned: false); try restored.setLibrary(first, pinned: false)
        XCTAssertEqual(pins.snapshot, LibraryPins.State())
    }

    func testInvalidPinAndCapacityFailureLeaveExistingPreferencesIntact() throws {
        let pins = LibraryPins(defaults: try defaults()), directory = try folder()
        let web = try XCTUnwrap(URL(string: "https://example.com/master.vssx"))
        XCTAssertThrowsError(try pins.setLibrary(web, pinned: true))
        XCTAssertThrowsError(try pins.setMaster(StencilSource(url: web, masterID: "1", universalName: ""), pinned: true))
        XCTAssertThrowsError(try pins.setMaster(StencilSource(url: directory, masterID: "invalid", universalName: ""), pinned: true))
        XCTAssertEqual(pins.snapshot, LibraryPins.State())
        for i in 0..<256 { try pins.setLibrary(directory.appendingPathComponent("\(i).vssx"), pinned: true) }
        let before = pins.snapshot
        XCTAssertThrowsError(try pins.setLibrary(directory.appendingPathComponent("overflow.vssx"), pinned: true))
        XCTAssertEqual(pins.snapshot, before)
        try pins.setLibrary(directory.appendingPathComponent("0.vssx"), pinned: false)
        XCTAssertEqual(pins.snapshot.libraries.count, 255)
    }

    func testPublicStencilMetadataKeepsDuplicateNamesDistinctAndStableAcrossReload() throws {
        let file = try folder().appendingPathComponent("Metadata.vssx")
        try VisioReusableFormat.writeStencil([definition(file: file), definition(id: "2", file: file)], to: file)
        var parts = try VisioPackage.read(file)
        let index = try VisioXML.document(XCTUnwrap(parts["visio/masters/masters.xml"]))
        let masters = try XCTUnwrap(index.rootElement()).elementsLocal("Master")
        masters[0].setAttr("NameU", "Unique.Alpha"); masters[1].setAttr("NameU", "Unique.Beta")
        parts["visio/masters/masters.xml"] = index.xmlData(options: .nodePreserveAll)
        try VisioPackage.write(parts, to: file)
        let imported = try VisioStencil.read(from: file).items, reloaded = try VisioStencil.read(from: file).items
        XCTAssertEqual(imported.map(\.name), ["Same name", "Same name"])
        XCTAssertEqual(imported.compactMap { $0.source?.masterID }, ["1", "2"])
        XCTAssertEqual(imported.compactMap { $0.source?.universalName }, ["Unique.Alpha", "Unique.Beta"])
        XCTAssertEqual(Set(imported.compactMap { $0.source?.key }).count, 2)
        XCTAssertEqual(imported.compactMap { $0.source?.key }, reloaded.compactMap { $0.source?.key })
        XCTAssertTrue(imported[0].searchMetadata.contains("Unique.Alpha"))
        XCTAssertTrue(imported[0].metadataDescription.contains("Master 1"))
        XCTAssertTrue(imported[0].metadataDescription.contains(file.path))
        XCTAssertNil(try VisioStencil.definitions([imported[0].fragment], family: "Detached")[0].source)
    }

    func testPinnedLibrariesAreResolvedAcrossFoldersWithoutDuplicatesSymlinksOrMissingFiles() throws {
        let first = try folder(), second = try folder()
        let local = first.appendingPathComponent("Local.vssx"), pinned = second.appendingPathComponent("Pinned.vssx")
        let link = second.appendingPathComponent("Link.vssx"), missing = second.appendingPathComponent("Missing.vssx")
        try Data().write(to: local); try Data().write(to: pinned)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: pinned)
        let entries = try VisioLibrary.includingPinned([local, pinned, pinned, link, missing], in: VisioLibrary.entries(in: first))
        XCTAssertEqual(entries.map(\.url), [local, pinned].map{$0.standardizedFileURL.resolvingSymlinksInPath()})
    }

    func testNativeLibraryPickerPinsFiltersAndPreservesSelectedIdentity() throws {
        try onMain {
            _ = NSApplication.shared
            let preferences = try self.defaults(), pins = LibraryPins(defaults: preferences), directory = try self.folder()
            let entries = ["Alpha.vssx", "Beta.vstx"].map { VisioLibraryEntry(url: directory.appendingPathComponent($0)) }
            let picker = VisioLibraryPicker(entries: entries, pins: pins)
            picker.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            XCTAssertTrue(picker.toggleSelectedPin())
            XCTAssertEqual(picker.filtered.first, entries[1]); XCTAssertEqual(picker.selected, entries[1])
            XCTAssertEqual(picker.pinButton.title, "Unpin")
            picker.pinnedOnly.state = .on; picker.refresh()
            XCTAssertEqual(picker.filtered, [entries[1]])
            picker.search.stringValue = "Alpha"; picker.refresh()
            XCTAssertTrue(picker.filtered.isEmpty); XCTAssertNil(picker.selected); XCTAssertFalse(picker.pinButton.isEnabled)
            let fresh = VisioLibraryPicker(entries: entries, pins: LibraryPins(defaults: preferences))
            XCTAssertEqual(fresh.filtered.first, entries[1])
            fresh.pinnedOnly.state = .on; fresh.refresh(); XCTAssertTrue(fresh.toggleSelectedPin())
            XCTAssertTrue(fresh.filtered.isEmpty); XCTAssertFalse(fresh.pinButton.isEnabled)
        }
    }

    func testSameNamedLibrariesExposeDistinctSourcePathsAndPinTheSelectedFile() throws {
        try onMain {
            _ = NSApplication.shared
            let entries = try [self.folder(),self.folder()].map { VisioLibraryEntry(url:$0.appendingPathComponent("Same.vssx")) }
            let pins = LibraryPins(defaults:try self.defaults()), picker = VisioLibraryPicker(entries:entries,pins:pins)
            for row in picker.filtered.indices {
                let label = try XCTUnwrap(picker.tableView(picker.table,viewFor:picker.table.tableColumns[0],row:row) as? NSTextField)
                XCTAssertEqual(label.stringValue,"Same");XCTAssertEqual(label.toolTip,picker.filtered[row].url.path)
                XCTAssertTrue(label.accessibilityLabel()?.contains(picker.filtered[row].url.path) == true)
            }
            let chosen = picker.filtered[1]
            picker.table.selectRowIndexes(IndexSet(integer:1),byExtendingSelection:false)
            XCTAssertTrue(picker.toggleSelectedPin());XCTAssertEqual(picker.selected,chosen)
            XCTAssertEqual(pins.snapshot.libraries,[chosen.url.standardizedFileURL.absoluteString])
        }
    }

    func testMasterPinActionUpdatesNativeCategoryWithoutEditingDrawingOrRecreatingCards() throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument(); document.makeWindowControllers(); defer { document.close() }
            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            let pins = LibraryPins(defaults: try self.defaults()), file = try self.folder().appendingPathComponent("Library.vssx")
            let a = self.definition(family: "Pinned masters", file: file), b = self.definition(family: "Pinned masters", id: "2", file: file)
            editor.stencils = [a, b]
            let panel = StencilPanel(editor: editor, pins: pins); defer { panel.detachEditor() }
            panel.refreshCategories(selecting: "Pinned masters")
            XCTAssertEqual(panel.category.selectedItem?.representedObject as? String, "family:Pinned masters")
            XCTAssertEqual(panel.visibleMasterIDs, [a.id, b.id])
            let count = panel.cardsCreatedCount, state = document.stateID, revision = document.revision, before = document.diagram
            let card = try XCTUnwrap(panel.list.subviews.compactMap { $0 as? MasterStencilCard }.first { $0.definition.id == a.id })
            panel.category.selectItem(at: 4); panel.rebuild(); XCTAssertTrue(panel.visibleMasterIDs.isEmpty)
            XCTAssertTrue(card.togglePin())
            XCTAssertEqual(panel.visibleMasterIDs, [a.id])
            panel.refreshCategories(); XCTAssertEqual(panel.category.selectedItem?.representedObject as? String, "pinned")
            XCTAssertEqual(panel.visibleMasterIDs, [a.id])
            panel.search.stringValue = "Unique.2"; panel.rebuild(); XCTAssertTrue(panel.visibleMasterIDs.isEmpty)
            panel.category.selectItem(at: 0); panel.rebuild(); XCTAssertEqual(panel.visibleMasterIDs, [b.id])
            panel.search.stringValue = "Library.vssx Unique.1"; panel.rebuild(); XCTAssertEqual(panel.visibleMasterIDs, [a.id])
            XCTAssertTrue(card.togglePin()); panel.category.selectItem(at: 4); panel.search.stringValue = ""; panel.rebuild()
            XCTAssertTrue(panel.visibleMasterIDs.isEmpty); XCTAssertEqual(panel.cardsCreatedCount, count)
            XCTAssertEqual(document.diagram, before); XCTAssertEqual(document.stateID, state); XCTAssertEqual(document.revision, revision)
            XCTAssertFalse(document.isDocumentEdited); XCTAssertFalse(document.undoManager?.canUndo ?? true)
            XCTAssertTrue(card.toolTip?.contains("Master 1") == true)
        }
    }
}
