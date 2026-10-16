import Darwin
import Foundation
import MacVisioInfrastructure

enum LegacyConverterError: Error, LocalizedError, Equatable {
    case timedOut
    case outputLimit
    case failed(Int32)

    var errorDescription: String? {
        switch self {
        case .timedOut: return "The legacy Visio converter exceeded its time limit."
        case .outputLimit: return "The converted drawing exceeds the supported size."
        case .failed(let status): return "The legacy Visio converter failed (exit status \(status))."
        }
    }
}

/// Bounded process output with cancellation that interrupts a blocked read.
/// Escalation also handles helpers that ignore SIGTERM.
enum LegacyConverterProcess {
    static func run(
        executable: URL,
        arguments: [String],
        cancellation: LifecycleJobCancellation? = nil,
        timeout: TimeInterval = 30,
        maximumOutputBytes: Int = 64 * 1024 * 1024
    ) throws -> Data {
        precondition(timeout > 0 && maximumOutputBytes > 0)
        try cancellation?.check()
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let termination = Termination(process: process)
        let handler = cancellation?.onCancel { termination.stop() }
        let deadline = DispatchWorkItem { termination.timeOut() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer {
            deadline.cancel()
            if let handler { cancellation?.removeHandler(handler) }
            termination.stop()
            process.waitUntilExit()
            try? pipe.fileHandleForReading.close()
        }
        var data = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
            try cancellation?.check()
            guard chunk.count <= maximumOutputBytes - data.count else {
                throw LegacyConverterError.outputLimit
            }
            data.append(chunk)
        }
        process.waitUntilExit()
        try cancellation?.check()
        if termination.didTimeOut { throw LegacyConverterError.timedOut }
        guard process.terminationStatus == 0 else {
            throw LegacyConverterError.failed(process.terminationStatus)
        }
        return data
    }

    private final class Termination {
        private let process: Process
        private let lock = NSLock()
        private var timedOut = false

        init(process: Process) { self.process = process }

        var didTimeOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return timedOut
        }

        func timeOut() {
            guard process.isRunning else { return }
            lock.lock()
            timedOut = true
            lock.unlock()
            stop()
        }

        func stop() {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { [process] in
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}
