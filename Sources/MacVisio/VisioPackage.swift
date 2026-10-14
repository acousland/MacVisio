import Foundation
import ZIPFoundation

/// An OPC package kept in memory. Files are never extracted into the user's filesystem.
enum VisioPackage {
    static let partLimit = 16 * 1024 * 1024
    static let totalLimit = 128 * 1024 * 1024
    static func validatePath(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
              !name.contains("\0"), !name.contains("\r"), !name.contains("\n"), name.utf8.count <= 1024,
              !name.split(separator: "/").contains(".."), !name.split(separator: "/").contains(".") else {
            throw DiagramError.invalid("The package contains an unsafe part name.")
        }
    }
    static func read(_ url: URL) throws -> [String: Data] {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 100 * 1024 * 1024 else { throw DiagramError.invalid("The Visio archive exceeds the 100 MB import limit.") }
        let archive = try Archive(url: url, accessMode: .read)
        var parts: [String: Data] = [:], seen = Set<String>(), total = 0
        for entry in archive {
            let name = entry.path
            try validatePath(name)
            guard seen.insert(name).inserted, seen.count <= 10000, entry.type != .symlink else { throw DiagramError.invalid("The archive contains duplicate, linked or too many entries.") }
            if entry.type == .directory { continue }
            guard entry.type == .file, entry.uncompressedSize <= UInt64(partLimit) else { throw DiagramError.invalid("A Visio package part exceeds the supported size limit.") }
            var data = Data()
            let checksum = try archive.extract(entry, bufferSize: 65536, skipCRC32: false) { chunk in
                guard data.count + chunk.count <= partLimit, total + chunk.count <= totalLimit else { throw DiagramError.invalid("The Visio drawing exceeds the supported import size limit.") }
                data.append(chunk); total += chunk.count
            }
            guard checksum == entry.checksum else { throw DiagramError.invalid("A Visio package part failed its checksum.") }
            parts[name] = data
        }
        guard parts["[Content_Types].xml"] != nil, parts["_rels/.rels"] != nil else { throw DiagramError.invalid("This file is not an OPC Visio drawing.") }
        return parts
    }
    static func write(_ parts: [String: Data], to url: URL) throws {
        guard parts.count <= 10000, parts.values.allSatisfy({ $0.count <= partLimit }),
              parts.values.reduce(0, { $0 + $1.count }) <= totalLimit else { throw DiagramError.invalid("The drawing exceeds the Visio package size limit.") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-package-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let temp = directory.appendingPathComponent("drawing.zip")
        do {
            let archive = try Archive(url: temp, accessMode: .create)
            for name in parts.keys.sorted() {
                try validatePath(name)
                let data = parts[name]!
                try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { position, count in
                    data.subdata(in: Int(position)..<min(data.count, Int(position)+count))
                }
            }
        }
        try Data(contentsOf: temp).write(to: url, options: .atomic)
    }
}

struct VisioDocumentArchive: Codable, Equatable {
    var parts: [String: Data]
    var pagesPart: String
    var pages: [VisioPageBinding]
    var connectorHierarchyVersion:Int? = nil
}

struct VisioPageBinding: Codable, Equatable {
    var pageID: UUID
    var visioID: String
    var part: String
    var original: DiagramPage
    var nodeIDs: [UUID: String]
    var edgeIDs: [UUID: String]
    // Model-only descendants do not have a page XML element until edited. Keep
    // their master identity so a save can emit a local override, not a duplicate.
    var inheritedShapes: [UUID: VisioInheritedShape]? = nil
}

struct VisioInheritedShape: Codable, Equatable {
    var masterShapeID: String
    var parentID: UUID
    var implicit: Bool
}
