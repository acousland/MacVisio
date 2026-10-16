import XCTest
@testable import MacVisio

final class RecentDrawingTests: XCTestCase {
    func testRecordsMoveToFrontAndCanonicalDuplicatesAreStoredOnce() {
        let (suite, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentDrawingStore(defaults: defaults)
        let first = fileURL("first.vsdx")
        let second = fileURL("second.vsdx")
        let firstAlias = URL(string: "file:///tmp/MacVisioRecentTests/folder/../first.vsdx")!

        XCTAssertNotEqual(first.absoluteString, firstAlias.absoluteString)
        store.record(first)
        store.record(second)
        store.record(firstAlias)

        XCTAssertEqual(store.entries().map(\.url), [first.standardizedFileURL, second.standardizedFileURL])
        store.record(second)
        XCTAssertEqual(store.entries().map(\.url), [second.standardizedFileURL, first.standardizedFileURL])
    }

    func testHistoryAndPinsPersistAcrossStoreInstances() {
        let (suite, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = fileURL("first.vsdx")
        let pinned = fileURL("pinned.vsdx")

        let initialStore = RecentDrawingStore(defaults: defaults)
        initialStore.record(first)
        initialStore.record(pinned)
        initialStore.togglePin(pinned)

        let reopenedStore = RecentDrawingStore(defaults: defaults)
        let entries = reopenedStore.entries()
        XCTAssertEqual(entries.map(\.url), [pinned.standardizedFileURL, first.standardizedFileURL])
        XCTAssertEqual(entries.map(\.isPinned), [true, false])
    }

    func testClearingHistoryRetainsPinnedDrawings() {
        let (suite, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentDrawingStore(defaults: defaults)
        let ordinary = fileURL("ordinary.vsdx")
        let pinned = fileURL("pinned.vsdx")
        let systemRecent = fileURL("system-recent.vsdx")

        store.record(ordinary)
        store.record(pinned)
        store.togglePin(pinned)
        store.clearHistory()

        let entries = store.entries(including: [systemRecent])
        XCTAssertEqual(entries.map(\.url), [pinned.standardizedFileURL, systemRecent.standardizedFileURL])
        XCTAssertEqual(entries.map(\.isPinned), [true, false])
    }

    func testSystemRecentsMergeAfterLocalHistoryAndDeduplicateCanonicalURLs() {
        let (suite, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentDrawingStore(defaults: defaults)
        let local = fileURL("local.vsdx")
        let shared = fileURL("shared.vsdx")
        let systemOnly = fileURL("system-only.vsdx")
        let sharedAlias = URL(string: "file:///tmp/MacVisioRecentTests/dir/../shared.vsdx")!

        store.record(local)
        store.record(shared)
        let entries = store.entries(including: [systemOnly, sharedAlias, local])

        XCTAssertEqual(entries.map(\.url), [
            shared.standardizedFileURL,
            local.standardizedFileURL,
            systemOnly.standardizedFileURL
        ])
    }

    func testHistoryLimitAppliesToLocalAndMergedRecentsWhilePinsRemainVisible() {
        let (suite, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentDrawingStore(defaults: defaults, limit: 2)
        let oldest = fileURL("oldest.vsdx")
        let middle = fileURL("middle.vsdx")
        let newest = fileURL("newest.vsdx")
        let systemOnly = fileURL("system-only.vsdx")

        store.record(oldest)
        store.record(middle)
        store.record(newest)
        XCTAssertEqual(store.entries().map(\.url), [newest.standardizedFileURL, middle.standardizedFileURL])

        store.togglePin(oldest)
        let entries = store.entries(including: [systemOnly])
        XCTAssertEqual(entries.map(\.url), [
            oldest.standardizedFileURL,
            newest.standardizedFileURL,
            middle.standardizedFileURL
        ])
        XCTAssertEqual(entries.map(\.isPinned), [true, false, false])
    }

    func testNonFileURLsAreExcludedFromHistoryPinsAndMergedEntries() {
        let (suite, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RecentDrawingStore(defaults: defaults)
        let remote = URL(string: "https://example.invalid/drawing.vsdx")!

        store.record(remote)
        store.togglePin(remote)

        XCTAssertTrue(store.entries().isEmpty)
        XCTAssertTrue(store.entries(including: [remote]).isEmpty)
    }

    func testRemoveForgetsHistoryAndPinWithoutSystemRecentResurrection() {
        let (suite, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let removed = fileURL("missing.vsdx"), retained = fileURL("retained.vsdx")
        let store = RecentDrawingStore(defaults: defaults)
        store.record(removed); store.togglePin(removed); store.record(retained)
        store.remove(removed)
        let reopened = RecentDrawingStore(defaults: defaults)
        XCTAssertEqual(reopened.entries(including: [removed]).map(\.url), [retained])
        reopened.record(removed)
        XCTAssertEqual(reopened.entries().map(\.url), [removed, retained])
        XCTAssertFalse(reopened.entries()[0].isPinned)
    }

    func testLocatePreservesPinAndOrderAndCoalescesExistingDestination() {
        let (suite, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = fileURL("old.vsdx"), new = fileURL("new.vsdx"), retained = fileURL("retained.vsdx")
        let store = RecentDrawingStore(defaults: defaults)
        store.record(new); store.record(old); store.record(retained)
        store.togglePin(old)
        store.relocate(old, to: new)
        let entries = store.entries(including: [old, new])
        XCTAssertEqual(entries.map(\.url), [new, retained])
        XCTAssertEqual(entries.map(\.isPinned), [true, false])
        XCTAssertEqual(RecentDrawingStore(defaults: defaults).entries(including: [old]).map(\.url), [new, retained])
    }

    func testLocateSystemOnlyEntryAndRemoteRejection() {
        let (suite, defaults) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let old = fileURL("old.vsdx"), new = fileURL("new.vsdx")
        let store = RecentDrawingStore(defaults: defaults)
        store.relocate(old, to: new)
        XCTAssertEqual(store.entries(including: [old]).map(\.url), [new])
        let remote = URL(string: "https://example.invalid/new.vsdx")!
        store.relocate(new, to: remote); store.remove(remote)
        XCTAssertEqual(store.entries(including: [remote]).map(\.url), [new])
    }

    private func isolatedDefaults() -> (String, UserDefaults) {
        let suite = "MacVisioRecentDrawingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (suite, defaults)
    }

    private func fileURL(_ name: String) -> URL {
        URL(fileURLWithPath: "/tmp/MacVisioRecentTests/\(name)")
    }
}
