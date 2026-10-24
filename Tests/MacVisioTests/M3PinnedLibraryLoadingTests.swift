import AppKit
import CryptoKit
import MacVisioInfrastructure
import XCTest
@testable import MacVisio

final class M3PinnedLibraryLoadingTests: XCTestCase {
    private var folders: [URL] = []
    private var suites: [String] = []
    override func tearDown() {
        folders.forEach { try? FileManager.default.removeItem(at: $0) }
        suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) }
        super.tearDown()
    }
    private func pins() throws -> LibraryPins {
        let name = "MacVisio.M3PinnedLoading.\(UUID())"; suites.append(name)
        return LibraryPins(defaults: try XCTUnwrap(UserDefaults(suiteName: name)))
    }
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("M3-pinned-loading-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let canonical = folder.resolvingSymlinksInPath().standardizedFileURL
        folders.append(canonical); return canonical
    }
    private func file(_ name: String = "Library.vssx") throws -> URL {
        let url = try folder().appendingPathComponent(name); try Data("source".utf8).write(to: url); return url
    }
    private func item(_ url: URL, id: String = "1", name: String = "Same caption") -> StencilDefinition {
        var page = DiagramPage(); page.nodes = [DiagramNode(text: name)]
        return StencilDefinition(name: name, family: "Tests", fragment: page,
            source: StencilSource(url: url.resolvingSymlinksInPath().standardizedFileURL, masterID: id, universalName: "Unique.\(id)"))
    }
    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }; return try DispatchQueue.main.sync(execute: body)
    }
    private func pump(_ done: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(15)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        guard done() else { throw DiagramError.invalid("Pinned library completion timed out") }
    }
    private func waitForSignal(_ semaphore: DispatchSemaphore) throws {
        var signalled = false
        try pump { if !signalled { signalled = semaphore.wait(timeout: .now()) == .success }; return signalled }
    }
    private func editor() throws -> (MacVisioDocument, EditorWindowController) {
        _ = NSApplication.shared
        let document = MacVisioDocument(); document.makeWindowControllers()
        return (document, try XCTUnwrap(document.windowControllers.first as? EditorWindowController))
    }

    func testOnlyExplicitLocalReferencesBecomeLoadSources() throws {
        let local = try file(), source = item(local, id: "010").source!
        var state = LibraryPins.State(); state.masters = [source.key, "https://example.invalid/unpinned.vssx#master=1", "file://server/share.vssx#master=1", "broken"]
        var reads: [URL] = []
        let result = try PinnedLibraryLoader.load(state, cache: PinnedStencilCache(), reader: { url in reads.append(url); return ([self.item(url, id: "10")], []) })
        XCTAssertEqual(reads, [local]); XCTAssertEqual(result.items.compactMap { $0.source?.masterID }, ["10"])
        XCTAssertEqual(result.rows.filter { $0.status == .unavailable(.invalidIdentity) }.count, 3)
        XCTAssertEqual(PinnedLibraryReference.master(source.key).source?.masterID, "10")
    }

    func testWholeLibraryAndMasterPinsReadOnceAndKeepDuplicateCaptionsDistinct() throws {
        let local = try file(), a = item(local), b = item(local, id: "2")
        var state = LibraryPins.State(); state.libraries = [local.absoluteString]; state.masters = [a.source!.key, b.source!.key]
        var reads = 0
        let result = try PinnedLibraryLoader.load(state, cache: PinnedStencilCache(), reader: { _ in reads += 1; return ([a, b], []) })
        XCTAssertEqual(reads, 1); XCTAssertEqual(result.items.map(\.id), [a.id, b.id])
        XCTAssertEqual(Set(result.items.compactMap { $0.source?.key }).count, 2)
        XCTAssertEqual(result.rows.map(\.status), [.loaded(2), .loaded(1), .loaded(1)])
    }

    func testMasterOnlyPinNeverFallsBackToSameNamedMaster() throws {
        let local = try file(), a = item(local), missing = item(local, id: "9")
        var state = LibraryPins.State(); state.masters = [missing.source!.key]
        let result = try PinnedLibraryLoader.load(state, cache: PinnedStencilCache(), reader: { _ in ([a], []) })
        XCTAssertTrue(result.items.isEmpty); XCTAssertEqual(result.rows.first?.status, .unavailable(.missingMaster))
    }

    func testActualPublicVSSXLoadsOnlyPinnedPublicIDWithMetadataAndSourceIntact() throws {
        let local = try file(), a = item(local), b = item(local, id: "2")
        try VisioReusableFormat.writeStencil([a, b], to: local)
        let originals = try VisioStencil.read(from: local).items
        var state = LibraryPins.State(); state.masters = [originals[1].source!.key]
        let before = try Data(contentsOf: local), result = try PinnedLibraryLoader.load(state, cache: PinnedStencilCache())
        XCTAssertEqual(result.items.count, 1); XCTAssertEqual(result.items.first?.source, originals[1].source)
        XCTAssertEqual(result.items.first?.fragment.nodes.first?.text, originals[1].fragment.nodes.first?.text)
        XCTAssertEqual(try Data(contentsOf: local), before); XCTAssertEqual(result.rows.first?.status, .loaded(1))
    }

    func testMissingLinkedAndUnsupportedPinsRemainVisibleWithoutReaderAccess() throws {
        let directory = try folder(), local = directory.appendingPathComponent("Source.vssx")
        try Data().write(to: local)
        let linked = directory.appendingPathComponent("Linked.vssx"), missing = directory.appendingPathComponent("Missing.vssx")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: local)
        let template = directory.appendingPathComponent("Template.vstx"), binary = directory.appendingPathComponent("Binary.vss")
        var state = LibraryPins.State(); state.libraries = Set([linked, missing, template, binary].map(\.absoluteString))
        var reads = 0
        let result = try PinnedLibraryLoader.load(state, cache: PinnedStencilCache(), reader: { _ in reads += 1; return ([], []) })
        XCTAssertEqual(reads, 0); XCTAssertEqual(result.rows.count, 4)
        XCTAssertEqual(result.rows.first { $0.reference.source?.url == linked }?.status, .unavailable(.linkedSource))
        XCTAssertEqual(result.rows.first { $0.reference.source?.url == missing }?.status, .unavailable(.missing))
        XCTAssertEqual(result.rows.filter { $0.status == .unavailable(.unsupported) }.count, 2)
    }

    func testLexicalParentAliasUsesCanonicalSourceWithoutRewritingStoredPin() throws {
        let local = try file(), alias = URL(fileURLWithPath: local.path.replacingOccurrences(of: "/private/var/", with: "/var/"))
        var state = LibraryPins.State(); state.libraries = [alias.absoluteString]
        let result = try PinnedLibraryLoader.load(state, cache: PinnedStencilCache(), reader: { _ in ([self.item(local)], []) })
        XCTAssertEqual(result.items.first?.source?.url, local)
        XCTAssertEqual(result.rows.first?.reference, .library(alias.absoluteString)); XCTAssertEqual(state.libraries, [alias.absoluteString])
    }

    func testMetadataChangeDuringReadRefusesResultAndCacheEntry() throws {
        let local = try file(), cache = PinnedStencilCache()
        XCTAssertThrowsError(try cache.read(local, reader: { url in
            try Data("changed with different bytes".utf8).write(to: url, options: .atomic)
            return ([self.item(url)], [])
        })) { XCTAssertEqual($0 as? PinnedLibraryFailure, .changed) }
        XCTAssertEqual(cache.statistics.count, 0)
    }

    func testCacheReusesUnchangedMetadataAndInvalidatesReplacedSource() throws {
        let local = try file(), cache = PinnedStencilCache(); var reads = 0
        let reader: PinnedStencilCache.Reader = { url in reads += 1; return ([self.item(url, name: String(decoding: try Data(contentsOf: url), as: UTF8.self))], []) }
        let first = try cache.read(local, reader: reader), same = try cache.read(local, reader: reader)
        XCTAssertEqual(first.items.first?.id, same.items.first?.id); XCTAssertEqual(reads, 1); XCTAssertEqual(cache.statistics.hits, 1)
        try Data("replacement".utf8).write(to: local, options: .atomic)
        let replaced = try cache.read(local, reader: reader)
        XCTAssertEqual(reads, 2); XCTAssertEqual(replaced.items.first?.name, "replacement")
    }

    func testSharedLRUBoundsCountAndDeclinesOversizeCacheRetention() throws {
        let first = try file("First.vssx"), second = try file("Second.vssx")
        let cache = PinnedStencilCache(maximumCount: 1)
        _ = try cache.read(first, reader: { ([self.item($0)], []) }); _ = try cache.read(second, reader: { ([self.item($0)], []) })
        XCTAssertEqual(cache.statistics.count, 1); XCTAssertEqual(cache.statistics.evictions, 1)
        let tiny = PinnedStencilCache(maximumCount: 1, maximumCost: 1)
        _ = try tiny.read(first, reader: { ([self.item($0)], []) })
        XCTAssertEqual(tiny.statistics.count, 0); XCTAssertEqual(tiny.statistics.cost, 0)
    }

    func testSourceFanoutAndAggregatePayloadLimitsReportRefusal() throws {
        let a = try file("A.vssx"), b = try file("B.vssx")
        var state = LibraryPins.State(); state.libraries = Set([a, b].map(\.absoluteString))
        var reads: [URL] = []
        let result = try PinnedLibraryLoader.load(state, cache: PinnedStencilCache(), maximumSources: 1, reader: { reads.append($0); return ([self.item($0)], []) })
        XCTAssertEqual(reads.count, 1); XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.rows.filter { $0.status == .unavailable(.limit) }.count, 1)
        state.libraries = [a.absoluteString]
        let bounded = try PinnedLibraryLoader.load(state, cache: PinnedStencilCache(), maximumCost: 2048, reader: { ([self.item($0)], []) })
        XCTAssertTrue(bounded.items.isEmpty); XCTAssertEqual(bounded.rows.first?.status, .unavailable(.limit))
        XCTAssertLessThanOrEqual(bounded.retainedCost, 2048)
    }

    func testRemovingExactUnavailableIdentityPreservesOtherSameCaptionPins() throws {
        let preferences = try pins(), a = try file(), b = try file()
        try preferences.setLibrary(a, pinned: true); try preferences.setLibrary(b, pinned: true)
        try FileManager.default.removeItem(at: a)
        try preferences.remove(.library(a.absoluteString))
        XCTAssertEqual(preferences.snapshot.libraries, [b.absoluteString])
        var state = LibraryPins.State(); state.masters = ["broken"]
        let raw = try XCTUnwrap(UserDefaults(suiteName: suites.last!)); raw.set(try JSONEncoder().encode(state), forKey: "MacVisio.LibraryPins.v1")
        try preferences.remove(.master("broken")); XCTAssertTrue(preferences.snapshot.masters.isEmpty)
    }

    func testOwnedStartupReturnsBeforeDeliveryPreservesFocusAndDoesNotEditDrawing() throws {
        try onMain {
            let (document, editor) = try self.editor(); defer { document.close() }
            let preferences = try pins(), local = try file(); try preferences.setLibrary(local, pinned: true)
            let before = document.diagram, state = document.stateID, revision = document.revision
            let firstResponder = editor.window?.firstResponder
            let coordinator = PinnedLibraryCoordinator(editor: editor, pins: preferences, cache: PinnedStencilCache(), reader: { url in
                XCTAssertFalse(Thread.isMainThread); return ([self.item(url)], [])
            }); defer { coordinator.detach() }
            coordinator.start(); XCTAssertTrue(coordinator.isLoading); XCTAssertTrue(editor.stencils.isEmpty)
            try pump { !coordinator.isLoading }
            XCTAssertEqual(editor.stencils.count, 1); XCTAssertEqual(coordinator.rows.first?.status, .loaded(1))
            XCTAssertTrue(editor.window?.firstResponder === firstResponder)
            XCTAssertEqual(document.diagram, before); XCTAssertEqual(document.stateID, state); XCTAssertEqual(document.revision, revision)
            XCTAssertFalse(document.isDocumentEdited); XCTAssertFalse(document.undoManager?.canUndo ?? true)
        }
    }

    func testConfiguredStartupIsIdempotentAndExplicitDetachCancelsDelivery() throws {
        try onMain {
            let (document, editor) = try self.editor(); defer { document.close() }
            let preferences = try pins(), local = try file(); try preferences.setLibrary(local, pinned: true)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let service = LifecycleJobService(maximumConcurrent: 1, maximumOutstanding: 4)
            var reads = 0
            XCTAssertTrue(editor.configurePinnedLibraries(pins: preferences, cache: PinnedStencilCache(), service: service, reader: { url in
                reads += 1; entered.signal(); _ = release.wait(timeout: .now() + 10); return ([self.item(url)], [])
            }))
            XCTAssertFalse(editor.configurePinnedLibraries(pins: preferences))
            let coordinator = editor.pinnedLibraries
            defer { editor.detachPinnedLibraries(); release.signal() }
            editor.startPinnedLibraries(); editor.startPinnedLibraries(); try waitForSignal(entered)
            XCTAssertEqual(reads, 1)
            editor.detachPinnedLibraries(); release.signal(); try pump { service.statistics.outstanding == 0 }
            XCTAssertFalse(coordinator.isLoading); XCTAssertTrue(coordinator.rows.isEmpty); XCTAssertTrue(editor.stencils.isEmpty)
        }
    }

    func testReloadPreservesMasterUUIDAndUnpinRetainsOnlyExplicitMasterSubset() throws {
        try onMain {
            let (document, editor) = try self.editor(); defer { document.close() }
            let preferences = try pins(), local = try file(), a = item(local), b = item(local, id: "2")
            try preferences.setLibrary(local, pinned: true); try preferences.setMaster(b.source!, pinned: true)
            let coordinator = PinnedLibraryCoordinator(editor: editor, pins: preferences, cache: PinnedStencilCache(), reader: { _ in ([a, b], []) }); defer { coordinator.detach() }
            coordinator.start(); try pump { !coordinator.isLoading }
            let firstIDs = editor.stencils.map(\.id)
            coordinator.reload(); try pump { !coordinator.isLoading }; XCTAssertEqual(editor.stencils.map(\.id), firstIDs)
            try preferences.setLibrary(local, pinned: false); try pump { !coordinator.isLoading }
            XCTAssertEqual(editor.stencils.map(\.id), [firstIDs[1]]); XCTAssertEqual(editor.stencils.first?.source?.masterID, "2")
            try preferences.setMaster(b.source!, pinned: false); XCTAssertTrue(editor.stencils.isEmpty)
        }
    }

    func testManualInstalledSourceIsDeduplicatedAndSurvivesUnpin() throws {
        try onMain {
            let (document, editor) = try self.editor(); defer { document.close() }
            let preferences = try pins(), local = try file(), manual = item(local)
            editor.stencils = [manual]; try preferences.setLibrary(local, pinned: true)
            let coordinator = PinnedLibraryCoordinator(editor: editor, pins: preferences, cache: PinnedStencilCache(), reader: { _ in ([self.item(local)], []) }); defer { coordinator.detach() }
            coordinator.start(); try pump { !coordinator.isLoading }; XCTAssertEqual(editor.stencils.map(\.id), [manual.id])
            try preferences.setLibrary(local, pinned: false); XCTAssertEqual(editor.stencils.map(\.id), [manual.id])
        }
    }

    func testPinChangeWhileWorkerIsBlockedRejectsStaleInstall() throws {
        try onMain {
            let (document, editor) = try self.editor(); defer { document.close() }
            let preferences = try pins(), local = try file(); try preferences.setLibrary(local, pinned: true)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let service = LifecycleJobService(maximumConcurrent: 1, maximumOutstanding: 4)
            let coordinator = PinnedLibraryCoordinator(editor: editor, pins: preferences, cache: PinnedStencilCache(), service: service, reader: { url in entered.signal(); _ = release.wait(timeout: .now() + 10); return ([self.item(url)], []) }); defer { coordinator.detach(); release.signal() }
            coordinator.start(); try waitForSignal(entered)
            try preferences.setLibrary(local, pinned: false); release.signal()
            try pump { service.statistics.outstanding == 0 }
            XCTAssertTrue(editor.stencils.isEmpty); XCTAssertTrue(coordinator.rows.isEmpty)
        }
    }

    func testCancelCannotInstallAndRetryCanLoadSameExplicitPin() throws {
        try onMain {
            let (document, editor) = try self.editor(); defer { document.close() }
            let preferences = try pins(), local = try file(); try preferences.setLibrary(local, pinned: true)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let service = LifecycleJobService(maximumConcurrent: 1, maximumOutstanding: 4)
            let coordinator = PinnedLibraryCoordinator(editor: editor, pins: preferences, cache: PinnedStencilCache(), service: service, reader: { url in entered.signal(); _ = release.wait(timeout: .now() + 10); return ([self.item(url)], []) }); defer { coordinator.detach(); release.signal() }
            coordinator.start(); try waitForSignal(entered)
            coordinator.cancel(); release.signal(); try pump { service.statistics.outstanding == 0 }
            XCTAssertTrue(editor.stencils.isEmpty); XCTAssertEqual(coordinator.rows.first?.status, .cancelled)
            release.signal(); coordinator.reload(); try pump { !coordinator.isLoading }
            XCTAssertEqual(editor.stencils.count, 1)
        }
    }

    func testLateAutomaticCompletionMergesNewManualLoadsBySourceIdentity() throws {
        try onMain {
            let (document, editor) = try self.editor(); defer { document.close() }
            let preferences = try pins(), local = try file(), unrelated = try file("Other.vssx")
            try preferences.setLibrary(local, pinned: true)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let coordinator = PinnedLibraryCoordinator(editor: editor, pins: preferences, cache: PinnedStencilCache(), reader: { url in
                entered.signal(); _ = release.wait(timeout: .now() + 10); return ([self.item(url, name: "Earlier automatic payload")], [])
            }); defer { coordinator.detach(); release.signal() }
            coordinator.start(); try waitForSignal(entered)
            let manual = item(local, name: "Newer manual payload"), other = item(unrelated)
            editor.stencils.append(contentsOf: [manual, other])
            let focus = editor.window?.firstResponder
            release.signal(); try pump { !coordinator.isLoading }
            XCTAssertEqual(editor.stencils.map(\.id), [manual.id, other.id])
            XCTAssertEqual(editor.stencils[0].name, "Newer manual payload")
            XCTAssertTrue(editor.window?.firstResponder === focus)
            try preferences.setLibrary(local, pinned: false)
            XCTAssertEqual(editor.stencils.map(\.id), [manual.id, other.id])
        }
    }

    func testOrdinaryDrawingEditDuringLoadDoesNotInvalidateLibraryResources() throws {
        try onMain {
            let (document, editor) = try self.editor(); defer { document.close() }
            let preferences = try pins(), local = try file(); try preferences.setLibrary(local, pinned: true)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let coordinator = PinnedLibraryCoordinator(editor: editor, pins: preferences, cache: PinnedStencilCache(), reader: { url in
                entered.signal(); _ = release.wait(timeout: .now() + 10); return ([self.item(url)], [])
            }); defer { coordinator.detach(); release.signal() }
            coordinator.start(); try waitForSignal(entered)
            let previous = document.stateID
            editor.insertShape(.rectangle)
            let edited = document.diagram, editedState = document.stateID
            XCTAssertNotEqual(editedState, previous)
            release.signal(); try pump { !coordinator.isLoading }
            XCTAssertEqual(editor.stencils.count, 1); XCTAssertEqual(document.diagram, edited)
            XCTAssertEqual(document.stateID, editedState); XCTAssertTrue(document.isDocumentEdited)
        }
    }

    func testRemovalOrEditOfAutomaticPaletteDuringReloadRefusesReintroduction() throws {
        try onMain {
            for remove in [true, false] {
                let (document, editor) = try self.editor(); defer { document.close() }
                let preferences = try pins(), local = try file(), cache = PinnedStencilCache()
                try preferences.setLibrary(local, pinned: true)
                let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
                var reads = 0
                let coordinator = PinnedLibraryCoordinator(editor: editor, pins: preferences, cache: cache, reader: { url in
                    reads += 1
                    if reads == 2 { entered.signal(); _ = release.wait(timeout: .now() + 10) }
                    return ([self.item(url)], [])
                }); defer { coordinator.detach(); release.signal() }
                coordinator.start(); try pump { !coordinator.isLoading }; XCTAssertEqual(editor.stencils.count, 1)
                cache.removeAll(); coordinator.reload(); try waitForSignal(entered)
                if remove { editor.stencils.removeAll() }
                else { editor.stencils[0].name = "New palette caption"; editor.stencils[0].fragment.nodes[0].text = "New palette content" }
                release.signal(); try pump { !coordinator.isLoading }
                XCTAssertEqual(coordinator.rows.first?.status, .unavailable(.paletteChanged))
                if remove { XCTAssertTrue(editor.stencils.isEmpty) }
                else {
                    XCTAssertEqual(editor.stencils[0].name, "New palette caption")
                    XCTAssertEqual(editor.stencils[0].fragment.nodes[0].text, "New palette content")
                }
            }
        }
    }

    func testClosingOwnerRejectsWorkerAndNativeControlsDetach() throws {
        try onMain {
            let (document, editor) = try self.editor()
            let preferences = try pins(), local = try file(); try preferences.setLibrary(local, pinned: true)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let service = LifecycleJobService(maximumConcurrent: 1, maximumOutstanding: 4)
            let coordinator = PinnedLibraryCoordinator(editor: editor, pins: preferences, cache: PinnedStencilCache(), service: service, reader: { url in entered.signal(); _ = release.wait(timeout: .now() + 10); return ([self.item(url)], []) })
            let controls = PinnedLibraryControls(editor: editor, coordinator: coordinator)
            defer { coordinator.detach(); controls.detach(); release.signal() }
            coordinator.start(); try waitForSignal(entered)
            document.close(); release.signal(); try pump { service.statistics.outstanding == 0 }
            XCTAssertTrue(editor.stencils.isEmpty); XCTAssertFalse(editor.lifecycleJobs.isActive)
            controls.refresh(); XCTAssertFalse(controls.retryPins()); XCTAssertFalse(controls.removeSelectedPin())
            XCTAssertNil(controls.table.dataSource); XCTAssertFalse(controls.retryButton.isEnabled)
        }
    }

    func testNativeUnavailableControlsPreserveSelectedPinIdentityAndRemoveExactKey() throws {
        try onMain {
            let (document, editor) = try self.editor(); defer { document.close() }
            let preferences = try pins(), directory = try folder()
            let a = directory.appendingPathComponent("Same.vssx"), b = try folder().appendingPathComponent("Same.vssx")
            try preferences.setLibrary(a, pinned: true); try preferences.setLibrary(b, pinned: true)
            let coordinator = PinnedLibraryCoordinator(editor: editor, pins: preferences, cache: PinnedStencilCache()); defer { coordinator.detach() }
            let controls = PinnedLibraryControls(editor: editor, coordinator: coordinator); defer { controls.detach() }
            coordinator.start(); try pump { !coordinator.isLoading }
            controls.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            let selected = try XCTUnwrap(controls.selectedReference)
            XCTAssertTrue(controls.detail.stringValue.contains(selected.source!.url.path))
            coordinator.reload(); try pump { !coordinator.isLoading }; XCTAssertEqual(controls.selectedReference, selected)
            try retainControlsIfRequested(controls)
            XCTAssertTrue(controls.removeSelectedPin()); try pump { !coordinator.isLoading }
            XCTAssertFalse(selected.isPresent(in: preferences.snapshot)); XCTAssertEqual(preferences.snapshot.libraries.count, 1)
            XCTAssertEqual(controls.rows.count, 1); XCTAssertTrue(controls.rows.first?.status.text.contains("missing") == true)
        }
    }

    func testMarkedTextRefusesPinActionsAndRetainsNativeComposition() throws {
        try onMain {
            let (document, editor) = try self.editor(); defer { document.close() }
            let preferences = try pins(), local = try file(); try preferences.setLibrary(local, pinned: true)
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let coordinator = PinnedLibraryCoordinator(editor: editor, pins: preferences, cache: PinnedStencilCache(), reader: { url in
                entered.signal(); _ = release.wait(timeout: .now() + 10); return ([self.item(url)], [])
            }); defer { coordinator.detach(); release.signal() }
            let controls = PinnedLibraryControls(editor: editor, coordinator: coordinator); defer { controls.detach() }
            coordinator.start(); try waitForSignal(entered)
            let input = NSTextField(frame: CGRect(x: 10, y: 10, width: 120, height: 24)); editor.root.addSubview(input)
            editor.window?.makeKeyAndOrderFront(nil); XCTAssertTrue(editor.window?.makeFirstResponder(input) == true)
            let field = try XCTUnwrap(editor.window?.firstResponder as? NSTextView)
            field.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            release.signal(); try pump { !coordinator.isLoading }
            XCTAssertEqual(editor.stencils.count, 1); XCTAssertTrue(editor.window?.firstResponder === field)
            let before = preferences.snapshot
            XCTAssertFalse(controls.retryPins()); XCTAssertFalse(controls.removeSelectedPin())
            let card = MasterStencilCard(item(local), editor: editor, pins: preferences); XCTAssertFalse(card.togglePin())
            XCTAssertTrue(field.hasMarkedText()); XCTAssertEqual(preferences.snapshot, before)
            field.unmarkText()
        }
    }

    func testExistingNativeLibraryPickerDoesNotPinOrRefilterMarkedSearchText() throws {
        try onMain {
            _ = NSApplication.shared
            let preferences = try pins(), local = try file()
            let picker = VisioLibraryPicker(entries: [VisioLibraryEntry(url: local)], pins: preferences)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
            defer { window.orderOut(nil) }
            window.contentView?.addSubview(picker); window.makeKeyAndOrderFront(nil)
            XCTAssertTrue(window.makeFirstResponder(picker.search))
            let field = try XCTUnwrap(window.firstResponder as? NSTextView)
            field.setMarkedText("あ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            let before = picker.filtered
            XCTAssertFalse(picker.toggleSelectedPin()); picker.refresh()
            XCTAssertEqual(picker.filtered, before); XCTAssertTrue(preferences.snapshot.libraries.isEmpty)
            XCTAssertTrue(field.hasMarkedText()); field.unmarkText()
        }
    }

    private func retainControlsIfRequested(_ controls: PinnedLibraryControls) throws {
        guard let configured = ProcessInfo.processInfo.environment["M3_EVIDENCE_DIR"], !configured.isEmpty else { return }
        guard (configured as NSString).isAbsolutePath else { throw DiagramError.invalid("Pin-control evidence requires an absolute M3_EVIDENCE_DIR.") }
        let view = try XCTUnwrap(controls.window?.contentView)
        view.layoutSubtreeIfNeeded()
        guard view.bounds.width > 0, view.bounds.height > 0, view.bounds.width <= 2048, view.bounds.height <= 2048 else { throw DiagramError.invalid("The pin-control evidence view exceeds its retention bound.") }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        guard data.count <= 16 * 1024 * 1024 else { throw DiagramError.invalid("The pin-control PNG exceeds its retention bound.") }
        let directory = URL(fileURLWithPath: configured, isDirectory: true)
            .appendingPathComponent("M3PinnedLibraryLoadingTests", isDirectory: true)
            .appendingPathComponent("testNativeUnavailableControlsPreserveSelectedPinIdentityAndRemoveExactKey", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("pinned-libraries.png"), options: .atomic)
        let manifest: [String: Any] = [
            "scope": "Synthetic local unavailable-pin controls; screenshot retention does not establish acceptance",
            "artifact": ["path": "pinned-libraries.png", "bytes": data.count, "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()],
            "rows": controls.rows.map { ["stored_key": $0.reference.key, "status": $0.status.text] }
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted]).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }
}
