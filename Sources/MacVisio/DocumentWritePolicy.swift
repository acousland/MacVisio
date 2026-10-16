import Foundation

/// A separate destination remains available when an original is read-only.
/// Atomic rename through a writable parent must not bypass that source policy.
enum DocumentWritePolicy {
    enum Failure: LocalizedError {
        case readOnlySource
        var errorDescription: String? { "The original drawing is read-only and cannot be replaced." }
        var recoverySuggestion: String? {
            "Save As to a separate destination or save a native MacVisio copy."
        }
    }

    static func requireWritableOriginal(_ canonicalURL: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: canonicalURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        let writable = try canonicalURL.resourceValues(forKeys: [.isWritableKey]).isWritable
        if permissions.map({ $0 & 0o222 == 0 }) == true || writable == false {
            throw Failure.readOnlySource
        }
    }
}
