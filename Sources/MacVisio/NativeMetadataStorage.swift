import Foundation
import Compression

/// Stores large private diagram metadata in OPC parts small enough for the
/// package reader, while leaving public Visio parts unchanged.
enum NativeMetadataStorage {
    static let segmentDirectory = "macvisio/metadata/"
    static let segmentExtension = "mvmeta"
    static let maximumSegments = 8
    static let maximumCompressedBytes = VisioPackage.totalLimit
    static let maximumDecodedBytes = 512 * 1024 * 1024

    private static let partLimit = VisioPackage.partLimit
    private static let streamBufferSize = 64 * 1024

    private struct Manifest: Codable {
        let format: Int
        let totalBytes: Int
        let segments: [Segment]
        let encoding: String?
        let decodedBytes: Int?
    }

    private struct Segment: Codable {
        let name: String
        let bytes: Int
        let sha256: String
    }

    /// Removes only segment paths owned by this storage format.
    static func removeSegments(from parts: inout [String: Data]) {
        for name in parts.keys.filter(isStrictSegmentName) {
            parts.removeValue(forKey: name)
        }
    }

    /// Adds the OPC default MIME type required by `.mvmeta` parts.
    static func registerContentType(in parts: inout [String: Data]) throws {
        guard let contentTypes = parts["[Content_Types].xml"] else {
            throw DiagramError.invalid("Missing package content types.")
        }
        let document = try VisioXML.document(contentTypes)
        guard let root = document.rootElement(), root.localTag == "Types" else {
            throw DiagramError.invalid("Invalid package content types.")
        }

        let matches = root.elementsLocal("Default").filter {
            $0.attr("Extension")?.lowercased() == segmentExtension
        }
        guard matches.count <= 1 else {
            throw DiagramError.invalid("Conflicting metadata segment content types.")
        }
        if let existing = matches.first {
            guard existing.attr("ContentType") == "application/octet-stream" else {
                throw DiagramError.invalid("The metadata segment extension has a conflicting content type.")
            }
            return
        }

        let entry = XMLElement(name: "Default")
        entry.setAttr("Extension", segmentExtension)
        entry.setAttr("ContentType", "application/octet-stream")
        root.addChild(entry)
        parts["[Content_Types].xml"] = document.xmlData(options: .nodePreserveAll)
    }

    /// Returns raw envelope JSON when it fits in one OPC part. Larger payloads
    /// are zlib-compressed, split into numbered parts, and described by a
    /// format-3 manifest.
    static func store(_ payload: Data, in parts: inout [String: Data]) throws -> Data {
        guard payload.count <= maximumDecodedBytes else {
            throw DiagramError.invalid("Native metadata payload (\(payload.count) bytes) exceeds the 512 MB decoded limit.")
        }
        guard payload.count > partLimit else { return payload }

        let compressed = try transform(payload, operation: COMPRESSION_STREAM_ENCODE, outputLimit: maximumCompressedBytes, expectedOutput: nil)
        guard !compressed.isEmpty, compressed.count <= maximumCompressedBytes else {
            throw DiagramError.invalid("Compressed native metadata (\(compressed.count) bytes) exceeds the 128 MB storage limit.")
        }
        let count = (compressed.count + partLimit - 1) / partLimit
        guard (1...maximumSegments).contains(count) else {
            throw DiagramError.invalid("Compressed native metadata requires too many storage segments.")
        }

        var descriptors: [Segment] = []
        descriptors.reserveCapacity(count)
        var segmentData: [(String, Data)] = []
        segmentData.reserveCapacity(count)
        for index in 0..<count {
            let start = index * partLimit
            let end = min(compressed.count, start + partLimit)
            let name = segmentName(index)
            guard parts[name] == nil else {
                throw DiagramError.invalid("A native metadata segment already exists; remove stale segments first.")
            }
            let data = compressed.subdata(in: start..<end)
            descriptors.append(Segment(name: name, bytes: data.count, sha256: VisioFormat.hash(data)))
            segmentData.append((name, data))
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let manifest = try encoder.encode(Manifest(format: 3, totalBytes: compressed.count, segments: descriptors, encoding: "zlib", decodedBytes: payload.count))
        for (name, data) in segmentData { parts[name] = data }
        return manifest
    }

    /// Loads a raw envelope unchanged or validates and assembles format-3
    /// segments before returning their names for package hash bookkeeping.
    static func load(_ metadata: Data, parts: [String: Data]) throws -> (data: Data, storageParts: Set<String>) {
        guard metadata.count <= partLimit,
              let object = try? JSONSerialization.jsonObject(with: metadata),
              let dictionary = object as? [String: Any],
              let format = dictionary["format"] as? Int else {
            throw DiagramError.invalid("Invalid native metadata manifest.")
        }
        if format == 1 || format == 2 || format == 4 { return (metadata, []) }
        guard format == 3 else { throw DiagramError.invalid("Unsupported native metadata format.") }

        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: metadata) }
        catch { throw DiagramError.invalid("Invalid native metadata manifest.") }

        let count = manifest.segments.count
        let isZlib: Bool
        switch manifest.encoding {
        case "zlib":
            isZlib = true
            guard (1...maximumSegments).contains(count),
                  manifest.totalBytes > 0,
                  manifest.totalBytes <= maximumCompressedBytes,
                  let decodedBytes = manifest.decodedBytes,
                  decodedBytes > partLimit,
                  decodedBytes <= maximumDecodedBytes else {
                throw DiagramError.invalid("Invalid compressed native metadata size or segment count.")
            }
        case nil:
            isZlib = false
            guard manifest.decodedBytes == nil,
                  (2...maximumSegments).contains(count),
                  manifest.totalBytes > partLimit,
                  manifest.totalBytes <= maximumCompressedBytes else {
                throw DiagramError.invalid("Invalid legacy native metadata size or segment count.")
            }
        default:
            throw DiagramError.invalid("Unsupported native metadata encoding.")
        }
        guard manifest.format == 3 else {
            throw DiagramError.invalid("Invalid native metadata segment count or size.")
        }

        var names = Set<String>()
        var total = 0
        var assembled = Data()
        assembled.reserveCapacity(manifest.totalBytes)

        for (index, descriptor) in manifest.segments.enumerated() {
            let expectedName = segmentName(index)
            guard descriptor.name == expectedName,
                  isStrictSegmentName(descriptor.name),
                  names.insert(descriptor.name).inserted,
                  descriptor.bytes > 0,
                  descriptor.bytes <= partLimit,
                  (index == count - 1 || descriptor.bytes == partLimit),
                  descriptor.sha256.count == 64,
                  descriptor.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let data = parts[descriptor.name],
                  data.count == descriptor.bytes,
                  VisioFormat.hash(data) == descriptor.sha256,
                  total <= maximumCompressedBytes - descriptor.bytes else {
                throw DiagramError.invalid("Invalid native metadata segment descriptor or data.")
            }
            total += descriptor.bytes
            assembled.append(data)
        }

        let presentSegments = Set(parts.keys.filter(isStrictSegmentName))
        guard total == manifest.totalBytes, assembled.count == manifest.totalBytes,
              names == presentSegments else {
            throw DiagramError.invalid("Native metadata segment totals do not match the manifest.")
        }
        if isZlib {
            let decoded = try transform(assembled, operation: COMPRESSION_STREAM_DECODE, outputLimit: manifest.decodedBytes!, expectedOutput: manifest.decodedBytes)
            guard decoded.count == manifest.decodedBytes else {
                throw DiagramError.invalid("Decoded native metadata length does not match its manifest.")
            }
            return (decoded, names)
        }
        return (assembled, names)
    }

    private static func transform(
        _ input: Data,
        operation: compression_stream_operation,
        outputLimit: Int,
        expectedOutput: Int?
    ) throws -> Data {
        guard !input.isEmpty else { throw DiagramError.invalid("Empty native metadata compression stream.") }
        let outputBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: streamBufferSize)
        defer { outputBuffer.deallocate() }

        return try input.withUnsafeBytes { rawInput in
            guard let inputBuffer = rawInput.bindMemory(to: UInt8.self).baseAddress else {
                throw DiagramError.invalid("Missing native metadata compression input.")
            }
            var stream = compression_stream(
                dst_ptr: outputBuffer,
                dst_size: 0,
                src_ptr: inputBuffer,
                src_size: 0,
                state: nil
            )
            guard compression_stream_init(&stream, operation, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
                throw DiagramError.invalid("Could not initialize native metadata zlib stream.")
            }
            defer { _ = compression_stream_destroy(&stream) }

            var output = Data()
            var inputOffset = 0
            var finalizing = false
            while true {
                if stream.src_size == 0, inputOffset < input.count {
                    let amount = min(streamBufferSize, input.count - inputOffset)
                    stream.src_ptr = inputBuffer.advanced(by: inputOffset)
                    stream.src_size = amount
                    inputOffset += amount
                    finalizing = inputOffset == input.count
                }

                stream.dst_ptr = outputBuffer
                stream.dst_size = streamBufferSize
                let previousSourceSize = stream.src_size
                let flags = finalizing ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
                let status = compression_stream_process(&stream, flags)
                let produced = streamBufferSize - stream.dst_size

                guard produced <= outputLimit - output.count else {
                    throw DiagramError.invalid("Native metadata zlib output (at least \(output.count + produced) bytes) exceeds its bounded size limit.")
                }
                if produced > 0 { output.append(outputBuffer, count: produced) }
                if let expectedOutput, output.count > expectedOutput {
                    throw DiagramError.invalid("Decoded native metadata exceeds its declared length.")
                }

                if status == COMPRESSION_STATUS_END {
                    guard stream.src_size == 0, inputOffset == input.count else {
                        throw DiagramError.invalid("Native metadata zlib stream has trailing data.")
                    }
                    break
                }
                guard status == COMPRESSION_STATUS_OK else {
                    throw DiagramError.invalid("Invalid native metadata zlib stream.")
                }

                let consumed = previousSourceSize - stream.src_size
                guard consumed > 0 || produced > 0 else {
                    throw DiagramError.invalid("Native metadata zlib stream made no progress.")
                }
            }
            if let expectedOutput, output.count != expectedOutput {
                throw DiagramError.invalid("Decoded native metadata length does not match its manifest.")
            }
            return output
        }
    }

    private static func segmentName(_ index: Int) -> String {
        "\(segmentDirectory)segment\(index).\(segmentExtension)"
    }

    private static func isStrictSegmentName(_ name: String) -> Bool {
        let prefix = "\(segmentDirectory)segment"
        guard name.hasPrefix(prefix), name.hasSuffix(".\(segmentExtension)") else { return false }
        let number = name.dropFirst(prefix.count).dropLast(".\(segmentExtension)".count)
        guard !number.isEmpty, number == "0" || number.first != "0",
              number.utf8.allSatisfy({ (48...57).contains($0) }) else { return false }
        return Int(number) != nil
    }
}
