import AppKit
import ImageIO
import MacVisioInfrastructure
import XCTest
@testable import MacVisio

final class M3RasterBoundsTests: XCTestCase {
    func testStyledConnectorSelectionKeepsGlyphsAndDecorationsWithoutEndpointPaint() throws {
        try onMain {
            _ = NSApplication.shared
            var model = fixture();model.page.width = 500;model.page.height = 240
            let source = node(20,110,20,20,"#FFFFFF00"),target = node(460,110,20,20,"#FFFFFF00")
            var edge = DiagramEdge(source:source.id,target:target.id,label:"Red italic Blue",style:.straight)
            edge.arrow = false;edge.color = "#444444"
            var red = ShapeCharacterStyle(node:edge.textNode)
            red.fontName = "Arial";red.size = 36;red.italic = true;red.underline = true;red.color = "#FF0000"
            var blue = red;blue.size = 18;blue.underline = false;blue.color = "#0000FF"
            edge.formatting.textRuns = [ShapeTextRun(text:"Red italic ",character:red,paragraph:ShapeParagraphStyle()),
                ShapeTextRun(text:"Blue",character:blue,paragraph:ShapeParagraphStyle())]
            model.page.nodes = [source,target];model.page.edges = [edge]
            let full = try export(model,region:.page),crop = try export(model,region:.selection,edges:[edge.id])
            let redInk:(Pixel)->Bool = {$0.r>180 && $0.g<80 && $0.b<80 && $0.a>220}
            let blueInk:(Pixel)->Bool = {$0.b>180 && $0.r<80 && $0.g<80 && $0.a>220}
            XCTAssertGreaterThan(crop.pixels.count(where:redInk),200)
            XCTAssertGreaterThan(crop.pixels.count(where:blueInk),50)
            XCTAssertLessThanOrEqual(abs(crop.pixels.count(where:redInk)-full.pixels.count(where:redInk)),20)
            XCTAssertLessThanOrEqual(abs(crop.pixels.count(where:blueInk)-full.pixels.count(where:blueInk)),20)
            XCTAssertEqual(crop.result.preparation.preparedObjects,1)
        }
    }

    func testPageModeKeepsLegacyPixelsAndCroppedModeKeepsPhysicalDPI() throws {
        try onMain {
            _ = NSApplication.shared
            let model = fixture()
            let page = try export(model, region: .page, dpi: 300)
            XCTAssertEqual(page.pixels.width, Int(200 * 300.0 / 72))
            XCTAssertEqual(page.pixels.height, 625)
            XCTAssertNil(page.result.preparation.rasterViewport)
            let crop = try export(model, dpi: 300)
            XCTAssertEqual(crop.pixels.width, 253)
            XCTAssertEqual(crop.pixels.height, 148)
            XCTAssertEqual(crop.dpi, 300, accuracy: 0.03)
            let red = try XCTUnwrap(crop.pixels.bounds { $0.r > 240 && $0.g < 20 && $0.b < 20 })
            XCTAssertEqual(red.width / (300 / 72) / 72 * 25.4, 60 / 72 * 25.4, accuracy: 0.2)
        }
    }

    func testContentIncludesNegativeOriginOffPageArtworkWithExactlyOnePixelGuard() throws {
        try onMain {
            _ = NSApplication.shared
            var model = fixture()
            model.page.nodes = [node(-30, -20, 60, 40, "#FF0000")]
            let crop = try export(model)
            XCTAssertEqual(crop.result.preparation.rasterViewport, CGRect(x: -31, y: -21, width: 62, height: 42))
            XCTAssertEqual(crop.pixels.width, 62)
            XCTAssertEqual(crop.pixels.height, 42)
            XCTAssertEqual(crop.pixels.count { $0.r > 240 && $0.g < 20 && $0.b < 20 }, 60 * 40)
            XCTAssertEqual(crop.pixels.alphaAt(0, 0), 0)
            let page = try export(model, region: .page)
            XCTAssertEqual(page.pixels.count { $0.r > 240 && $0.g < 20 && $0.b < 20 }, 30 * 20)
        }
    }

    func testRotatedCustomOutsetPathsRetainPaintAndExcludeScreenPadding() throws {
        try onMain {
            _ = NSApplication.shared
            var model = fixture()
            var shape = node(60, 55, 60, 30, "#FF0000")
            shape.rotation = 37
            shape.formatting.flipX = true
            shape.stroke = "#000000"; shape.strokeWidth = 8
            shape.formatting.paths = [VectorPath(commands: [VectorCommand("M", -0.4, 0), VectorCommand("C", 0, -0.3, 1.4, -0.3, 1.4, 0.5),
                VectorCommand("L", 1, 1.3), VectorCommand("L", -0.4, 1), VectorCommand("Z")], fill: true, stroke: true)]
            model.page.width = 300; model.page.height = 240; model.page.nodes = [shape]
            let full = try export(model, region: .page), cropped = try export(model)
            XCTAssertLessThanOrEqual(abs(cropped.pixels.count { $0.a > 240 && $0.r < 20 && $0.g < 20 && $0.b < 20 }
                           - full.pixels.count { $0.a > 240 && $0.r < 20 && $0.g < 20 && $0.b < 20 }), 12)
            XCTAssertLessThanOrEqual(abs(cropped.pixels.count { $0.r > 240 && $0.g < 20 && $0.b < 20 }
                           - full.pixels.count { $0.r > 240 && $0.g < 20 && $0.b < 20 }), 12)
            XCTAssertLessThan(cropped.pixels.width, 160)
            XCTAssertGreaterThan(cropped.result.preparation.measuredObjects, 0)
        }
    }

    func testRotatedTextBlockAndRichTextDecorationAreNotClipped() throws {
        try onMain {
            _ = NSApplication.shared
            var model = fixture(); model.page.width = 500; model.page.height = 500
            var text = DiagramNode(kind: .text, x: 180, y: 190, text: "Rotated exported text")
            text.width = 150; text.height = 70; text.fontSize = 18; text.rotation = 25
            text.formatting.italic = true; text.formatting.underline = true
            text.formatting.textBox = ShapeTextBox(rotation: 33)
            model.page.nodes = [text]
            let full = try export(model, region: .page), crop = try export(model)
            let dark: (Pixel) -> Bool = { $0.a > 220 && $0.r < 100 && $0.g < 100 && $0.b < 130 }
            XCTAssertGreaterThan(crop.pixels.count(where: dark), 100)
            XCTAssertLessThanOrEqual(abs(crop.pixels.count(where: dark) - full.pixels.count(where: dark)), 20)
            XCTAssertLessThan(crop.pixels.width, 250)
        }
    }

    func testEdgeOnlySelectionKeepsOriginalRoutingArrowheadsAndLabelWithoutEndpoints() throws {
        try onMain {
            _ = NSApplication.shared
            var model = fixture()
            let source = node(10, 50, 20, 25, "#FF0000"), target = node(170, 90, 20, 25, "#0000FF")
            var edge = DiagramEdge(source: source.id, target: target.id)
            edge.style = .straight; edge.width = 8; edge.color = "#000000"
            edge.arrow = true; edge.startArrow = true; edge.label = "Edge only"
            model.page.nodes = [source, target]; model.page.edges = [edge]
            let cropped = try export(model, region: .selection, edges: [edge.id])
            XCTAssertEqual(cropped.result.preparation.preparedObjects, 1)
            XCTAssertEqual(cropped.pixels.count { $0.r > 240 && $0.g < 20 && $0.b < 20 }, 0)
            XCTAssertEqual(cropped.pixels.count { $0.b > 240 && $0.r < 20 && $0.g < 20 }, 0)
            var reference = model
            for index in reference.page.nodes.indices {
                reference.page.nodes[index].fill = "#FFFFFF00"; reference.page.nodes[index].stroke = "#FFFFFF00"
            }
            let full = try export(reference, region: .page)
            let dark: (Pixel) -> Bool = { $0.a > 220 && $0.r < 40 && $0.g < 40 && $0.b < 40 }
            XCTAssertGreaterThan(cropped.pixels.count(where: dark), 300)
            XCTAssertLessThanOrEqual(abs(cropped.pixels.count(where: dark) - full.pixels.count(where: dark)), 20)
        }
    }

    func testGroupSelectionExpandsLockedDescendantsAndGroupOwnedEdges() throws {
        try onMain {
            _ = NSApplication.shared
            var model = fixture()
            var group = node(30, 20, 90, 70, "#FFFFFF00")
            group.formatting.isGroup = true; group.locked = true
            var child = node(40, 35, 35, 20, "#FF0000"); child.parentID = group.id; child.locked = true
            let outside = node(150, 110, 20, 20, "#0000FF")
            var edge = DiagramEdge(source: child.id, target: outside.id)
            edge.parentID = group.id; edge.style = .straight; edge.color = "#000000"; edge.label = "Owned"
            model.page.nodes = [group, child, outside]; model.page.edges = [edge]
            let owner = LifecycleJobOwner(), input = identity(owner)
            let raw = RasterExportSelection(input: input, pageID: model.page.id, nodeIDs: [group.id], edgeIDs: [])
            let membership = try raw.expanded(in: model, input: input)
            XCTAssertEqual(membership.nodeIDs, [group.id, child.id])
            XCTAssertEqual(membership.edgeIDs, [edge.id])
            let output = try export(model, region: .selection, nodes: [group.id])
            XCTAssertEqual(output.result.preparation.preparedObjects, 3)
            XCTAssertGreaterThan(output.pixels.count { $0.r > 240 && $0.g < 20 && $0.b < 20 }, 100)
            XCTAssertEqual(output.pixels.count { $0.b > 240 && $0.r < 20 && $0.g < 20 }, 0)
        }
    }

    func testDifferentScaleBackgroundUsesSceneOffsetAndDoesNotExpandSelectionBounds() throws {
        try onMain {
            _ = NSApplication.shared
            var model = fixture(); model.page.width = 10000; model.page.height = 7500
            model.page.drawingScale = DrawingScale(page: 1, drawing: 50)
            let selected = node(50 * 50, 40 * 50, 60 * 50, 30 * 50, "#FF0000")
            model.page.nodes = [selected]
            var background = DiagramPage(name: "Background", width: 3000, height: 2000)
            background.drawingScale = DrawingScale(page: 1, drawing: 10); background.isBackground = true
            background.nodes = [node(400, 900, 1000, 400, "#0000FF")]
            model.page.backgroundPageID = background.id; model.pages.append(background)
            let selection = try export(model, region: .selection, nodes: [selected.id])
            XCTAssertEqual(selection.result.preparation.rasterViewport, CGRect(x: 49, y: 39, width: 62, height: 32))
            XCTAssertGreaterThan(selection.pixels.count { $0.b > 240 && $0.r < 20 && $0.g < 20 }, 20)
            let content = try export(model)
            XCTAssertEqual(content.result.preparation.rasterViewport, CGRect(x: 39, y: 39, width: 102, height: 42))
        }
    }

    func testEmptyAndNonprintingSelectionsRefuseWithoutChangingDestination() throws {
        try onMain {
            _ = NSApplication.shared
            var model = fixture()
            model.page.nodes[0].layer = "Screen only"
            model.page.layers = [DiagramLayer(name: "Screen only", visible: true, printable: false)]
            let owner = LifecycleJobOwner(), input = identity(owner)
            for ids in [Set<UUID>(), Set([model.page.nodes[0].id])] {
                var options = OwnedExportOptions(); options.rasterRegion = .selection
                options.rasterSelection = RasterExportSelection(input: input, pageID: model.page.id, nodeIDs: ids, edgeIDs: [])
                try assertPreservesDestination(model, options: options, owner: owner, input: input)
            }
            var empty = model; empty.page.nodes = []
            var options = OwnedExportOptions(); options.rasterRegion = .content
            try assertPreservesDestination(empty, options: options, owner: owner, input: input)
        }
    }

    func testSelectionDraftRejectsChangedRawSelectionWithoutDocumentRevisionChange() throws {
        try onMain {
            _ = NSApplication.shared
            let model = fixture(), owner = LifecycleJobOwner(), input = identity(owner)
            let captured = RasterExportSelection(input: input, pageID: model.page.id, nodeIDs: [model.page.nodes[0].id], edgeIDs: [])
            let view = ExportOptionsView(snapshot: model, format: .png, allPages: false, input: input, selection: captured)
            view.rasterBoundsMode.selectItem(at: 2)
            let changed = RasterExportSelection(input: input, pageID: model.page.id, nodeIDs: [], edgeIDs: [])
            XCTAssertThrowsError(try view.options(for: input, activePageID: model.page.id, selection: changed)) {
                XCTAssertEqual($0 as? LifecycleJobError, .staleInput)
            }
            let options = try view.options(for: input, activePageID: model.page.id, selection: captured)
            XCTAssertEqual(options.rasterSelection, captured)
            XCTAssertEqual(options.rasterRegion, .selection)
            view.rasterBoundsMode.selectItem(at: 1)
            XCTAssertNoThrow(try view.options(for: input, activePageID: model.page.id, selection: changed))
            let noSelection = ExportOptionsView(snapshot: model, format: .png, allPages: false, input: input)
            XCTAssertFalse(noSelection.rasterBoundsMode.item(at: 2)?.isEnabled ?? true)
        }
    }

    func testWorkerSelectionIdentityRejectsWrongRevisionOrMissingObject() throws {
        try onMain {
            _ = NSApplication.shared
            let model = fixture(), owner = LifecycleJobOwner(), input = identity(owner)
            let wrong = LifecycleJobInput(ownerID: owner.id, snapshotID: input.snapshotID, revision: input.revision + 1)
            for selection in [RasterExportSelection(input: wrong, pageID: model.page.id, nodeIDs: [model.page.nodes[0].id], edgeIDs: []),
                              RasterExportSelection(input: input, pageID: model.page.id, nodeIDs: [UUID()], edgeIDs: [])] {
                var options = OwnedExportOptions(); options.rasterRegion = .selection; options.rasterSelection = selection
                try assertPreservesDestination(model, options: options, owner: owner, input: input, expected: .staleInput)
            }
        }
    }

    func testCropLimitsAndDPIRejectBeforeBitmapAllocationAndPreserveDestination() throws {
        try onMain {
            _ = NSApplication.shared
            var options = OwnedExportOptions(); options.rasterRegion = .content; options.rasterDPI = 72
            XCTAssertThrowsError(try RasterExportViewport.cropped(CGRect(x: 0, y: 0, width: 100000, height: 1), options: options))
            XCTAssertThrowsError(try RasterExportViewport.cropped(CGRect(x: 0, y: 0, width: 10000, height: 10001), options: options))
            for dpi in [35.0, 1201.0, .nan, .infinity] {
                options.rasterDPI = dpi
                XCTAssertThrowsError(try RasterExportViewport.cropped(CGRect(x: 0, y: 0, width: 10, height: 10), options: options))
            }
            var model = fixture(); model.page.nodes = [node(0, 0, 20000, 20000, "#FF0000")]
            options.rasterDPI = 1200
            let owner = LifecycleJobOwner(), input = identity(owner)
            try assertPreservesDestination(model, options: options, owner: owner, input: input)
            XCTAssertThrowsError(try options.pageIDs(in: fixture(), format: .pdf))
        }
    }

    func testCroppedPreparationCancellationAndClosedOwnerNeverReplaceDestination() throws {
        try onMain {
            _ = NSApplication.shared
            var model = fixture()
            model.page.nodes = (0..<180).map { node(Double($0 % 20) * 8, Double($0 / 20) * 8, 6, 6, "#FF0000") }
            for close in [false, true] {
                let owner = LifecycleJobOwner(), input = identity(owner)
                let destination = try temporaryDirectory().appendingPathComponent("existing.png")
                let previous = Data("Previous complete output".utf8); try previous.write(to: destination)
                var options = OwnedExportOptions(); options.rasterRegion = .content
                var outcome: Result<OwnedExportResult, Error>?, handle: LifecycleJobHandle?
                handle = try OwnedExportJobs.submit(snapshot: model, input: input, sourceURL: nil, destination: destination,
                    format: .png, options: options, owner: owner, progress: { _ in handle?.cancel() }) { outcome = $0 }
                if close { owner.close() }
                try pump(until: { outcome != nil })
                XCTAssertThrowsError(try XCTUnwrap(outcome).get())
                XCTAssertEqual(try Data(contentsOf: destination), previous)
            }
        }
    }

    func testUnsupportedImageCropRefusesWhilePageModeKeepsExistingPlaceholder() throws {
        try onMain {
            _ = NSApplication.shared
            var model = fixture()
            model.page.nodes[0].formatting.image = EmbeddedImage(data: Data([1, 2, 3]), mimeType: "image/png")
            XCTAssertNoThrow(try export(model, region: .page))
            let owner = LifecycleJobOwner(), input = identity(owner)
            let destination = try temporaryDirectory().appendingPathComponent("existing.png")
            let previous = Data("Previous complete output".utf8); try previous.write(to: destination)
            var options = OwnedExportOptions(); options.rasterRegion = .content
            XCTAssertThrowsError(try run(model, options: options, owner: owner, input: input, destination: destination)) {
                XCTAssertTrue($0.localizedDescription.contains("supported image"))
            }
            XCTAssertEqual(try Data(contentsOf: destination), previous)
        }
    }

    func testCroppedTransparencyChangesOnlyPaperFill() throws {
        try onMain {
            _ = NSApplication.shared
            let transparent = try export(fixture()), opaque = try export(fixture(), transparent: false)
            XCTAssertEqual(transparent.pixels.width, opaque.pixels.width)
            XCTAssertEqual(transparent.pixels.height, opaque.pixels.height)
            XCTAssertEqual(transparent.pixels.alphaAt(0, 0), 0)
            XCTAssertEqual(opaque.pixels.alphaAt(0, 0), 255)
            XCTAssertEqual(transparent.pixels.count { $0.r > 240 && $0.g < 20 && $0.b < 20 },
                           opaque.pixels.count { $0.r > 240 && $0.g < 20 && $0.b < 20 })
        }
    }

    func testCroppedOptionsAndSelectionRemainFrozenAfterSubmission() throws {
        try onMain {
            _ = NSApplication.shared
            var model = fixture(), options = OwnedExportOptions()
            options.rasterRegion = .selection; options.rasterDPI = 72; options.transparentBackground = true
            let owner = LifecycleJobOwner(), input = identity(owner)
            options.rasterSelection = RasterExportSelection(input: input, pageID: model.page.id,
                nodeIDs: [model.page.nodes[0].id], edgeIDs: [])
            let destination = try temporaryDirectory().appendingPathComponent("frozen.png")
            var outcome: Result<OwnedExportResult, Error>?
            try OwnedExportJobs.submit(snapshot: model, input: input, sourceURL: nil, destination: destination,
                format: .png, options: options, owner: owner) { outcome = $0 }
            options.rasterRegion = .page; options.rasterDPI = 300; options.transparentBackground = false
            model.page.nodes[0].width = 5
            try pump(until: { outcome != nil })
            let result = try XCTUnwrap(outcome).get()
            XCTAssertEqual(result.preparation.rasterViewport, CGRect(x: 39, y: 29, width: 62, height: 37))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(destination as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 62); XCTAssertEqual(image.height, 37)
            XCTAssertEqual(try pixels(image).alphaAt(0, 0), 0)
        }
    }

    private func fixture() -> Diagram {
        var model = Diagram(); model.page.width = 200; model.page.height = 150
        model.page.nodes = [node(40, 30, 60, 35, "#FF0000")]
        return model
    }

    private func node(_ x: Double, _ y: Double, _ width: Double, _ height: Double, _ color: String) -> DiagramNode {
        var result = DiagramNode(x: x, y: y, text: "")
        result.width = width; result.height = height; result.fill = color; result.stroke = "#FFFFFF00"; result.strokeWidth = 0
        return result
    }

    private func identity(_ owner: LifecycleJobOwner) -> LifecycleJobInput {
        LifecycleJobInput(ownerID: owner.id, snapshotID: UUID(), revision: 3)
    }

    private func export(_ model: Diagram, region: RasterExportRegion = .content, dpi: Double = 72,
                        nodes: Set<UUID> = [], edges: Set<UUID> = [], transparent: Bool = true,
                        testName: String = #function) throws -> (result: OwnedExportResult, pixels: Pixels, dpi: Double) {
        let owner = LifecycleJobOwner(), input = identity(owner)
        var options = OwnedExportOptions(); options.rasterRegion = region; options.rasterDPI = dpi; options.transparentBackground = transparent
        if region == .selection { options.rasterSelection = RasterExportSelection(input: input, pageID: model.page.id, nodeIDs: nodes, edgeIDs: edges) }
        let url = try temporaryDirectory().appendingPathComponent("artifact.png")
        let result = try run(model, options: options, owner: owner, input: input, destination: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
        let actualDPI = try XCTUnwrap(properties[kCGImagePropertyDPIWidth as String] as? NSNumber).doubleValue
        if let path = ProcessInfo.processInfo.environment["M3_EVIDENCE_DIR"], !path.isEmpty {
            let name = testName.hasSuffix("()") ? String(testName.dropLast(2)) : testName
            guard (path as NSString).isAbsolutePath, !name.isEmpty,
                  name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
                throw DiagramError.invalid("Raster evidence requires an absolute directory and a simple test name.")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let bytes = attributes[.size] as? NSNumber, bytes.intValue <= 4 * 1024 * 1024 else {
                throw DiagramError.invalid("Raster test evidence exceeds its 4 MiB artifact limit.")
            }
            let directory = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("M3RasterBoundsTests", isDirectory: true).appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let label = "\(region.rawValue)-\(dpi)-\(transparent ? "transparent" : "opaque").png"
            try Data(contentsOf: url).write(to: directory.appendingPathComponent(label), options: .atomic)
        }
        return (result, try pixels(image), actualDPI)
    }

    private func run(_ model: Diagram, options: OwnedExportOptions, owner: LifecycleJobOwner,
                     input: LifecycleJobInput, destination: URL) throws -> OwnedExportResult {
        var outcome: Result<OwnedExportResult, Error>?
        try OwnedExportJobs.submit(snapshot: model, input: input, sourceURL: nil, destination: destination,
                                  format: .png, options: options, owner: owner) { outcome = $0 }
        try pump(until: { outcome != nil })
        return try XCTUnwrap(outcome).get()
    }

    private func assertPreservesDestination(_ model: Diagram, options: OwnedExportOptions,
                                           owner: LifecycleJobOwner, input: LifecycleJobInput,
                                           expected: LifecycleJobError? = nil) throws {
        let directory = try temporaryDirectory(), destination = directory.appendingPathComponent("existing.png")
        let previous = Data("Previous complete output".utf8); try previous.write(to: destination)
        XCTAssertThrowsError(try run(model, options: options, owner: owner, input: input, destination: destination)) {
            if let expected { XCTAssertEqual($0 as? LifecycleJobError, expected) }
        }
        XCTAssertEqual(try Data(contentsOf: destination), previous)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing.png"])
    }

    private struct Pixel { let r: UInt8, g: UInt8, b: UInt8, a: UInt8 }
    private struct Pixels {
        let data: Data, width: Int, height: Int
        func pixel(_ x: Int, _ y: Int) -> Pixel { let i = (y * width + x) * 4; return Pixel(r: data[i], g: data[i + 1], b: data[i + 2], a: data[i + 3]) }
        func alphaAt(_ x: Int, _ y: Int) -> UInt8 { pixel(x, y).a }
        func count(where predicate: (Pixel) -> Bool) -> Int {
            var result = 0
            for y in 0..<height { for x in 0..<width where predicate(pixel(x, y)) { result += 1 } }
            return result
        }
        func bounds(where predicate: (Pixel) -> Bool) -> CGRect? {
            var left = width, top = height, right = -1, bottom = -1
            for y in 0..<height { for x in 0..<width where predicate(pixel(x, y)) {
                left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
            } }
            return right < left ? nil : CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        }
    }
    private func pixels(_ image: CGImage) throws -> Pixels {
        let drawing = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        drawing.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        drawing.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Pixels(data: Data(bytes: try XCTUnwrap(drawing.data), count: image.width * image.height * 4), width: image.width, height: image.height)
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("M3-raster-bounds-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func pump(until complete: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(30)
        while !complete() && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        guard complete() else { throw DiagramError.invalid("Cropped export timed out.") }
    }
    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}
