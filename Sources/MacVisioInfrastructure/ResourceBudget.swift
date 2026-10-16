import Foundation

package enum ResourceBudgets {
    package static let decodedImages = 64 * 1024 * 1024
    package static let imageCount = 128
    package static let retainedPaths = 32 * 1024 * 1024
    package static let retainedText = 32 * 1024 * 1024
    package static let undoPayload = 64 * 1024 * 1024
    package static let undoCount = 100

    /// Saturating arithmetic also rejects corrupt/unbounded image dimensions.
    package static func decodedImageCost(width: Int, height: Int, bytesPerPixel: Int = 4) -> Int {
        guard width > 0, height > 0, bytesPerPixel > 0 else { return Int.max }
        let pixels = width.multipliedReportingOverflow(by: height)
        guard !pixels.overflow else { return Int.max }
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: bytesPerPixel)
        return bytes.overflow ? Int.max : bytes.partialValue
    }
}

/// A deterministic, thread-safe LRU with hard retained count/cost limits.
/// The cost must describe the retained value, not its compressed source bytes.
package final class ResourceBudgetCache<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        let cost: Int
        var access: UInt64
    }

    package struct Statistics {
        package let count: Int
        package let cost: Int
        package let hits: Int
        package let misses: Int
        package let evictions: Int
    }

    package let maximumCount: Int
    package let maximumCost: Int
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]
    private var cost = 0
    private var clock: UInt64 = 0
    private var hits = 0
    private var misses = 0
    private var evictions = 0

    package init(maximumCount: Int, maximumCost: Int) {
        precondition(maximumCount >= 0 && maximumCost >= 0)
        self.maximumCount = maximumCount
        self.maximumCost = maximumCost
    }

    package var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return Statistics(
            count: entries.count, cost: cost, hits: hits,
            misses: misses, evictions: evictions)
    }

    package func value(for key: Key) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard var entry = entries[key] else {
            misses += 1
            return nil
        }
        clock &+= 1
        entry.access = clock
        entries[key] = entry
        hits += 1
        return entry.value
    }

    @discardableResult
    package func insert(_ value: Value, for key: Key, cost newCost: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let old = entries.removeValue(forKey: key) { cost -= old.cost }
        guard maximumCount > 0, newCost >= 0, newCost <= maximumCost else { return false }
        while entries.count >= maximumCount || cost > maximumCost - newCost {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access }) else { break }
            entries.removeValue(forKey: oldest.key)
            cost -= oldest.value.cost
            evictions += 1
        }
        clock &+= 1
        entries[key] = Entry(value: value, cost: newCost, access: clock)
        cost += newCost
        return true
    }

    package func removeAll() {
        lock.lock()
        entries.removeAll()
        cost = 0
        lock.unlock()
    }
}
