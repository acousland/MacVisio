import Foundation

/// Metadata identity for normal external modifications, intentionally cheap
/// enough to check inside NSDocument's coordinated write path.
struct DocumentSourceVersion: Equatable {
    let url: URL
    let device: UInt64
    let inode: UInt64
    let bytes: UInt64
    let modified: Date?

    static func canonical(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }

    static func read(_ url: URL) throws -> DocumentSourceVersion {
        let url = canonical(url)
        let attributes = try FileManager.default.attributesOfItem(atPath:url.path)
        return DocumentSourceVersion(url:url,
            device:(attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0,
            inode:(attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            bytes:(attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modified:attributes[.modificationDate] as? Date)
    }

    func check(contentsAt originalContentsURL: URL? = nil) throws {
        // NSDocument may rename the old file while safely staging a replacement.
        // Its originalContentsURL still names that file, rather than the output.
        guard let current = try? Self.read(originalContentsURL ?? url),
              current.device == device,current.inode == inode,
              current.bytes == bytes,current.modified == modified else { throw DocumentSourceConflict(url:url) }
    }
}

struct DocumentSourceConflict: LocalizedError, CustomNSError {
    let url: URL
    static let errorDomain = "MacVisio.DocumentSourceConflict"
    var errorCode: Int { 1 }
    var errorDescription: String? { "The drawing changed outside MacVisio. Your changes have not replaced it." }
    var recoverySuggestion: String? { "Choose File > Revert to Saved to reload the external version, or File > Save As to keep your edits in a separate copy." }
    var errorUserInfo: [String:Any] {
        [NSLocalizedDescriptionKey:errorDescription!,NSLocalizedRecoverySuggestionErrorKey:recoverySuggestion!,NSURLErrorKey:url]
    }
}
