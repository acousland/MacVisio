import Foundation

/// The immutable input a job is allowed to publish. Revision alone is not an
/// identity: undo may revisit old content and separate documents may share one.
package struct LifecycleJobInput: Hashable {
    package let ownerID: UUID
    package let snapshotID: UUID
    package let revision: UInt64

    package init(ownerID: UUID, snapshotID: UUID, revision: UInt64) {
        self.ownerID = ownerID
        self.snapshotID = snapshotID
        self.revision = revision
    }
}

package enum LifecycleJobKind: String {
    case open, conversion, library, export, save, calculation
}

package enum LifecycleJobError: Error, LocalizedError, Equatable {
    case queueFull
    case cancelled
    case staleInput
    case inputIsDestination

    package var errorDescription: String? {
        switch self {
        case .queueFull: return "The background job queue is full. Try again after a current job finishes."
        case .cancelled: return "The operation was cancelled."
        case .staleInput: return "The operation's document input is no longer current."
        case .inputIsDestination: return "The output must use a different file from the input."
        }
    }
}

package struct LifecycleJobProgress {
    package let stage: String
    package let fraction: Double?

    package init(stage: String, fraction: Double? = nil) {
        self.stage = stage
        self.fraction = fraction
    }
}

/// Thread-safe cooperative cancellation. Subprocess owners register a short
/// termination handler so cancellation also interrupts a blocked pipe read.
package final class LifecycleJobCancellation {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [UUID: () -> Void] = [:]

    package init() {}

    package var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    package func check() throws {
        if isCancelled { throw LifecycleJobError.cancelled }
    }

    package func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let callbacks = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()
        callbacks.forEach { $0() }
    }

    @discardableResult
    package func onCancel(_ handler: @escaping () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
        } else {
            handlers[id] = handler
            lock.unlock()
        }
        return id
    }

    package func removeHandler(_ id: UUID) {
        lock.lock()
        handlers.removeValue(forKey: id)
        lock.unlock()
    }
}

package final class LifecycleJobHandle {
    package let id: UUID
    package let kind: LifecycleJobKind
    package let input: LifecycleJobInput
    package let cancellation = LifecycleJobCancellation()

    fileprivate init(id: UUID, kind: LifecycleJobKind, input: LifecycleJobInput) {
        self.id = id
        self.kind = kind
        self.input = input
    }

    package func cancel() { cancellation.cancel() }
}

package struct LifecycleJobContext {
    package let id: UUID
    package let input: LifecycleJobInput
    package let cancellation: LifecycleJobCancellation
    private let report: (LifecycleJobProgress) -> Void
    private static let threadKey = "com.macvisio.lifecycle.context"

    /// Compatibility boundary for synchronous reader APIs invoked inside an
    /// owned worker. Scoped to that worker thread and removed before reuse.
    package static var current: LifecycleJobContext? {
        (Thread.current.threadDictionary[threadKey] as? ContextBox)?.value
    }

    fileprivate init(handle: LifecycleJobHandle, report: @escaping (LifecycleJobProgress) -> Void) {
        id = handle.id
        input = handle.input
        cancellation = handle.cancellation
        self.report = report
    }

    package func checkpoint() throws { try cancellation.check() }

    package func progress(_ stage: String, fraction: Double? = nil) {
        guard !cancellation.isCancelled else { return }
        let bounded = fraction.flatMap { $0.isFinite ? max(0, min(1, $0)) : nil }
        report(LifecycleJobProgress(stage: stage, fraction: bounded))
    }

    fileprivate func perform<Output>(_ work: () throws -> Output) rethrows -> Output {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[Self.threadKey]
        dictionary[Self.threadKey] = ContextBox(self)
        defer {
            if let previous {
                dictionary[Self.threadKey] = previous
            } else {
                dictionary.removeObject(forKey: Self.threadKey)
            }
        }
        return try work()
    }

    private final class ContextBox: NSObject {
        let value: LifecycleJobContext
        init(_ value: LifecycleJobContext) { self.value = value }
    }
}

/// Bounds retained inputs/results as well as executing workers. Results count
/// as outstanding until main-thread delivery, preventing an occupied main loop
/// from accumulating an unbounded queue of completed document snapshots.
package final class LifecycleJobService {
    package static let shared = LifecycleJobService()

    package struct Statistics {
        package let outstanding: Int
        package let running: Int
        package let peakRunning: Int
        package let completed: Int
    }

    private let workers = OperationQueue()
    private let lock = NSLock()
    private let maximumOutstanding: Int
    private var handles: [UUID: LifecycleJobHandle] = [:]
    private var running = 0
    private var peakRunning = 0
    private var completed = 0

    package init(maximumConcurrent: Int = 2, maximumOutstanding: Int = 32) {
        precondition(maximumConcurrent > 0 && maximumOutstanding >= maximumConcurrent)
        self.maximumOutstanding = maximumOutstanding
        workers.name = "com.macvisio.lifecycle"
        workers.qualityOfService = .userInitiated
        workers.maxConcurrentOperationCount = maximumConcurrent
    }

    package var statistics: Statistics {
        lock.lock()
        defer { lock.unlock() }
        return Statistics(
            outstanding: handles.count, running: running,
            peakRunning: peakRunning, completed: completed)
    }

    /// `accepts` and `completion` run on main. Callers check owner lifetime and
    /// the input's compatibility with current state in `accepts`; work closures
    /// must capture immutable values rather than reading the live document.
    @discardableResult
    package func submit<Output>(
        id: UUID = UUID(),
        kind: LifecycleJobKind,
        input: LifecycleJobInput,
        accepts: @escaping (LifecycleJobInput) -> Bool = { _ in true },
        progress: @escaping (LifecycleJobProgress) -> Void = { _ in },
        work: @escaping (LifecycleJobContext) throws -> Output,
        completion: @escaping (Result<Output, Error>) -> Void
    ) throws -> LifecycleJobHandle {
        let handle = LifecycleJobHandle(id: id, kind: kind, input: input)
        lock.lock()
        guard handles.count < maximumOutstanding, handles[id] == nil else {
            lock.unlock()
            throw LifecycleJobError.queueFull
        }
        handles[handle.id] = handle
        lock.unlock()

        let progressLock = NSLock()
        var lastProgressTime: TimeInterval = -.infinity
        var lastStage: String?
        let context = LifecycleJobContext(handle: handle) { update in
            // Coalesce repeated progress from tight loops before enqueuing UI
            // work. Stage transitions and completion are always observable.
            let now = ProcessInfo.processInfo.systemUptime
            progressLock.lock()
            let deliver =
                update.stage != lastStage || update.fraction == 1 || now - lastProgressTime >= 1 / 30
            if deliver {
                lastProgressTime = now
                lastStage = update.stage
            }
            progressLock.unlock()
            guard deliver else { return }
            DispatchQueue.main.async {
                guard !handle.cancellation.isCancelled, accepts(input) else { return }
                progress(update)
            }
        }
        workers.addOperation { [self] in
            lock.lock()
            running += 1
            peakRunning = max(peakRunning, running)
            lock.unlock()
            let result = Result {
                try context.checkpoint()
                let value = try context.perform { try work(context) }
                try context.checkpoint()
                return value
            }
            lock.lock()
            running -= 1
            lock.unlock()
            DispatchQueue.main.async { [self] in
                lock.lock()
                handles.removeValue(forKey: handle.id)
                completed += 1
                lock.unlock()
                if handle.cancellation.isCancelled {
                    completion(.failure(LifecycleJobError.cancelled))
                } else if !accepts(input) {
                    completion(.failure(LifecycleJobError.staleInput))
                } else {
                    completion(result)
                }
            }
        }
        return handle
    }

    package func cancel(ownerID: UUID) {
        lock.lock()
        let owned = handles.values.filter { $0.input.ownerID == ownerID }
        lock.unlock()
        owned.forEach { $0.cancel() }
    }
}
