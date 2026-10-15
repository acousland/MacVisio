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
