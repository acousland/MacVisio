import Foundation

/// Only syntax is shared. Evaluation hosts, cached values, palettes and text
/// measurement remain scoped to an immutable page and its document revision.
final class ShapeSheetExpressionCache {
    struct Statistics: Equatable {
        var hits = 0
        var compilations = 0
        var entries = 0
        var sourceBytes = 0
    }
    private struct Key: Hashable {
        var source: String
        var characterLimit: Int
    }
    static let shared = ShapeSheetExpressionCache()
    private let lock = NSLock()
    private let maximumEntries: Int
    private let maximumSourceBytes: Int
    private var entries: [Key: ShapeSheet.Expression] = [:]
    private var order: [Key] = []
    private var counters = Statistics()

    init(maximumEntries: Int = 2048, maximumSourceBytes: Int = 2 * 1024 * 1024) {
        self.maximumEntries = max(0, maximumEntries)
        self.maximumSourceBytes = max(0, maximumSourceBytes)
    }

    var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return counters
    }

    func expression(
        _ source: String, characterLimit: Int,
        compile: () throws -> ShapeSheet.Expression
    ) throws -> ShapeSheet.Expression {
        let key = Key(source: source, characterLimit: characterLimit)
        lock.lock()
        if let expression = entries[key] {
            counters.hits += 1
            lock.unlock()
            return expression
        }
        lock.unlock()
        // Parsing does not call back into the cache and does not use AppKit.
        let expression = try compile()
        lock.lock()
        defer { lock.unlock() }
        counters.compilations += 1
        if entries[key] == nil, maximumEntries > 0, source.utf8.count <= maximumSourceBytes {
            while !order.isEmpty
                && (entries.count >= maximumEntries
                    || counters.sourceBytes + source.utf8.count > maximumSourceBytes)
            {
                let oldest = order.removeFirst()
                entries.removeValue(forKey: oldest)
                counters.sourceBytes -= oldest.source.utf8.count
            }
            entries[key] = expression
            order.append(key)
            counters.sourceBytes += source.utf8.count
            counters.entries = entries.count
        }
        return expression
    }
}
