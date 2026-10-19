import AppKit
import ImageIO
import MacVisioInfrastructure
import XCTest
@testable import MacVisio

final class M3OutputOptionsTests: XCTestCase {
    func testPNGResolutionWritesExpectedPixelsAndPhysicalDPIMetadata() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = try temporaryDirectory()
            for dpi in [72.0, 144.0, 300.0] {
                let output = directory.appendingPathComponent("resolution-\(dpi).png")
                var options = OwnedExportOptions(); options.rasterDPI = dpi
                _ = try export(fixture(), to: output, format: .png, options: options)
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
                let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertEqual(image.width, Int(dpi))
                XCTAssertEqual(image.height, Int(dpi / 2))
                let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any])
                XCTAssertEqual(try XCTUnwrap(properties[kCGImagePropertyDPIWidth as String] as? NSNumber).doubleValue, dpi, accuracy: 0.03)
                XCTAssertEqual(try XCTUnwrap(properties[kCGImagePropertyDPIHeight as String] as? NSNumber).doubleValue, dpi, accuracy: 0.03)
                let pixels = try rgba(image)
                XCTAssertEqual(pixels[3], 255, "Default page background remains opaque.")
                XCTAssertEqual(Array(pixels[0..<3]), [255, 255, 255])
            }
        }
    }

    func testTransparentPNGRetainsPaintedObjectAndAssignedBackgroundArtwork() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = try temporaryDirectory()
            var diagram = fixture()
            var background = DiagramPage(name: "Artwork", width: 72, height: 36)
            var artwork = DiagramNode(x: 4, y: 4, text: "")
            artwork.width = 6; artwork.height = 28; artwork.fill = "#0000FF"; artwork.stroke = "#00000000"
            background.nodes = [artwork]; background.isBackground = true
            diagram.page.backgroundPageID = background.id; diagram.pages.append(background)
            var options = OwnedExportOptions(); options.rasterDPI = 72; options.transparentBackground = true
            let output = directory.appendingPathComponent("transparent.png")
            _ = try export(diagram, to: output, format: .png, options: options)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let pixels = try rgba(image)
            XCTAssertEqual(pixels[3], 0, "An unpainted corner must remain transparent.")
            let object = (18 * image.width + 36) * 4
            XCTAssertEqual(pixels[object + 3], 255)
            XCTAssertGreaterThan(pixels[object], 240)
            XCTAssertLessThan(pixels[object + 1], 20)
            let backgroundPixel = (18 * image.width + 7) * 4
            XCTAssertEqual(pixels[backgroundPixel + 3], 255)
            XCTAssertGreaterThan(pixels[backgroundPixel + 2], 240, "Transparency removes the paper fill, preserving assigned artwork.")
        }
    }

    func testOrderedPDFSelectionUsesMixedPhysicalMediaBoxesAndExplicitBackgroundChoice() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = try temporaryDirectory()
            var diagram = fixture()
            let second = DiagramPage(name: "Same name", width: 210, height: 300)
            var background = DiagramPage(name: "Same name", width: 120, height: 80); background.isBackground = true
            diagram.pages += [second, background]
            var options = OwnedExportOptions(); options.pdfPageIDs = [background.id, diagram.page.id, second.id]
            let output = directory.appendingPathComponent("ordered.pdf")
            _ = try export(diagram, to: output, format: .pdf, options: options, allPages: true)
            let pdf = try XCTUnwrap(CGPDFDocument(output as CFURL))
            XCTAssertEqual(pdf.numberOfPages, 3)
            let boxes = (1...3).compactMap { pdf.page(at: $0)?.getBoxRect(.mediaBox) }
            XCTAssertEqual(boxes.map(\.width), [120, 72, 210])
            XCTAssertEqual(boxes.map(\.height), [80, 36, 300])
            XCTAssertEqual(try OwnedExportOptions().pageIDs(in: diagram, format: .pdf), [diagram.page.id])
            XCTAssertEqual(try OwnedExportOptions().pageIDs(in: diagram, format: .pdf, allPages: true), [diagram.page.id, second.id])
        }
    }

    func testOwnedPDFKeepsOneMetreAtOneToFiftyAt20mmInOrderedOutput() throws {
        try onMain {
            _ = NSApplication.shared
            let source = try XCTUnwrap(Bundle.module.url(forResource: "m3-physical", withExtension: "vsdx", subdirectory: "Fixtures/M3"))
            var diagram = try VisioFormat.read(from: source).diagram
            let physicalID = diagram.page.id
            let other = DiagramPage(name: "First in output", width: 300, height: 150)
            diagram.pages.append(other)
            var options = OwnedExportOptions(); options.pdfPageIDs = [other.id, physicalID]
            let output = try temporaryDirectory().appendingPathComponent("physical.pdf")
            _ = try export(diagram, to: output, format: .pdf, options: options)
            let pdf = try XCTUnwrap(CGPDFDocument(output as CFURL))
            XCTAssertEqual(pdf.numberOfPages, 2)
            XCTAssertEqual(pdf.page(at: 1)?.getBoxRect(.mediaBox).width, 300)
            let page = try XCTUnwrap(pdf.page(at: 2)), box = page.getBoxRect(.mediaBox)
            XCTAssertEqual(box.width / 72 * 25.4, 210, accuracy: 1e-4)
            XCTAssertEqual(box.height / 72 * 25.4, 297, accuracy: 1e-4)
            let scale = 4.0, width = Int(ceil(box.width * scale)), height = Int(ceil(box.height * scale))
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            try pixels.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.scaleBy(x: scale, y: scale); context.drawPDFPage(page)
            }
            var left = width, right = -1
            for y in 0..<height { for x in 0..<width {
                let offset = (y * width + x) * 4
                if pixels[offset] < 40 && pixels[offset + 1] < 40 && pixels[offset + 2] < 40 {
                    left = min(left, x); right = max(right, x)
                }
            } }
            XCTAssertGreaterThanOrEqual(right, left)
            XCTAssertEqual(Double(right - left + 1) / scale / 72 * 25.4, 20, accuracy: 0.2)
        }
    }

    func testInvalidOptionsRejectBeforeRasterAllocationAndPreserveExistingDestination() throws {
        try onMain {
            _ = NSApplication.shared
            let diagram = fixture()
            for dpi in [0.0, 35.0, 1201.0, Double.nan, Double.infinity] {
                var options = OwnedExportOptions(); options.rasterDPI = dpi
                XCTAssertThrowsError(try options.rasterSize(width: 72, height: 36))
            }
            var options = OwnedExportOptions(); options.rasterDPI = 72
            XCTAssertThrowsError(try options.rasterSize(width: 100_001, height: 1))
            XCTAssertThrowsError(try options.rasterSize(width: 10_000, height: 10_001))
            XCTAssertThrowsError(try options.rasterSize(width: .greatestFiniteMagnitude, height: 1))
            for ids in [[], [diagram.page.id, diagram.page.id], [UUID()]] as [[UUID]] {
                options.pdfPageIDs = ids
                XCTAssertThrowsError(try options.pageIDs(in: diagram, format: .pdf))
            }
            options.pdfPageIDs = [diagram.page.id]
            XCTAssertThrowsError(try options.pageIDs(in: diagram, format: .png))
            let directory = try temporaryDirectory(), output = directory.appendingPathComponent("existing.png")
            let original = Data("Existing destination".utf8); try original.write(to: output)
            options = OwnedExportOptions(); options.rasterDPI = 1200
            var oversized = diagram; oversized.page.width = 10_000; oversized.page.height = 10_000
            XCTAssertThrowsError(try export(oversized, to: output, format: .png, options: options))
            XCTAssertEqual(try Data(contentsOf: output), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing.png"])
        }
    }

    func testRasterSettingsAndPageSnapshotAreCapturedByValue() throws {
        try onMain {
            _ = NSApplication.shared
            let output = try temporaryDirectory().appendingPathComponent("captured.png")
            let owner = LifecycleJobOwner()
            var diagram = fixture(), options = OwnedExportOptions()
            options.rasterDPI = 72; options.transparentBackground = true
            var outcome: Result<OwnedExportResult, Error>?
            try OwnedExportJobs.submit(snapshot: diagram, input: input(owner), sourceURL: nil,
                destination: output, format: .png, options: options, owner: owner) { outcome = $0 }
            diagram.page.width = 200; options.rasterDPI = 300; options.transparentBackground = false
            try pump(until: { outcome != nil }); _ = try XCTUnwrap(outcome).get()
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(image.width, 72); XCTAssertEqual(image.height, 36)
            XCTAssertEqual(try rgba(image)[3], 0)
        }
    }

    func testPNGOptionsKeepCancellationAndClosedOwnerFromPublishing() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = try temporaryDirectory(), output = directory.appendingPathComponent("existing.png")
            let original = Data("Existing destination".utf8); try original.write(to: output)
            var diagram = fixture()
            diagram.page.nodes = (0..<300).map { _ in diagram.page.nodes[0] }
            for index in diagram.page.nodes.indices { diagram.page.nodes[index].id = UUID() }
            var options = OwnedExportOptions(); options.rasterDPI = 300; options.transparentBackground = true
            for closeOwner in [false, true] {
                let owner = LifecycleJobOwner()
                var handle: LifecycleJobHandle?, outcome: Result<OwnedExportResult, Error>?
                handle = try OwnedExportJobs.submit(snapshot: diagram, input: input(owner), sourceURL: nil,
                    destination: output, format: .png, options: options, owner: owner,
                    progress: { _ in if !closeOwner { handle?.cancel() } }) { outcome = $0 }
                if closeOwner { owner.close() }
                try pump(until: { outcome != nil })
                XCTAssertThrowsError(try XCTUnwrap(outcome).get()) {
                    XCTAssertTrue([LifecycleJobError.cancelled, .staleInput].contains($0 as? LifecycleJobError ?? .queueFull))
                }
                XCTAssertEqual(try Data(contentsOf: output), original)
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing.png"])
        }
    }

    func testNativePNGControlsExposeDefaultsAndValidatedDraft() throws {
        try onMain {
            _ = NSApplication.shared
            let owner = LifecycleJobOwner(), captured = input(owner), diagram = fixture()
            let view = ExportOptionsView(snapshot: diagram, format: .png, allPages: false, input: captured)
            XCTAssertEqual(try view.options(for: captured, activePageID: diagram.activePageID), OwnedExportOptions())
            view.resolutionField.stringValue = "300"
            view.transparencyButton.performClick(nil)
            let options = try view.options(for: captured, activePageID: diagram.activePageID)
            XCTAssertEqual(options.rasterDPI, 300); XCTAssertTrue(options.transparentBackground)
            view.resolutionField.stringValue = "invalid"
            XCTAssertThrowsError(try view.options(for: captured, activePageID: diagram.activePageID))
        }
    }

    func testNativePDFControlsSelectAndMoveIdentityBoundPagesAndRejectStaleInputs() throws {
        try onMain {
            _ = NSApplication.shared
            var diagram = fixture()
            let second = DiagramPage(name: "Duplicate", width: 200, height: 100)
            var background = DiagramPage(name: "Duplicate", width: 150, height: 200); background.isBackground = true
            diagram.pages += [second, background]
            let owner = LifecycleJobOwner(), captured = input(owner)
            let view = ExportOptionsView(snapshot: diagram, format: .pdf, allPages: true, input: captured)
            XCTAssertEqual(try view.options(for: captured, activePageID: diagram.activePageID).pdfPageIDs, [diagram.page.id, second.id])
            view.pageMode.selectItem(at: 0); view.pageModeChanged(nil)
            XCTAssertEqual(try view.options(for: captured, activePageID: diagram.activePageID).pdfPageIDs, [diagram.page.id])
            view.pageMode.selectItem(at: 2); view.pageModeChanged(nil)
            view.table.selectRowIndexes(IndexSet([1, 2]), byExtendingSelection: false)
            view.moveUpButton.performClick(nil)
            XCTAssertEqual(try view.options(for: captured, activePageID: diagram.activePageID).pdfPageIDs, [second.id, background.id])
            view.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            view.moveUpButton.performClick(nil)
            view.table.selectRowIndexes(IndexSet([0, 1, 2]), byExtendingSelection: false)
            XCTAssertEqual(try view.options(for: captured, activePageID: diagram.activePageID).pdfPageIDs, [background.id, second.id, diagram.page.id])
            view.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            view.moveDownButton.performClick(nil)
            view.table.selectRowIndexes(IndexSet([0, 1, 2]), byExtendingSelection: false)
            XCTAssertEqual(try view.options(for: captured, activePageID: diagram.activePageID).pdfPageIDs, [second.id, background.id, diagram.page.id])
            let labels = (0..<3).map { view.tableView(view.table, objectValueFor: view.table.tableColumns[0], row: $0) as? String }
            XCTAssertEqual(Set(labels.compactMap { $0 }).count, 3)
            view.table.deselectAll(nil)
            XCTAssertThrowsError(try view.options(for: captured, activePageID: diagram.activePageID))
            for stale in [LifecycleJobInput(ownerID: UUID(), snapshotID: captured.snapshotID, revision: captured.revision),
                          LifecycleJobInput(ownerID: captured.ownerID, snapshotID: UUID(), revision: captured.revision),
                          LifecycleJobInput(ownerID: captured.ownerID, snapshotID: captured.snapshotID, revision: captured.revision + 1)] {
                XCTAssertThrowsError(try view.options(for: stale, activePageID: diagram.activePageID))
            }
        }
    }

    func testActualPageActivationInvalidatesRasterAndPDFDraftsWithoutContentRevisionChange() throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument(); defer { document.close() }
            var diagram = fixture()
            let firstID = diagram.activePageID
            let second = DiagramPage(name: "Different paper", width: 300, height: 200)
            diagram.pages.append(second); document.diagram = diagram
            let owner = LifecycleJobOwner()
            for format in [OwnedExportFormat.png, .jpeg, .tiff, .pdf] {
                document.activatePage(firstID)
                let captured = LifecycleJobInput(ownerID: owner.id, snapshotID: document.stateID, revision: document.revision)
                let view = ExportOptionsView(snapshot: document.diagram, format: format, allPages: false, input: captured)
                _ = try view.options(for: captured, activePageID: document.diagram.activePageID)
                document.activatePage(second.id)
                XCTAssertEqual(document.stateID, captured.snapshotID)
                XCTAssertEqual(document.revision, captured.revision)
                let current = LifecycleJobInput(ownerID: owner.id, snapshotID: document.stateID, revision: document.revision)
                XCTAssertThrowsError(try view.options(for: current, activePageID: document.diagram.activePageID)) {
                    XCTAssertTrue($0.localizedDescription.contains("active page changed"))
                }
            }
        }
    }

    private func fixture() -> Diagram {
        var diagram = Diagram(); diagram.page.width = 72; diagram.page.height = 36
        var object = DiagramNode(x: 24, y: 12, text: "")
        object.width = 24; object.height = 12; object.fill = "#FF0000"; object.stroke = "#00000000"
        diagram.page.nodes = [object]
        return diagram
    }
    private func input(_ owner: LifecycleJobOwner) -> LifecycleJobInput {
        LifecycleJobInput(ownerID: owner.id, snapshotID: UUID(), revision: 1)
    }
    private func export(_ diagram: Diagram, to url: URL, format: OwnedExportFormat,
                        options: OwnedExportOptions = OwnedExportOptions(), allPages: Bool = false) throws -> OwnedExportResult {
        let owner = LifecycleJobOwner()
        var outcome: Result<OwnedExportResult, Error>?
        try OwnedExportJobs.submit(snapshot: diagram, input: input(owner), sourceURL: nil, destination: url,
            format: format, allPages: allPages, options: options, owner: owner) { outcome = $0 }
        try pump(until: { outcome != nil })
        return try XCTUnwrap(outcome).get()
    }
    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }
    private func pump(until complete: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(30)
        while !complete() && Date() < deadline { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        guard complete() else { throw DiagramError.invalid("Owned export options completion timed out") }
    }
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("M3-output-options-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}
