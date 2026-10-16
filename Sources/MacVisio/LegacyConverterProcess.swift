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

/// Bounded caller reads, including when a descendant retains the stdout pipe.
/// Termination applies only to the launched helper, not its process tree.
enum LegacyConverterProcess {
    static func run(
        executable: URL,
        arguments: [String],
        cancellation: LifecycleJobCancellation? = nil,
        timeout: TimeInterval = 30,
        maximumOutputBytes: Int = 64 * 1024 * 1024
    ) throws -> Data {
        precondition(timeout.isFinite && timeout > 0 && maximumOutputBytes > 0)
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
        defer {
            if let handler { cancellation?.removeHandler(handler) }
            termination.stop()
            try? pipe.fileHandleForReading.close()
        }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        var reachedEOF = false
        while true {
            try cancellation?.check()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw LegacyConverterError.timedOut }
            if !reachedEOF {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(descriptor, $0.baseAddress, $0.count)
                }
                if count > 0 {
                    guard count <= maximumOutputBytes - data.count else {
                        throw LegacyConverterError.outputLimit
                    }
                    data.append(contentsOf: buffer.prefix(count))
                    continue
                } else if count == 0 {
                    reachedEOF = true
                } else {
                    let readError = errno
                    if readError == EINTR { continue }
                    guard readError == EAGAIN || readError == EWOULDBLOCK else {
                        throw POSIXError(POSIXErrorCode(rawValue: readError) ?? .EIO)
                    }
                }
            }
            if reachedEOF && !process.isRunning { break }
            // An exited parent does not imply EOF: an inherited descriptor may
            // remain open. Neither read nor process completion may block checks.
            let milliseconds = Int32(max(1, min(25, ceil(remaining * 1000))))
            var polled = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
            let result =
                reachedEOF
                ? Darwin.poll(nil, 0, milliseconds)
                : Darwin.poll(&polled, 1, milliseconds)
            if result < 0 {
                let pollError = errno
                if pollError == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: pollError) ?? .EIO)
            }
            if polled.revents & Int16(POLLNVAL) != 0 { throw POSIXError(.EBADF) }
        }
        try cancellation?.check()
        guard process.terminationStatus == 0 else {
            throw LegacyConverterError.failed(process.terminationStatus)
        }
        return data
    }

    private final class Termination {
        private let process: Process
        private let lock = NSLock()
        private var requestedStop = false

        init(process: Process) { self.process = process }

        func stop() {
            lock.lock()
            guard !requestedStop, process.isRunning else {
                lock.unlock()
                return
            }
            requestedStop = true
            lock.unlock()
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) { [process] in
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}
