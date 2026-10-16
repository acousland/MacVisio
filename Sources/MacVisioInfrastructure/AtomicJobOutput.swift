import Darwin
import Foundation

/// The destination changes only after a complete staged artifact is available.
/// The staging file is a sibling so POSIX rename is an atomic same-volume step.
package enum AtomicJobOutput {
    package static func write(
        to destination: URL,
        input: URL? = nil,
        cancellation: LifecycleJobCancellation? = nil,
        writer: (URL) throws -> Void
    ) throws {
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        if let input, input.resolvingSymlinksInPath().standardizedFileURL == target {
            throw LifecycleJobError.inputIsDestination
        }
        let staging = target.deletingLastPathComponent()
            .appendingPathComponent(".MacVisio-\(UUID().uuidString)")
            .appendingPathExtension(target.pathExtension)
        defer { try? FileManager.default.removeItem(at: staging) }
        try cancellation?.check()
        try writer(staging)
        try cancellation?.check()
        let status = staging.withUnsafeFileSystemRepresentation { source in
            target.withUnsafeFileSystemRepresentation { output in
                rename(source!, output!)
            }
        }
        guard status == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: target.path])
        }
    }
}
