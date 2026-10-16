import MacVisioInfrastructure
import XCTest
@testable import MacVisio

final class ResourceBudgetTests: XCTestCase {
    func testLeastRecentlyUsedEvictionSatisfiesBothLimits() {
        let cache = ResourceBudgetCache<String, Data>(maximumCount: 3, maximumCost: 10)
        cache.insert(Data([1]), for: "a", cost: 4)
        cache.insert(Data([2]), for: "b", cost: 4)
        XCTAssertEqual(cache.value(for: "a"), Data([1]))
        cache.insert(Data([3]), for: "c", cost: 4)
        XCTAssertNil(cache.value(for: "b"), "The unvisited entry must be evicted before the recently used entry")
        XCTAssertEqual(cache.statistics.cost, 8)
        XCTAssertEqual(cache.statistics.count, 2)
        XCTAssertEqual(cache.statistics.evictions, 1)

        let countLimited = ResourceBudgetCache<Int, Int>(maximumCount: 2, maximumCost: 100)
        for value in 0..<1000 { countLimited.insert(value, for: value, cost: 0) }
        XCTAssertEqual(countLimited.statistics.count, 2, "Zero-cost values still obey a count limit")
        XCTAssertEqual(countLimited.statistics.evictions, 998)
    }

    func testOversizeReplacementReleasesPriorValueAndCacheClearReleasesAllValues() {
        let cache = ResourceBudgetCache<String, LifetimeProbe>(maximumCount: 2, maximumCost: 10)
        weak var first: LifetimeProbe?
        weak var second: LifetimeProbe?
        do {
            let value = LifetimeProbe()
            first = value
            XCTAssertTrue(cache.insert(value, for: "a", cost: 4))
        }
        XCTAssertNotNil(first)
        XCTAssertFalse(cache.insert(LifetimeProbe(), for: "a", cost: 11))
        XCTAssertNil(first)
        do {
            let value = LifetimeProbe()
            second = value
            cache.insert(value, for: "b", cost: 3)
        }
        cache.removeAll()
        XCTAssertNil(second)
        XCTAssertEqual(cache.statistics.count, 0)
        XCTAssertEqual(cache.statistics.cost, 0)
    }

    func testDecodedImageCostsUsePixelsAndSaturateInvalidDimensions() {
        XCTAssertEqual(ResourceBudgets.decodedImageCost(width: 4096, height: 4096), 64 * 1024 * 1024)
        XCTAssertEqual(ResourceBudgets.decodedImageCost(width: Int.max, height: 2), Int.max)
        XCTAssertEqual(ResourceBudgets.decodedImageCost(width: -1, height: 1), Int.max)
        XCTAssertEqual(ResourceBudgets.decodedImageCost(width: 1, height: 0), Int.max)
    }

    private final class LifetimeProbe {}
}
