import AppKit
import CryptoKit
import ImageIO
import MacVisioInfrastructure
import XCTest
@testable import MacVisio

final class M3RasterFormatTests: XCTestCase {
    private let formats: [OwnedExportFormat] = [.jpeg, .tiff]
    private func fixture() -> Diagram {
        var model = Diagram(); model.page.width = 200; model.page.height = 150
        model.page.nodes = [node(40, 30, 60, 35, "#FF0000")]; return model
    }
    private func node(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ fill: String) -> DiagramNode {
        var node = DiagramNode(x: x, y: y, text: ""); node.width = width; node.height = height
        node.fill = fill; node.stroke = "#FFFFFF00"; node.strokeWidth = 0; return node
    }
    private func identity(_ owner: LifecycleJobOwner) -> LifecycleJobInput {
        LifecycleJobInput(ownerID: owner.id, snapshotID: UUID(), revision: 9)
    }
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("M3-raster-formats-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }; return try DispatchQueue.main.sync(execute: body)
    }
    private func pump(_ done: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(30)
        while !done() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        guard done() else { throw DiagramError.invalid("Raster format completion timed out") }
    }

    func testActualJPEGAndTIFFFilesHaveExpectedTypeMagicAndSingleFrame() throws {
        try onMain {
            _ = NSApplication.shared
            for format in formats {
                let artifact = try export(fixture(), format: format, region: .page)
                XCTAssertEqual(artifact.type, format == .jpeg ? "public.jpeg" : "public.tiff")
                XCTAssertEqual(artifact.count, 1); XCTAssertEqual(artifact.pixels.width, 200); XCTAssertEqual(artifact.pixels.height, 150)
                if format == .jpeg { XCTAssertEqual(Array(artifact.data.prefix(2)), [0xFF, 0xD8]) }
                else {
                    let signature = Array(artifact.data.prefix(4))
                    XCTAssertTrue(signature == [0x49, 0x49, 42, 0] || signature == [0x4D, 0x4D, 0, 42])
                }
            }
        }
    }

    func testJPEGFlattensPartlyTransparentArtworkOnFixedOpaqueWhite() throws {
        try onMain {
            _ = NSApplication.shared
            var model = fixture(); model.page.nodes = [node(40, 55, 60, 40, "#0000FF80")]
            let artifact = try export(model, format: .jpeg, region: .page, quality: .maximum)
            let corner = artifact.pixels.pixel(2, 2), center = artifact.pixels.pixel(65, 75)
            XCTAssertEqual(corner.a, 255); XCTAssertGreaterThan(corner.r, 248); XCTAssertGreaterThan(corner.g, 248); XCTAssertGreaterThan(corner.b, 248)
            XCTAssertEqual(center.a, 255); XCTAssertEqual(Double(center.r), 127, accuracy: 6)
            XCTAssertEqual(Double(center.g), 127, accuracy: 6); XCTAssertGreaterThan(center.b, 248)
            XCTAssertFalse(artifact.hasAlpha)
        }
    }

    func testTIFFPreservesSupportedAlphaAndCanExplicitlyFillWhite() throws {
        try onMain {
            _ = NSApplication.shared
            var model = fixture(); model.page.nodes = [node(40, 55, 60, 40, "#0000FF80")]
            let alpha = try export(model, format: .tiff, region: .page, transparent: true)
            let white = try export(model, format: .tiff, region: .page)
            XCTAssertTrue(alpha.hasAlpha); XCTAssertEqual(alpha.pixels.pixel(2, 2).a, 0)
            XCTAssertEqual(Double(alpha.pixels.pixel(65, 75).a), 128, accuracy: 1)
            XCTAssertEqual(Double(alpha.pixels.pixel(65, 75).b), 128, accuracy: 1)
            XCTAssertEqual(white.pixels.pixel(2, 2).a, 255); XCTAssertEqual(white.pixels.pixel(2, 2).r, 255)
            XCTAssertEqual(white.pixels.pixel(65, 75).a, 255); XCTAssertEqual(Double(white.pixels.pixel(65, 75).r), 127, accuracy: 1)
        }
    }

    func testTIFFContentAlphaPreservesOutwardPixelGuardAtFractionalDPI() throws {
        try onMain {
            _ = NSApplication.shared
            let artifact = try export(fixture(), format: .tiff, region: .content, dpi: 144.5, transparent: true)
            XCTAssertEqual(artifact.dpiX, 144.5, accuracy: 0.01); XCTAssertEqual(artifact.dpiY, 144.5, accuracy: 0.01)
            XCTAssertEqual(artifact.pixels.pixel(0, 0).a, 0)
            XCTAssertEqual(artifact.pixels.pixel(artifact.pixels.width - 1, artifact.pixels.height - 1).a, 0)
            XCTAssertGreaterThan(artifact.pixels.count { $0.r > 240 && $0.g < 20 && $0.b < 20 && $0.a > 240 }, 7000)
        }
    }

    func testPhysicalDPIMetadataAndOneInchMarkerSurviveActualEncoding() throws {
        try onMain {
            _ = NSApplication.shared
            var model = fixture(); model.page.width = 144; model.page.height = 72
            model.page.nodes = [node(36, 18, 72, 36, "#FF0000")]
            for format in formats {
                let dpi = 300.5
                let artifact = try export(model, format: format, region: .page, dpi: dpi, quality: format == .jpeg ? .maximum : nil)
                XCTAssertEqual(artifact.pixels.width, Int(dpi * 2)); XCTAssertEqual(artifact.pixels.height, Int(dpi))
                XCTAssertEqual(artifact.dpiX, dpi, accuracy: 0.01); XCTAssertEqual(artifact.dpiY, dpi, accuracy: 0.01)
                let red = try XCTUnwrap(artifact.pixels.bounds { $0.r > 235 && $0.g < 25 && $0.b < 25 })
                XCTAssertEqual(red.width / artifact.dpiX * 25.4, 25.4, accuracy: 0.2)
                XCTAssertEqual(red.height / artifact.dpiY * 25.4, 12.7, accuracy: 0.2)
                let nested = try XCTUnwrap(artifact.properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any])
                XCTAssertEqual(try XCTUnwrap(nested[kCGImagePropertyTIFFXResolution as String] as? NSNumber).doubleValue, dpi, accuracy: 0.01)
                XCTAssertEqual(try XCTUnwrap(nested[kCGImagePropertyTIFFYResolution as String] as? NSNumber).doubleValue, dpi, accuracy: 0.01)
                XCTAssertEqual(try XCTUnwrap(nested[kCGImagePropertyTIFFResolutionUnit as String] as? NSNumber).intValue, 2)
                if format == .jpeg {
                    let aspect = try XCTUnwrap(artifact.properties[kCGImagePropertyJFIFDictionary as String] as? [String: Any])
                    XCTAssertEqual(try XCTUnwrap(aspect[kCGImagePropertyJFIFDensityUnit as String] as? NSNumber).intValue, 0)
                    XCTAssertEqual(try XCTUnwrap(aspect[kCGImagePropertyJFIFXDensity as String] as? NSNumber),
                                   try XCTUnwrap(aspect[kCGImagePropertyJFIFYDensity as String] as? NSNumber))
                }
            }
        }
    }

    func testPublicOneMetreAtOneToFiftyFixtureRemainsTwentyMillimetres() throws {
        try onMain {
            _ = NSApplication.shared
            let url = try XCTUnwrap(Bundle.module.url(forResource: "m3-physical", withExtension: "vsdx", subdirectory: "Fixtures/M3"))
            let model = try VisioFormat.read(from: url).diagram
            XCTAssertEqual(model.page.paperScale, 1.0 / 50, accuracy: 1e-10)
            for format in formats {
                let artifact = try export(model, format: format, region: .content, dpi: 300, quality: format == .jpeg ? .maximum : nil)
                let marker = try XCTUnwrap(artifact.pixels.bounds { $0.r < 40 && $0.g < 40 && $0.b < 40 })
                XCTAssertEqual(marker.width / artifact.dpiX * 25.4, 20, accuracy: 0.2)
            }
        }
    }

    func testPageContentAndSelectionReusePNGGeometryIncludingNegativeOrigin() throws {
        try onMain {
            _ = NSApplication.shared
            var model = fixture(); let selected = node(-30, -20, 60, 40, "#FF0000")
            model.page.nodes = [selected, node(150, 100, 20, 20, "#0000FF")]
            for region in RasterExportRegion.allCases {
                let reference = try export(model, format: .png, region: region, nodes: [selected.id])
                for format in formats {
                    let artifact = try export(model, format: format, region: region, nodes: [selected.id], quality: format == .jpeg ? .maximum : nil)
                    XCTAssertEqual(artifact.pixels.width, reference.pixels.width); XCTAssertEqual(artifact.pixels.height, reference.pixels.height)
                    XCTAssertEqual(artifact.result.preparation.rasterViewport, reference.result.preparation.rasterViewport)
                    if format == .tiff { XCTAssertEqual(artifact.pixels.data, reference.pixels.data) }
                    else { XCTAssertLessThan(artifact.pixels.meanError(from: reference.pixels), 10) }
                    if region == .selection {
                        XCTAssertEqual(artifact.result.preparation.rasterViewport, CGRect(x: -31, y: -21, width: 62, height: 42))
                        XCTAssertEqual(artifact.result.preparation.preparedObjects, 1)
                    }
                }
            }
        }
    }

    func testRotatedTextCustomPathCropUsesIdenticalConservativeBounds() throws {
        try onMain {
            _ = NSApplication.shared
            var model = fixture(); model.page.width = 500; model.page.height = 500
            var shape = node(180, 180, 100, 60, "#FF0000"); shape.rotation = 31; shape.stroke = "#000000"; shape.strokeWidth = 5
            shape.text = "Format bounds"; shape.fontSize = 18
            shape.formatting.textBox = ShapeTextBox(rotation: 24)
            shape.formatting.paths = [VectorPath(commands: [VectorCommand("M", -0.2, 0), VectorCommand("C", 0, -0.3, 1.3, -0.3, 1.3, 0.5), VectorCommand("L", 1, 1.2), VectorCommand("L", 0, 1), VectorCommand("Z")], fill: true, stroke: true)]
            model.page.nodes = [shape]
            let reference = try export(model, format: .png, region: .content)
            for format in formats {
                let artifact = try export(model, format: format, region: .content, quality: format == .jpeg ? .maximum : nil)
                XCTAssertEqual(artifact.result.preparation.rasterViewport, reference.result.preparation.rasterViewport)
                XCTAssertEqual(artifact.pixels.width, reference.pixels.width); XCTAssertEqual(artifact.pixels.height, reference.pixels.height)
                if format == .tiff { XCTAssertEqual(artifact.pixels.data, reference.pixels.data) }
                else { XCTAssertLessThan(artifact.pixels.meanError(from: reference.pixels), 12) }
            }
        }
    }

    func testEdgeOnlySelectionRetainsArrowAndLabelWithOriginalRoute() throws {
        try onMain {
            _ = NSApplication.shared
            var model = fixture(); let a = node(10, 50, 20, 25, "#FF0000"), b = node(170, 90, 20, 25, "#0000FF")
            var edge = DiagramEdge(source: a.id, target: b.id); edge.style = .straight; edge.width = 8; edge.label = "JPEG / TIFF route"; edge.arrow = true; edge.color = "#000000"
            model.page.nodes = [a, b]; model.page.edges = [edge]
            let reference = try export(model, format: .png, region: .selection, edges: [edge.id])
            for format in formats {
                let artifact = try export(model, format: format, region: .selection, edges: [edge.id], quality: format == .jpeg ? .maximum : nil)
                XCTAssertEqual(artifact.result.preparation.rasterViewport, reference.result.preparation.rasterViewport)
                XCTAssertEqual(artifact.result.preparation.preparedObjects, 1)
                XCTAssertGreaterThan(artifact.pixels.count { $0.r < 40 && $0.g < 40 && $0.b < 40 }, 100)
                if format == .tiff { XCTAssertEqual(artifact.pixels.data, reference.pixels.data) }
            }
        }
    }

    func testLockedGroupSelectionAndScaledBackgroundKeepExistingPaintPolicy() throws {
        try onMain {
            _ = NSApplication.shared
            var model = fixture(); model.page.width = 10000; model.page.height = 7500; model.page.drawingScale = DrawingScale(page: 1, drawing: 50)
            var group = node(2500, 2000, 3000, 1500, "#FFFFFF00"); group.formatting.isGroup = true; group.locked = true
            var child = node(2500, 2000, 3000, 1500, "#FF0000"); child.parentID = group.id; child.locked = true
            model.page.nodes = [group, child]
            var background = DiagramPage(name: "Background", width: 3000, height: 2000)
            background.drawingScale = DrawingScale(page: 1, drawing: 10); background.isBackground = true
            background.nodes = [node(400, 900, 1000, 400, "#0000FF")]
            model.page.backgroundPageID = background.id; model.pages.append(background)
            for format in formats {
                let artifact = try export(model, format: format, region: .selection, nodes: [group.id], quality: format == .jpeg ? .maximum : nil)
                XCTAssertEqual(artifact.result.preparation.rasterViewport, CGRect(x: 49, y: 39, width: 62, height: 32))
                XCTAssertEqual(artifact.result.preparation.preparedObjects, 3)
                XCTAssertGreaterThan(artifact.pixels.count { $0.b > 230 && $0.r < 30 && $0.g < 30 }, 20)
            }
        }
    }

    func testJPEGQualityPresetsProduceActualDistinctEncodedFiles() throws {
        try onMain {
            _ = NSApplication.shared
            var model = fixture(); model.page.width = 72; model.page.height = 72; model.page.nodes = []
            var seed: UInt32 = 12345
            for y in 0..<16 { for x in 0..<16 {
                seed = seed &* 1664525 &+ 1013904223
                model.page.nodes.append(node(Double(x * 4 + 4), Double(y * 4 + 4), 4, 4, String(format: "#%06X", seed & 0xFFFFFF)))
            } }
            let reference = try export(model, format: .png, region: .page)
            var data = Set<Data>(), error: [JPEGExportQuality: Double] = [:]
            for quality in JPEGExportQuality.allCases {
                let artifact = try export(model, format: .jpeg, region: .page, quality: quality)
                data.insert(artifact.data); error[quality] = artifact.pixels.meanError(from: reference.pixels)
            }
            XCTAssertEqual(data.count, 3)
            XCTAssertLessThan(try XCTUnwrap(error[.maximum]), 45)
            XCTAssertLessThanOrEqual(try XCTUnwrap(error[.maximum]), try XCTUnwrap(error[.standard]) + 0.5)
        }
    }

    func testNativeOptionsExposeOnlyApplicableRasterChoices() throws {
        try onMain {
            _ = NSApplication.shared
            let model = fixture(), owner = LifecycleJobOwner(), input = identity(owner)
            for format in formats {
                let view = ExportOptionsView(snapshot: model, format: format, allPages: false, input: input)
                XCTAssertEqual(view.rasterBoundsMode.numberOfItems, 3); XCTAssertFalse(view.rasterBoundsMode.item(at: 2)?.isEnabled ?? true)
                view.resolutionField.stringValue = "300.5"
                if format == .jpeg {
                    XCTAssertNil(view.transparencyButton.superview); XCTAssertEqual(view.jpegQualityPicker.numberOfItems, 3)
                    view.jpegQualityPicker.selectItem(at: 2)
                    let options = try view.options(for: input, activePageID: model.page.id)
                    XCTAssertEqual(options.jpegQuality, .maximum); XCTAssertFalse(options.transparentBackground)
                    view.jpegQualityPicker.removeAllItems(); XCTAssertThrowsError(try view.options(for: input, activePageID: model.page.id))
                } else {
                    XCTAssertNotNil(view.transparencyButton.superview); XCTAssertNil(view.jpegQualityPicker.superview)
                    view.transparencyButton.state = .on
                    XCTAssertTrue(try view.options(for: input, activePageID: model.page.id).transparentBackground)
                }
            }
        }
    }

    func testRasterOptionDraftsRejectChangedSelectionAndRevision() throws {
        try onMain {
            _ = NSApplication.shared
            let model = fixture(), owner = LifecycleJobOwner(), input = identity(owner)
            let selected = RasterExportSelection(input: input, pageID: model.page.id, nodeIDs: [model.page.nodes[0].id], edgeIDs: [])
            let empty = RasterExportSelection(input: input, pageID: model.page.id, nodeIDs: [], edgeIDs: [])
            for format in formats {
                let view = ExportOptionsView(snapshot: model, format: format, allPages: false, input: input, selection: selected)
                view.rasterBoundsMode.selectItem(at: 2)
                XCTAssertThrowsError(try view.options(for: input, activePageID: model.page.id, selection: empty)) { XCTAssertEqual($0 as? LifecycleJobError, .staleInput) }
                let changed = LifecycleJobInput(ownerID: owner.id, snapshotID: input.snapshotID, revision: input.revision + 1)
                XCTAssertThrowsError(try view.options(for: changed, activePageID: model.page.id, selection: selected))
                XCTAssertEqual(try view.options(for: input, activePageID: model.page.id, selection: selected).rasterSelection, selected)
            }
        }
    }

    func testUnsupportedJPEGTransparencyAndForeignQualityRefuse() throws {
        try onMain {
            _ = NSApplication.shared
            let owner = LifecycleJobOwner(), input = identity(owner)
            var options = OwnedExportOptions(); options.transparentBackground = true
            try assertPreserved(fixture(), format: .jpeg, options: options, owner: owner, input: input)
            options.transparentBackground = false
            options.rasterDPI = 72; options.jpegQuality = .maximum
            for format in [OwnedExportFormat.tiff, .png, .pdf, .svg] {
                try assertPreserved(fixture(), format: format, options: options, owner: owner, input: input)
            }
        }
    }

    func testRasterDPIAndDimensionLimitsRefuseBeforeBitmapPublication() throws {
        try onMain {
            _ = NSApplication.shared
            for format in formats {
                let owner = LifecycleJobOwner(), input = identity(owner)
                for dpi in [35.0, 1201, .nan, .infinity] {
                    var options = OwnedExportOptions(); options.rasterDPI = dpi
                    try assertPreserved(fixture(), format: format, options: options, owner: owner, input: input)
                }
                var huge = fixture(); huge.page.width = 20000; huge.page.height = 20000
                var options = OwnedExportOptions(); options.rasterDPI = 1200
                try assertPreserved(huge, format: format, options: options, owner: owner, input: input)
                options.rasterRegion = .content; huge.page.nodes = [node(0, 0, 20000, 20000, "#FF0000")]
                try assertPreserved(huge, format: format, options: options, owner: owner, input: input)
            }
            var long = fixture(); long.page.width = 4000; long.page.height = 1
            var options = OwnedExportOptions(); options.rasterDPI = 1200
            XCTAssertThrowsError(try options.pageIDs(in: long, format: .jpeg)) { XCTAssertTrue($0.localizedDescription.contains("65,000")) }
            let owner = LifecycleJobOwner()
            try assertPreserved(long, format: .jpeg, options: options, owner: owner, input: identity(owner))
        }
    }

    func testEmptyAndStaleSelectionPreserveExistingDestinations() throws {
        try onMain {
            _ = NSApplication.shared
            for format in formats {
                let owner = LifecycleJobOwner(), input = identity(owner), model = fixture()
                var options = OwnedExportOptions(); options.rasterRegion = .selection
                options.rasterSelection = RasterExportSelection(input: input, pageID: model.page.id, nodeIDs: [], edgeIDs: [])
                try assertPreserved(model, format: format, options: options, owner: owner, input: input)
                options.rasterSelection = RasterExportSelection(input: input, pageID: model.page.id, nodeIDs: [UUID()], edgeIDs: [])
                try assertPreserved(model, format: format, options: options, owner: owner, input: input, expected: .staleInput)
                let wrong = LifecycleJobInput(ownerID: owner.id, snapshotID: input.snapshotID, revision: input.revision + 1)
                options.rasterSelection = RasterExportSelection(input: wrong, pageID: model.page.id, nodeIDs: [model.page.nodes[0].id], edgeIDs: [])
                try assertPreserved(model, format: format, options: options, owner: owner, input: input, expected: .staleInput)
                var screenOnly = model; screenOnly.page.nodes[0].layer = "Screen only"
                screenOnly.page.layers = [DiagramLayer(name: "Screen only", visible: true, printable: false)]
                options.rasterSelection = RasterExportSelection(input: input, pageID: model.page.id, nodeIDs: [model.page.nodes[0].id], edgeIDs: [])
                try assertPreserved(screenOnly, format: format, options: options, owner: owner, input: input)
                var empty = model; empty.page.nodes = []; options.rasterSelection = nil; options.rasterRegion = .content
                try assertPreserved(empty, format: format, options: options, owner: owner, input: input)
            }
        }
    }

    func testCancellationAndClosedOwnerPreservePriorCompleteFile() throws {
        try onMain {
            _ = NSApplication.shared
            var model = fixture(); model.page.nodes = (0..<180).map { node(Double($0 % 20) * 8, Double($0 / 20) * 8, 6, 6, "#FF0000") }
            for format in formats { for close in [false, true] {
                let owner = LifecycleJobOwner(), input = identity(owner), directory = try folder()
                let destination = directory.appendingPathComponent("existing.\(format.rawValue)"), previous = Data("Previous complete artifact".utf8)
                try previous.write(to: destination)
                var options = OwnedExportOptions(); options.rasterRegion = .content
                var outcome: Result<OwnedExportResult, Error>?, handle: LifecycleJobHandle?
                handle = try OwnedExportJobs.submit(snapshot: model, input: input, sourceURL: nil, destination: destination,
                    format: format, options: options, owner: owner, progress: { _ in handle?.cancel() }) { outcome = $0 }
                if close { owner.close() }
                try pump { outcome != nil }
                XCTAssertThrowsError(try XCTUnwrap(outcome).get()) { XCTAssertEqual($0 as? LifecycleJobError, .cancelled) }
                XCTAssertEqual(try Data(contentsOf: destination), previous)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [destination.lastPathComponent])
            } }
        }
    }

    func testInputDestinationAliasesRemainProtectedForBothNewFormats() throws {
        try onMain {
            _ = NSApplication.shared
            for format in formats {
                let directory = try folder(), source = directory.appendingPathComponent("source.\(format.rawValue)")
                let alias = directory.appendingPathComponent("alias.\(format.rawValue)"), previous = Data("Retained input".utf8)
                try previous.write(to: source); try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
                for destination in [source, alias] {
                    let owner = LifecycleJobOwner(), input = identity(owner)
                    XCTAssertThrowsError(try run(fixture(), format: format, options: OwnedExportOptions(), owner: owner, input: input, destination: destination, source: source)) {
                        XCTAssertEqual($0 as? LifecycleJobError, .inputIsDestination)
                    }
                    XCTAssertEqual(try Data(contentsOf: source), previous)
                }
            }
        }
    }

    func testFrozenSelectionDPIAndSceneSurviveCallerMutationAfterSubmission() throws {
        try onMain {
            _ = NSApplication.shared
            for format in formats {
                var model = fixture(); let owner = LifecycleJobOwner(), input = identity(owner)
                var options = OwnedExportOptions(); options.rasterRegion = .selection; options.rasterDPI = 72
                options.rasterSelection = RasterExportSelection(input: input, pageID: model.page.id, nodeIDs: [model.page.nodes[0].id], edgeIDs: [])
                let destination = try folder().appendingPathComponent("frozen.\(format.rawValue)")
                var outcome: Result<OwnedExportResult, Error>?
                try OwnedExportJobs.submit(snapshot: model, input: input, sourceURL: nil, destination: destination, format: format, options: options, owner: owner) { outcome = $0 }
                model.page.nodes[0].fill = "#0000FF"; model.page.nodes[0].width = 150
                options.rasterDPI = 300; options.rasterSelection = nil; options.rasterRegion = .page
                try pump { outcome != nil }; _ = try XCTUnwrap(outcome).get()
                let artifact = try decode(destination, result: try XCTUnwrap(outcome).get())
                XCTAssertEqual(artifact.pixels.width, 62); XCTAssertEqual(artifact.pixels.height, 37); XCTAssertEqual(artifact.dpiX, 72, accuracy: 0.01)
                XCTAssertGreaterThan(artifact.pixels.count { $0.r > 230 && $0.g < 30 && $0.b < 30 }, 1800)
                XCTAssertEqual(artifact.pixels.count { $0.b > 230 && $0.r < 30 && $0.g < 30 }, 0)
            }
        }
    }

    func testMultiplePageRasterRequestIsExplicitlyRefused() throws {
        try onMain {
            _ = NSApplication.shared
            for format in formats {
                XCTAssertThrowsError(try OwnedExportOptions().pageIDs(in: fixture(), format: format, allPages: true))
                let directory = try folder(), destination = directory.appendingPathComponent("existing.\(format.rawValue)")
                let previous = Data("Previous complete output".utf8); try previous.write(to: destination)
                let owner = LifecycleJobOwner()
                XCTAssertThrowsError(try run(fixture(), format: format, options: OwnedExportOptions(), owner: owner, input: identity(owner), destination: destination, allPages: true))
                XCTAssertEqual(try Data(contentsOf: destination), previous)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [destination.lastPathComponent])
            }
        }
    }

    private struct Pixel { let r: UInt8, g: UInt8, b: UInt8, a: UInt8 }
    private struct Pixels {
        let data: Data, width: Int, height: Int
        func pixel(_ x: Int, _ y: Int) -> Pixel { let i = (y * width + x) * 4; return Pixel(r: data[i], g: data[i + 1], b: data[i + 2], a: data[i + 3]) }
        func count(where predicate: (Pixel) -> Bool) -> Int {
            var count = 0; for y in 0..<height { for x in 0..<width where predicate(pixel(x, y)) { count += 1 } }; return count
        }
        func bounds(where predicate: (Pixel) -> Bool) -> CGRect? {
            var left = width, top = height, right = -1, bottom = -1
            for y in 0..<height { for x in 0..<width where predicate(pixel(x, y)) {
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
            } }
            return right < left ? nil : CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        }
        func meanError(from other: Pixels) -> Double {
            guard width == other.width, height == other.height else { return .infinity }
            var total = 0
            for i in stride(from: 0, to: data.count, by: 4) { for channel in 0..<3 { total += abs(Int(data[i + channel]) - Int(other.data[i + channel])) } }
            return Double(total) / Double(width * height * 3)
        }
    }
    private struct Artifact {
        let result: OwnedExportResult, data: Data, type: String, count: Int
        let pixels: Pixels, properties: [String: Any], dpiX: Double, dpiY: Double, hasAlpha: Bool
    }
    private func decode(_ url: URL, result: OwnedExportResult) throws -> Artifact {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let drawing = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        drawing.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        drawing.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = Pixels(data: Data(bytes: try XCTUnwrap(drawing.data), count: image.width * image.height * 4), width: image.width, height: image.height)
        return Artifact(result: result, data: try Data(contentsOf: url), type: try XCTUnwrap(CGImageSourceGetType(source)) as String,
            count: CGImageSourceGetCount(source), pixels: pixels, properties: properties,
            dpiX: try XCTUnwrap(properties[kCGImagePropertyDPIWidth as String] as? NSNumber).doubleValue,
            dpiY: try XCTUnwrap(properties[kCGImagePropertyDPIHeight as String] as? NSNumber).doubleValue,
            hasAlpha: (properties[kCGImagePropertyHasAlpha as String] as? NSNumber)?.boolValue ?? false)
    }
    private func export(_ model: Diagram, format: OwnedExportFormat, region: RasterExportRegion,
                        dpi: Double = 72, nodes: Set<UUID> = [], edges: Set<UUID> = [], transparent: Bool = false,
                        quality: JPEGExportQuality? = nil, testName: String = #function) throws -> Artifact {
        let owner = LifecycleJobOwner(), input = identity(owner), destination = try folder().appendingPathComponent("artifact.\(format.rawValue)")
        var options = OwnedExportOptions(); options.rasterRegion = region; options.rasterDPI = dpi
        options.transparentBackground = transparent; options.jpegQuality = quality
        if region == .selection { options.rasterSelection = RasterExportSelection(input: input, pageID: model.page.id, nodeIDs: nodes, edgeIDs: edges) }
        let result = try run(model, format: format, options: options, owner: owner, input: input, destination: destination)
        let artifact = try decode(destination, result: result)
        try retainIfRequested(artifact, format: format, options: options, testName: testName)
        return artifact
    }
    private func run(_ model: Diagram, format: OwnedExportFormat, options: OwnedExportOptions, owner: LifecycleJobOwner,
                     input: LifecycleJobInput, destination: URL, source: URL? = nil, allPages: Bool = false) throws -> OwnedExportResult {
        var outcome: Result<OwnedExportResult, Error>?
        try OwnedExportJobs.submit(snapshot: model, input: input, sourceURL: source, destination: destination,
                                  format: format, allPages: allPages, options: options, owner: owner) { outcome = $0 }
        try pump { outcome != nil }; return try XCTUnwrap(outcome).get()
    }
    private func assertPreserved(_ model: Diagram, format: OwnedExportFormat, options: OwnedExportOptions,
                                 owner: LifecycleJobOwner, input: LifecycleJobInput, expected: LifecycleJobError? = nil) throws {
        let directory = try folder(), destination = directory.appendingPathComponent("existing.\(format.rawValue)")
        let previous = Data("Previous complete output".utf8); try previous.write(to: destination)
        XCTAssertThrowsError(try run(model, format: format, options: options, owner: owner, input: input, destination: destination)) {
            if let expected { XCTAssertEqual($0 as? LifecycleJobError, expected) }
        }
        XCTAssertEqual(try Data(contentsOf: destination), previous)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [destination.lastPathComponent])
    }
    private func retainIfRequested(_ artifact: Artifact, format: OwnedExportFormat, options: OwnedExportOptions, testName: String) throws {
        guard let configured = ProcessInfo.processInfo.environment["M3_EVIDENCE_DIR"], !configured.isEmpty else { return }
        let name = testName.hasSuffix("()") ? String(testName.dropLast(2)) : testName
        guard (configured as NSString).isAbsolutePath, !name.isEmpty,
              name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), artifact.data.count <= 8 * 1024 * 1024 else {
            throw DiagramError.invalid("Raster-format evidence requires an absolute directory, simple test name and artifact under 8 MiB.")
        }
        let directory = URL(fileURLWithPath: configured, isDirectory: true).appendingPathComponent("M3RasterFormatTests", isDirectory: true).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let label = "\(options.rasterRegion.rawValue)-\(options.rasterDPI)-\(options.transparentBackground ? "alpha" : "white")-\(options.jpegQuality.map { String($0.rawValue) } ?? "default").\(format.rawValue)"
        try artifact.data.write(to: directory.appendingPathComponent(label), options: .atomic)
        var manifest: [String: Any] = ["artifact": label, "sha256": SHA256.hash(data: artifact.data).map { String(format: "%02x", $0) }.joined(),
            "bytes": artifact.data.count, "image_type": artifact.type, "width_pixels": artifact.pixels.width, "height_pixels": artifact.pixels.height,
            "dpi_x": artifact.dpiX, "dpi_y": artifact.dpiY, "has_alpha": artifact.hasAlpha,
            "scope": "Actual local ImageIO export; retention is not acceptance or reference parity"]
        if let box = artifact.result.preparation.rasterViewport { manifest["physical_viewport_points"] = [box.minX, box.minY, box.width, box.height] }
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted]).write(to: directory.appendingPathComponent(label + ".json"), options: .atomic)
    }
}
