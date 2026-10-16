import CoreGraphics
import ImageIO
import XCTest
@testable import MacVisio

final class NativeImageDecodingTests: XCTestCase {
    func testStaticRasterFormatsPreflightAndDecodeIntoOwnedRGBA() throws {
        for (uti, mime) in [("public.png", "image/png"), ("public.jpeg", "image/jpeg"),
                            ("public.tiff", "image/tiff"), ("com.compuserve.gif", "image/gif"), ("com.microsoft.bmp", "image/bmp")] {
            let data = try encoded(uti), before = data
            let info = try NativeImageDecoding.preflight(data: data, mimeType: mime)
            XCTAssertEqual(info.width, 2, uti); XCTAssertEqual(info.height, 3, uti); XCTAssertEqual(info.frameCount, 1, uti)
            let result = try NativeImageDecoding.decode(data: data, mimeType: mime)
            XCTAssertEqual(result.cgImage.width, 2); XCTAssertEqual(result.cgImage.height, 3)
            XCTAssertEqual(result.cgImage.bitsPerComponent, 8); XCTAssertEqual(result.cgImage.bitsPerPixel, 32)
            XCTAssertEqual(result.cacheCost, result.cgImage.bytesPerRow * 3 + data.count)
            XCTAssertLessThanOrEqual(result.cacheCost, info.allocationCharge); XCTAssertEqual(data, before)
        }
    }
    func testOversizedPNGHeaderNeverReachesPixelDecoder() throws {
        var data = try encoded("public.png")
        // IHDR width and CRC are updated; the tiny payload must never decode.
        let width: UInt32 = 100_000
        for index in 0..<4 { data[16 + index] = UInt8(truncatingIfNeeded: width >> (24 - index * 8)) }
        let crc = crc32(data[12..<29])
        for index in 0..<4 { data[29 + index] = UInt8(truncatingIfNeeded: crc >> (24 - index * 8)) }
        var calls = 0
        XCTAssertThrowsError(try NativeImageDecoding.decode(data: data) { _ in calls += 1; return nil })
        XCTAssertEqual(calls, 0, "Declared size must be rejected before a pixel decoder runs")
    }
    func testIndexedPalettePNGAndGIFNormalizeThroughKnownRGBBase() throws {
        let palette: [UInt8] = [255, 0, 0, 0, 255, 0]
        let space = try XCTUnwrap(CGColorSpace(indexedBaseSpace: CGColorSpaceCreateDeviceRGB(), last: 1, colorTable: palette))
        let provider = try XCTUnwrap(CGDataProvider(data: Data([0, 1, 1, 0, 0, 1]) as CFData))
        let indexed = try XCTUnwrap(CGImage(width: 2, height: 3, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: 2, space: space, bitmapInfo: [], provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
        XCTAssertEqual(indexed.colorSpace?.model, .indexed)
        for uti in ["public.png", "com.compuserve.gif"] {
            let output = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output as CFMutableData, uti as CFString, 1, nil))
            CGImageDestinationAddImage(destination, indexed, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
            let data = output as Data
            let actual = try NativeImageDecoding.decode(data: data)
            XCTAssertEqual(actual.cgImage.colorSpace?.model, .rgb); XCTAssertEqual(actual.cgImage.bitsPerPixel, 32)
            // Platform codecs may expand a palette. This also exercises the
            // indexed branch deterministically without depending on expansion.
            let retainedPalette = try NativeImageDecoding.decode(data: data) { _ in indexed }
            XCTAssertEqual(retainedPalette.cgImage.colorSpace?.model, .rgb)
            XCTAssertLessThanOrEqual(retainedPalette.cacheCost, retainedPalette.info.allocationCharge)
        }
    }
    func testSVGTextInsideValidRasterMetadataIsNotClassifiedAsVector() throws {
        var data = try encoded("public.png")
        let type = Data("tEXt".utf8), payload = Data("Comment\0<svg xmlns='http://www.w3.org/2000/svg'/>".utf8)
        let length = UInt32(payload.count), checksum = crc32(type + payload)
        var chunk = Data((0..<4).map { UInt8(truncatingIfNeeded: length >> (24 - $0 * 8)) })
        chunk.append(type); chunk.append(payload)
        chunk.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: checksum >> (24 - $0 * 8)) })
        data.insert(contentsOf: chunk, at: 33)
        XCTAssertTrue(String(decoding: data.prefix(512), as: UTF8.self).contains("<svg"))
        XCTAssertEqual(try NativeImageDecoding.decode(data: data).info.format.rawValue, "png")
    }
    func testFiniteIntegralRequiredMetadataAndCheckedArithmetic() throws {
        let limits = NativeImageDecoding.Limits()
        for invalid in [NSNumber(value: 0), NSNumber(value: -1), NSNumber(value: 1.5), NSNumber(value: Double.infinity),
                        NSNumber(value: Double.nan), NSNumber(value: true), NSNumber(value: UInt64.max)] {
            var values = metadata(); values[kCGImagePropertyPixelWidth as String] = invalid
            XCTAssertThrowsError(try NativeImageDecoding.validateMetadata(values, format: .png, sourceBytes: 1, frameCount: 1, limits: limits))
        }
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth, kCGImagePropertyColorModel] {
            var values = metadata(); values.removeValue(forKey: key as String)
            XCTAssertThrowsError(try NativeImageDecoding.validateMetadata(values, format: .png, sourceBytes: 1, frameCount: 1, limits: limits))
        }
        var wideLimits = limits; wideLimits.maximumDimension = Int.max; wideLimits.maximumPixels = Int.max
        var huge = metadata(); huge[kCGImagePropertyPixelWidth as String] = NSNumber(value: 1 << 40)
        huge[kCGImagePropertyPixelHeight as String] = NSNumber(value: 1 << 40)
        XCTAssertThrowsError(try NativeImageDecoding.validateMetadata(huge, format: .png, sourceBytes: 1, frameCount: 1, limits: wideLimits)) {
            XCTAssertEqual($0 as? NativeImageDecoding.Failure, .allocationLimit)
        }
    }
    func testExactEncodedPixelAndAllocationLimitsAreInclusive() throws {
        let data = try encoded("public.png"), info = try NativeImageDecoding.preflight(data: data)
        var limits = NativeImageDecoding.Limits(); limits.maximumEncodedBytes = data.count
        limits.maximumPixels = 6; limits.maximumAllocationBytes = info.allocationCharge
        XCTAssertNoThrow(try NativeImageDecoding.decode(data: data, limits: limits))
        limits.maximumAllocationBytes -= 1
        XCTAssertThrowsError(try NativeImageDecoding.preflight(data: data, limits: limits)) { XCTAssertEqual($0 as? NativeImageDecoding.Failure, .allocationLimit) }
        limits.maximumAllocationBytes = info.allocationCharge; limits.maximumPixels = 5
        XCTAssertThrowsError(try NativeImageDecoding.preflight(data: data, limits: limits)) { XCTAssertEqual($0 as? NativeImageDecoding.Failure, .pixelLimit) }
        limits.maximumPixels = 6; limits.maximumEncodedBytes = data.count - 1
        XCTAssertThrowsError(try NativeImageDecoding.preflight(data: data, limits: limits)) { XCTAssertEqual($0 as? NativeImageDecoding.Failure, .encodedLimit) }
        limits.maximumEncodedBytes = data.count; limits.maximumAllocationBytes = data.count
        var calls = 0
        XCTAssertThrowsError(try NativeImageDecoding.decode(data: data, limits: limits) { _ in calls += 1; return nil }) {
            XCTAssertEqual($0 as? NativeImageDecoding.Failure, .allocationLimit)
        }
        XCTAssertEqual(calls, 0)
    }
    func testMultiFrameGIFAndTIFFAreRejectedBeforeAnyFrameDecode() throws {
        for uti in ["com.compuserve.gif", "public.tiff"] {
            let data = try encoded(uti, frames: 2); var calls = 0
            let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
            XCTAssertEqual(CGImageSourceGetCount(source), 2, "The \(uti) fixture must actually contain two distinct frames")
            XCTAssertThrowsError(try NativeImageDecoding.decode(data: data) { _ in calls += 1; return nil }) {
                XCTAssertEqual($0 as? NativeImageDecoding.Failure, .multipleFrames)
            }
            XCTAssertEqual(calls, 0)
        }
    }
    func testVectorAndExternalSVGResourcesNeverReachPlatformImageDecoder() {
        let inputs = [(Data("<svg xmlns='http://www.w3.org/2000/svg'><image href='https://example.invalid/image.png'/><script>fetch('https://example.invalid/')</script></svg>".utf8), "image/svg+xml"),
                      (Data("%PDF-1.7\n/OpenAction << /S /JavaScript /JS (app.alert('no')) >>".utf8), "application/pdf")]
        for (data, mime) in inputs {
            let embedded = EmbeddedImage(data: data, mimeType: mime), before = embedded
            var calls = 0
            XCTAssertThrowsError(try NativeImageDecoding.decode(data: embedded.data, mimeType: embedded.mimeType) { _ in calls += 1; return nil }) {
                XCTAssertEqual($0 as? NativeImageDecoding.Failure, .vectorPreviewUnavailable)
            }
            XCTAssertEqual(calls, 0); XCTAssertEqual(embedded, before)
        }
    }
    func testTruncatedUnknownAndMismatchedInputsFailClosed() throws {
        let data = try encoded("public.png")
        for bad in [Data(), Data([0, 1, 2]), Data(data.prefix(40))] {
            var calls = 0
            XCTAssertThrowsError(try NativeImageDecoding.decode(data: bad) { _ in calls += 1; return nil })
            XCTAssertEqual(calls, 0)
        }
        XCTAssertThrowsError(try NativeImageDecoding.preflight(data: data, mimeType: "image/jpeg")) { XCTAssertEqual($0 as? NativeImageDecoding.Failure, .mimeMismatch) }
        var invalid = NativeImageDecoding.Limits(); invalid.maximumAllocationBytes = Int.max
        XCTAssertThrowsError(try NativeImageDecoding.preflight(data: data, limits: invalid)) { XCTAssertEqual($0 as? NativeImageDecoding.Failure, .invalidLimits) }
    }
    func testDecodedDimensionsAndActualStrideAreRevalidated() throws {
        let data = try encoded("public.png")
        let wrongSize = try image(width: 4, height: 4)
        XCTAssertThrowsError(try NativeImageDecoding.decode(data: data) { _ in wrongSize }) { XCTAssertEqual($0 as? NativeImageDecoding.Failure, .decodedMismatch) }
        let padded = try image(width: 2, height: 3, bytesPerRow: 512)
        XCTAssertThrowsError(try NativeImageDecoding.decode(data: data) { _ in padded }) { XCTAssertEqual($0 as? NativeImageDecoding.Failure, .decodedMismatch) }
    }
    func testUnsupportedDepthColorAndOrientationMetadataFailClosed() {
        for (key, value) in [(kCGImagePropertyDepth as String, 32 as Any), (kCGImagePropertyColorModel as String, "Lab" as Any),
                              (kCGImagePropertyOrientation as String, 9 as Any)] {
            var values = metadata(); values[key] = value
            XCTAssertThrowsError(try NativeImageDecoding.validateMetadata(values, format: .png, sourceBytes: 1, frameCount: 1, limits: .init())) {
                XCTAssertEqual($0 as? NativeImageDecoding.Failure, .invalidMetadata)
            }
        }
    }
    func testOrientationNormalizationKeepsPixelAreaAndRGBAChargeBounded() throws {
        for orientation in 1...8 {
            let data = try encoded("public.tiff", orientation: orientation)
            let result = try NativeImageDecoding.decode(data: data)
            XCTAssertEqual(result.info.orientation, orientation)
            XCTAssertEqual(result.cgImage.width, orientation >= 5 ? 3 : 2)
            XCTAssertEqual(result.cgImage.height, orientation >= 5 ? 2 : 3)
            XCTAssertEqual(result.cgImage.width * result.cgImage.height, 6)
            XCTAssertLessThanOrEqual(result.cacheCost, result.info.allocationCharge)
        }
    }
    private func metadata() -> [String: Any] {
        [kCGImagePropertyPixelWidth as String: 2, kCGImagePropertyPixelHeight as String: 3,
         kCGImagePropertyDepth as String: 8, kCGImagePropertyColorModel as String: "RGB"]
    }
    private func image(width: Int = 2, height: Int = 3, bytesPerRow: Int? = nil, variant: Int = 0) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: bytesPerRow ?? width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setFillColor(variant.isMultiple(of: 2) ? CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
                             : CGColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
    private func encoded(_ uti: String, frames: Int = 1, orientation: Int = 1) throws -> Data {
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output as CFMutableData, uti as CFString, frames, nil))
        for frame in 0..<frames {
            var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
            if uti == "com.compuserve.gif" { properties[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFDelayTime: 0.1] }
            CGImageDestinationAddImage(destination, try image(variant: frame), properties as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination)); return output as Data
    }
    private func crc32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc = UInt32.max
        for byte in bytes { crc ^= UInt32(byte); for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xEDB88320 : 0) } }
        return ~crc
    }
}
