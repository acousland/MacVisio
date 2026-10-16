import Foundation
import MacVisioInfrastructure

/// The evaluator owns immutable value snapshots on its worker. AppKit text,
/// font and layout objects are created and destroyed inside one main-queue
/// record; no live document or layout manager crosses the execution boundary.
enum ShapeTextMeasurementService {
    struct Statistics {
        var records = 0
        var mainThreadRecords = 0
        var offMainThreadRecords = 0
        var maximumRecordSeconds = 0.0
        var totalRecordSeconds = 0.0
    }
    private static let lock = NSLock()
    private static var totals = Statistics()

    static var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return totals
    }

    static func perform<Value>(cancellation: LifecycleJobCancellation? = nil, _ body: () throws -> Value)
        throws -> Value
    {
        try cancellation?.check()
        if !Thread.isMainThread {
            // The caller is an owned worker and never blocks the main queue
            // waiting for its completion. Cancellation is checked again when
            // this individual record reaches the main queue.
            return try DispatchQueue.main.sync { try perform(cancellation: cancellation, body) }
        }
        let start = ProcessInfo.processInfo.systemUptime
        defer {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            lock.lock()
            totals.records += 1
            if Thread.isMainThread { totals.mainThreadRecords += 1 } else { totals.offMainThreadRecords += 1 }
            totals.totalRecordSeconds += elapsed
            totals.maximumRecordSeconds = max(totals.maximumRecordSeconds, elapsed)
            lock.unlock()
        }
        let result = try body()
        try cancellation?.check()
        return result
    }
}
