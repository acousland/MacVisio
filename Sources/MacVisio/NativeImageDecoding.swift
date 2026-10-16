import CoreGraphics
import Foundation
import ImageIO
import MacVisioInfrastructure

/// Bounds declared raster dimensions before requesting pixels. ImageIO remains
/// an in-process codec: this is not a CPU, parser-scratch or codec sandbox.
/// Original embedded bytes are never changed. No vector/resource loader runs.
enum NativeImageDecoding {
    struct Limits {
        var maximumEncodedBytes = VisioPackage.partLimit
        var maximumAllocationBytes = ResourceBudgets.decodedImages
        var maximumDimension = 32_768
        var maximumPixels = 16_000_000
    }
    enum Format: String { case png, jpeg, gif, tiff, bmp }
    struct RasterInfo {
        let format: Format
        let width: Int
        let height: Int
        let depth: Int
        let orientation: Int
        let frameCount: Int
        let nativeByteAllowance: Int
        /// Source + native frame + RGBA8 context and possible image copy.
        let allocationCharge: Int
        var pixelSize: CGSize {
            orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
        }
    }
    struct Decoded {
        let cgImage: CGImage
        let info: RasterInfo
        /// Retained RGBA pixels plus the source used as the image cache key.
        let cacheCost: Int
        var pixelSize: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }
    }
    enum Failure: Error, Equatable, LocalizedError {
        case invalidLimits, encodedLimit, unsupportedFormat, mimeMismatch
        case vectorPreviewUnavailable, multipleFrames, incompleteData, invalidMetadata
        case dimensionLimit, pixelLimit, allocationLimit, decodeFailed, decodedMismatch
        var errorDescription: String? {
            switch self {
            case .invalidLimits: return "The image preview limits are invalid."
            case .encodedLimit: return "The encoded image exceeds the supported byte limit."
            case .unsupportedFormat: return "This embedded image format has no supported bounded raster preview."
            case .mimeMismatch: return "The image's declared format does not match its raster content."
            case .vectorPreviewUnavailable: return "PDF/SVG bytes are preserved, but this bounded raster preview does not render vector content."
            case .multipleFrames: return "Animated or multipage images are preserved but have no static-only bounded preview."
            case .incompleteData: return "The embedded raster image is incomplete."
            case .invalidMetadata: return "The raster image has missing or invalid size, depth or color metadata."
            case .dimensionLimit: return "The raster image exceeds the supported dimension limit."
            case .pixelLimit: return "The raster image exceeds the supported pixel limit."
            case .allocationLimit: return "The raster image exceeds the decoded allocation budget."
            case .decodeFailed: return "The raster image could not be decoded."
            case .decodedMismatch: return "The decoded raster does not match its validated metadata or byte allowance."
            }
        }
    }

    static func preflight(data: Data, mimeType: String? = nil, limits: Limits = Limits()) throws -> RasterInfo {
        try validatedSource(data, mimeType: mimeType, limits: limits).info
    }
    static func decode(data: Data, mimeType: String? = nil, limits: Limits = Limits()) throws -> Decoded {
        try decode(data: data, mimeType: mimeType, limits: limits) { source in
            CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: true,
                kCGImageSourceShouldCacheImmediately: true, kCGImageSourceShouldAllowFloat: false] as CFDictionary)
        }
    }
    /// Injection is only at the pixel boundary: callers cannot supply a forged
    /// preflight token to bypass the same source/metadata checks.
    static func decode(data: Data, mimeType: String? = nil, limits: Limits = Limits(),
                       decodeImage: (CGImageSource) -> CGImage?) throws -> Decoded {
        let (source, info) = try validatedSource(data, mimeType: mimeType, limits: limits)
        guard let image = decodeImage(source) else { throw Failure.decodeFailed }
        let nativeBytes = try product(image.bytesPerRow, image.height)
        guard image.width == info.width, image.height == info.height,
              image.bitsPerComponent > 0, image.bitsPerComponent <= 16, image.bitsPerPixel > 0, image.bitsPerPixel <= 64,
              !image.bitmapInfo.contains(.floatComponents), nativeBytes <= info.nativeByteAllowance,
              supportedColorSpace(image.colorSpace) else { throw Failure.decodedMismatch }
        let minimumRow = try sum(try product(image.width, image.bitsPerPixel), 7) / 8
        guard image.bytesPerRow >= minimumRow else { throw Failure.decodedMismatch }
        let width = info.orientation >= 5 ? info.height : info.width
        let height = info.orientation >= 5 ? info.width : info.height
        let row = try product(width, 4)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: row, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { throw Failure.decodeFailed }
        context.concatenate(orientationTransform(info.orientation, width: info.width, height: info.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: info.width, height: info.height))
        guard let normalized = context.makeImage() else { throw Failure.decodeFailed }
        let retained = try sum(try product(normalized.bytesPerRow, normalized.height), data.count)
        guard retained <= limits.maximumAllocationBytes else { throw Failure.decodedMismatch }
        return Decoded(cgImage: normalized, info: info, cacheCost: retained)
    }

    private static func validatedSource(_ data: Data, mimeType: String?, limits: Limits) throws -> (source: CGImageSource, info: RasterInfo) {
        guard limits.maximumEncodedBytes > 0, limits.maximumEncodedBytes <= VisioPackage.partLimit,
              limits.maximumAllocationBytes > 0, limits.maximumAllocationBytes <= ResourceBudgets.decodedImages,
              limits.maximumDimension > 0, limits.maximumDimension <= 32_768,
              limits.maximumPixels > 0, limits.maximumPixels <= 16_000_000 else { throw Failure.invalidLimits }
        guard !data.isEmpty, data.count <= limits.maximumEncodedBytes else { throw Failure.encodedLimit }
        guard data.count < limits.maximumAllocationBytes else { throw Failure.allocationLimit }
        let mime = mimeType?.split(separator: ";", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if mime == "application/pdf" || mime == "image/svg+xml" {
            throw Failure.vectorPreviewUnavailable
        }
        // This gate precedes any format parser. In particular SVG/PDF do not
        // enter a platform image loader, even when MIME metadata is absent.
        guard let format = sniff(data) else {
            let prefix = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
            if data.starts(with: Data("%PDF-".utf8)) || prefix.contains("<svg") { throw Failure.vectorPreviewUnavailable }
            throw Failure.unsupportedFormat
        }
        if let mime, !mime.isEmpty, mime != "application/octet-stream", !mimes(format).contains(mime) { throw Failure.mimeMismatch }
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false, kCGImageSourceShouldAllowFloat: false,
                                      kCGImageSourceTypeIdentifierHint: uti(format)]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
              CGImageSourceGetType(source).map({ $0 as String }) == uti(format) else { throw Failure.unsupportedFormat }
        let count = CGImageSourceGetCount(source)
        guard count == 1 else { throw count > 1 ? Failure.multipleFrames : Failure.incompleteData }
        guard let metadata = CGImageSourceCopyPropertiesAtIndex(source, 0, options as CFDictionary) as? [String: Any] else { throw Failure.invalidMetadata }
        let info = try validateMetadata(metadata, format: format, sourceBytes: data.count, frameCount: count, limits: limits)
        guard CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { throw Failure.incompleteData }
        return (source, info)
    }

    static func validateMetadata(_ metadata: [String: Any], format: Format, sourceBytes: Int,
                                 frameCount: Int, limits: Limits) throws -> RasterInfo {
        guard frameCount == 1 else { throw Failure.multipleFrames }
        let width = try integer(metadata[kCGImagePropertyPixelWidth as String])
        let height = try integer(metadata[kCGImagePropertyPixelHeight as String])
        let depth = try integer(metadata[kCGImagePropertyDepth as String])
        guard depth <= 16, let color = metadata[kCGImagePropertyColorModel as String] as? String,
              ["RGB", "Gray", "CMYK"].contains(color),
              !(color == "CMYK" && (metadata[kCGImagePropertyHasAlpha as String] as? NSNumber)?.boolValue == true) else { throw Failure.invalidMetadata }
        let orientation = try metadata[kCGImagePropertyOrientation as String].map { try integer($0) } ?? 1
        guard orientation <= 8 else { throw Failure.invalidMetadata }
        guard width <= limits.maximumDimension, height <= limits.maximumDimension else { throw Failure.dimensionLimit }
        guard try product(width, height) <= limits.maximumPixels else { throw Failure.pixelLimit }
        // Up to four 16-bit components, with conservative 64-byte row padding;
        // reserve both the RGBA8 context and a possible makeImage copy while
        // the native frame remains alive. Codec scratch remains unisolated.
        let rawRow = try product(width, 8)
        let paddedRow = try product(try sum(rawRow, 63) / 64, 64)
        let native = try product(paddedRow, height)
        let output = try product(try product(width, height), 8)
        let charge = try sum(try sum(native, output), sourceBytes)
        guard sourceBytes >= 0, charge <= limits.maximumAllocationBytes else { throw Failure.allocationLimit }
        return RasterInfo(format: format, width: width, height: height, depth: depth, orientation: orientation,
                          frameCount: frameCount, nativeByteAllowance: native, allocationCharge: charge)
    }
    private static func integer(_ value: Any?) throws -> Int {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, let result = Int(exactly: value.doubleValue), result > 0 else { throw Failure.invalidMetadata }
        return result
    }
    private static func supportedColorSpace(_ space: CGColorSpace?) -> Bool {
        guard let space else { return false }
        if [.rgb, .monochrome, .cmyk].contains(space.model) { return true }
        // Palette PNG/GIF can remain indexed on decode. Their bounded table
        // must have a known RGB/Gray base before conversion into owned RGBA.
        guard space.model == .indexed, let base = space.baseColorSpace,
              [.rgb, .monochrome].contains(base.model), let table = space.colorTable,
              base.numberOfComponents > 0, table.count % base.numberOfComponents == 0 else { return false }
        return (1...256).contains(table.count / base.numberOfComponents)
    }
    private static func product(_ a: Int, _ b: Int) throws -> Int {
        let result = a.multipliedReportingOverflow(by: b)
        guard a >= 0, b >= 0, !result.overflow else { throw Failure.allocationLimit }; return result.partialValue
    }
    private static func sum(_ a: Int, _ b: Int) throws -> Int {
        let result = a.addingReportingOverflow(b)
        guard a >= 0, b >= 0, !result.overflow else { throw Failure.allocationLimit }; return result.partialValue
    }
    private static func sniff(_ data: Data) -> Format? {
        if data.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { return .png }
        if data.starts(with: [255, 216, 255]) { return .jpeg }
        if data.starts(with: Data("GIF87a".utf8)) || data.starts(with: Data("GIF89a".utf8)) { return .gif }
        if data.starts(with: [73, 73, 42, 0]) || data.starts(with: [77, 77, 0, 42]) { return .tiff }
        if data.starts(with: [66, 77]) { return .bmp }
        return nil
    }
    private static func uti(_ format: Format) -> String {
        switch format {
        case .png: return "public.png"
        case .jpeg: return "public.jpeg"
        case .gif: return "com.compuserve.gif"
        case .tiff: return "public.tiff"
        case .bmp: return "com.microsoft.bmp"
        }
    }
    private static func mimes(_ format: Format) -> Set<String> {
        switch format {
        case .png: return ["image/png", "image/x-png"]
        case .jpeg: return ["image/jpeg", "image/jpg"]
        case .gif: return ["image/gif"]
        case .tiff: return ["image/tiff", "image/x-tiff"]
        case .bmp: return ["image/bmp", "image/x-ms-bmp"]
        }
    }
    private static func orientationTransform(_ orientation: Int, width: Int, height: Int) -> CGAffineTransform {
        let w = CGFloat(width), h = CGFloat(height)
        switch orientation {
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case 6: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 7: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: return .identity
        }
    }
}
