import AppKit
import XCTest
@testable import MacVisio

final class DocumentSavingTests: XCTestCase {
    func testNewVSDXCanBeSavedAndOverwrittenTwiceThroughNSDocument() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("drawing.vsdx")
            let document = MacVisioDocument()
            defer { document.close() }
            document.diagram.title = "Save pipeline fixture"
            document.diagram.page.nodes = [DiagramNode(kind: .rectangle, x: 120, y: 90, text: "Initial")]
            document.updateChangeCount(.changeDone)

            try save(document, to: url, type: MacVisioDocument.visioType, operation: .saveAsOperation)
            assertSuccessfulSave(document, at: url)
            XCTAssertEqual(try VisioFormat.read(from: url).diagram.page.nodes.first?.text, "Initial")

            document.diagram.page.nodes[0].text = "First overwrite"
            document.updateChangeCount(.changeDone)
            try save(document, to: url, type: MacVisioDocument.visioType, operation: .saveOperation)
            assertSuccessfulSave(document, at: url)
            XCTAssertEqual(try VisioFormat.read(from: url).diagram.page.nodes.first?.text, "First overwrite")

            document.diagram.page.nodes[0].text = "Second overwrite"
            document.updateChangeCount(.changeDone)
            try save(document, to: url, type: MacVisioDocument.visioType, operation: .saveOperation)
            assertSuccessfulSave(document, at: url)

            let reopened = try MacVisioDocument(contentsOf: url, ofType: MacVisioDocument.visioType)
            defer { reopened.close() }
            XCTAssertEqual(reopened.diagram.page.nodes.first?.text, "Second overwrite")
            XCTAssertFalse(reopened.isDocumentEdited)
            XCTAssertEqual(reopened.fileURL?.standardizedFileURL, url.standardizedFileURL)
            XCTAssertNotNil(reopened.fileModificationDate)
        }
    }

    func testSaveAsCopyPreservesSourceAndWritesEditedContentToDestination() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let sourceURL = directory.appendingPathComponent("source.vsdx")
            let copyURL = directory.appendingPathComponent("copy.vsdx")
            let source = MacVisioDocument()
            defer { source.close() }
            source.diagram.title = "Save As source fixture"
            source.diagram.page.nodes = [DiagramNode(kind: .ellipse, x: 80, y: 100, text: "Original source")]
            source.updateChangeCount(.changeDone)
            try save(source, to: sourceURL, type: MacVisioDocument.visioType, operation: .saveAsOperation)
            let originalBytes = try Data(contentsOf: sourceURL)

            let document = try MacVisioDocument(contentsOf: sourceURL, ofType: MacVisioDocument.visioType)
            defer { document.close() }
            document.diagram.page.nodes[0].text = "Edited copy"
            document.updateChangeCount(.changeDone)
            try save(document, to: copyURL, type: MacVisioDocument.visioType, operation: .saveAsOperation)

            assertSuccessfulSave(document, at: copyURL)
            XCTAssertEqual(try Data(contentsOf: sourceURL), originalBytes, "Save As must leave the source bytes untouched.")
            XCTAssertEqual(try VisioFormat.read(from: sourceURL).diagram.page.nodes.first?.text, "Original source")
            XCTAssertEqual(try VisioFormat.read(from: copyURL).diagram.page.nodes.first?.text, "Edited copy")
            XCTAssertEqual(document.fileURL?.standardizedFileURL, copyURL.standardizedFileURL)
        }
    }

    func testNativeDocumentCanBeSavedOverwrittenAndReopenedThroughNSDocument() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("drawing.macvisio")
            let document = MacVisioDocument()
            defer { document.close() }
            document.diagram.title = "Native save fixture"
            document.diagram.page.nodes = [DiagramNode(kind: .diamond, x: 70, y: 60, text: "Before")]
            document.updateChangeCount(.changeDone)

            try save(document, to: url, type: MacVisioDocument.nativeType, operation: .saveAsOperation)
            assertSuccessfulSave(document, at: url)
            document.diagram.page.nodes[0].text = "After native overwrite"
            document.updateChangeCount(.changeDone)
            try save(document, to: url, type: MacVisioDocument.nativeType, operation: .saveOperation)
            assertSuccessfulSave(document, at: url)

            let reopened = try MacVisioDocument(contentsOf: url, ofType: MacVisioDocument.nativeType)
            defer { reopened.close() }
            XCTAssertEqual(reopened.diagram.page.nodes.first?.text, "After native overwrite")
            XCTAssertFalse(reopened.isDocumentEdited)
            XCTAssertNotNil(reopened.fileModificationDate)
        }
    }

    func testLegacyVSDRefusesUnsafeOverwriteAndReopensExplicitCopyThroughNSDocument() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("drawing.vsd")
            let document = MacVisioDocument()
            defer { document.close() }
            document.diagram.title = "Legacy save fixture"
            document.diagram.page.nodes = [DiagramNode(kind: .rectangle, x: 75, y: 65, text: "Before legacy save")]
            document.updateChangeCount(.changeDone)

            try save(document, to: url, type: MacVisioDocument.legacyType, operation: .saveAsOperation)
            assertSuccessfulSave(document, at: url)
            let originalBytes = try Data(contentsOf: url)
            document.diagram.page.nodes[0].text = "Edited legacy copy"
            document.updateChangeCount(.changeDone)

            let refusal = try XCTUnwrap(
                try saveResult(document, to: url, type: MacVisioDocument.legacyType, operation: .saveOperation)
                    as? DocumentSaveImpact.UnsafeOverwrite)
            XCTAssertTrue(refusal.assessment.risks.contains { $0.feature == .legacyReconstruction })
            XCTAssertEqual(try Data(contentsOf: url), originalBytes)
            XCTAssertTrue(document.isDocumentEdited)
            XCTAssertEqual(document.fileURL?.standardizedFileURL, url.standardizedFileURL)

            let copyURL = directory.appendingPathComponent("drawing-copy.vsd")
            document.resolveSaveImpact = { assessment in
                XCTAssertTrue(assessment.risks.contains { $0.feature == .legacyReconstruction })
                return .copy(copyURL)
            }
            try save(document, to: url, type: MacVisioDocument.legacyType, operation: .saveOperation)
            XCTAssertTrue(FileManager.default.fileExists(atPath: copyURL.path))
            XCTAssertEqual(try Data(contentsOf: url), originalBytes)
            XCTAssertTrue(document.isDocumentEdited, "Saving a separate copy must leave the original edit pending.")
            XCTAssertEqual(document.fileURL?.standardizedFileURL, url.standardizedFileURL)

            let reopened = try MacVisioDocument(contentsOf: url, ofType: MacVisioDocument.legacyType)
            defer { reopened.close() }
            XCTAssertEqual(reopened.diagram.page.nodes.first?.text, "Before legacy save")
            XCTAssertFalse(reopened.isDocumentEdited)
            XCTAssertNotNil(reopened.fileModificationDate)

            let copied = try MacVisioDocument(contentsOf: copyURL, ofType: MacVisioDocument.legacyType)
            defer { copied.close() }
            XCTAssertEqual(copied.diagram.page.nodes.first?.text, "Edited legacy copy")
            XCTAssertFalse(copied.isDocumentEdited)
            XCTAssertNotNil(copied.fileModificationDate)
        }
    }

    func testImportedPublicVSDXOverwriteRetainsUnknownPackageParts() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let fixture = try XCTUnwrap(Bundle.module.url(forResource: "blue-box", withExtension: "vsdx", subdirectory: "Fixtures"))
            let url = directory.appendingPathComponent("public-import.vsdx")
            try FileManager.default.copyItem(at: fixture, to: url)

            var package = try VisioPackage.read(url)
            package.removeValue(forKey: "macvisio/document.json")
            if let relData = package["_rels/.rels"] {
                let relationships = try VisioXML.document(relData)
                for relationship in relationships.rootElement()?.elementsLocal("Relationship") ?? []
                where relationship.attr("Type")?.hasPrefix("urn:macvisio") == true {
                    relationship.detach()
                }
                package["_rels/.rels"] = relationships.xmlData(options: .nodePreserveAll)
            }
            if let contentTypeData = package["[Content_Types].xml"] {
                let contentTypes = try VisioXML.document(contentTypeData)
                for override in contentTypes.rootElement()?.elementsLocal("Override") ?? []
                where override.attr("PartName") == "/macvisio/document.json" {
                    override.detach()
                }
                package["[Content_Types].xml"] = contentTypes.xmlData(options: .nodePreserveAll)
            }
            let vendorPart = Data([0x00, 0xA5, 0x11, 0xFE, 0x42, 0x09])
            package["vendor/future-document-data.bin"] = vendorPart
            try VisioPackage.write(package, to: url)

            let document = try MacVisioDocument(contentsOf: url, ofType: MacVisioDocument.visioType)
            defer { document.close() }
            XCTAssertFalse(document.diagram.page.nodes.isEmpty)
            document.diagram.page.nodes[0].text = "Edited through NSDocument"
            document.updateChangeCount(.changeDone)
            try save(document, to: url, type: MacVisioDocument.visioType, operation: .saveOperation)

            assertSuccessfulSave(document, at: url)
            XCTAssertEqual(try VisioPackage.read(url)["vendor/future-document-data.bin"], vendorPart)
            let reopened = try MacVisioDocument(contentsOf: url, ofType: MacVisioDocument.visioType)
            defer { reopened.close() }
            XCTAssertEqual(reopened.diagram.page.nodes.first?.text, "Edited through NSDocument")
        }
    }

    func testLargeImportedShapeSheetPayloadUsesSegmentsThenRemovesStaleSegments() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let sourceURL = directory.appendingPathComponent("large-source.vsdx")
            let savedURL = directory.appendingPathComponent("large-saved.vsdx")
            let publicOnlyURL = directory.appendingPathComponent("public-only.vsdx")
            let largeValue = String(repeating: "P", count: 3 * 1024 * 1024)

            var model = Diagram()
            model.pages = (0..<3).map { index in
                var page = DiagramPage(name: "Metadata Page \(index + 1)")
                var node = DiagramNode(kind: .rectangle, x: 120, y: 90, text: "Before large save")
                node.formatting.sheet["User.Payload"] = ShapeSheetCell(value: largeValue)
                page.nodes = [node]
                return page
            }
            model.activePageID = model.pages[0].id
            try VisioFormat.write(model, to: sourceURL)

            var sourceParts = try VisioPackage.read(sourceURL)
            sourceParts["vendor/opaque-save-probe.bin"] = Data([0x00, 0xFE, 0x13, 0x80, 0x42])
            try VisioPackage.write(sourceParts, to: sourceURL)
            let sourcePageXMLSizes = sourceParts.filter {
                $0.key.hasPrefix("visio/pages/page") && $0.key != "visio/pages/pages.xml" && $0.key.hasSuffix(".xml")
            }.map(\.value.count)
            XCTAssertEqual(sourcePageXMLSizes.count, 3)
            XCTAssertTrue(sourcePageXMLSizes.allSatisfy { $0 < 8 * 1024 * 1024 })

            let document = try MacVisioDocument(contentsOf: sourceURL, ofType: MacVisioDocument.visioType)
            defer { document.close() }
            XCTAssertEqual(document.diagram.pages.count, 3)
            for page in document.diagram.pages {
                XCTAssertEqual(page.nodes.first?.formatting.sheet["User.Payload"]?.value, largeValue)
            }
            let stableIDs = try document.diagram.pages.map { try XCTUnwrap($0.nodes.first?.id) }
            document.diagram.page.nodes[0].text = "First large save"
            document.updateChangeCount(.changeDone)
            try save(document, to: savedURL, type: MacVisioDocument.visioType, operation: .saveAsOperation)
            assertSuccessfulSave(document, at: savedURL)

            let firstParts = try VisioPackage.read(savedURL)
            let firstNative = try XCTUnwrap(firstParts["macvisio/document.json"])
            let firstStored = try NativeMetadataStorage.load(firstNative, parts: firstParts)
            let firstManifest = try XCTUnwrap(JSONSerialization.jsonObject(with: firstNative) as? [String: Any])
            XCTAssertGreaterThan(firstStored.data.count, VisioPackage.partLimit)
            XCTAssertEqual(firstManifest["encoding"] as? String, "zlib")
            XCTAssertEqual(firstManifest["decodedBytes"] as? Int, firstStored.data.count)
            XCTAssertGreaterThanOrEqual(firstStored.storageParts.count, 1)
            XCTAssertEqual(firstParts["vendor/opaque-save-probe.bin"], Data([0x00, 0xFE, 0x13, 0x80, 0x42]))
            XCTAssertTrue(firstParts.filter {
                $0.key.hasPrefix("visio/pages/page") && $0.key != "visio/pages/pages.xml" && $0.key.hasSuffix(".xml")
            }.allSatisfy { $0.value.count < 8 * 1024 * 1024 })

            let reopened = try MacVisioDocument(contentsOf: savedURL, ofType: MacVisioDocument.visioType)
            defer { reopened.close() }
            XCTAssertEqual(reopened.diagram.pages.compactMap { $0.nodes.first?.id }, stableIDs)
            for page in reopened.diagram.pages {
                XCTAssertEqual(page.nodes.first?.formatting.sheet["User.Payload"]?.value, largeValue)
            }
            XCTAssertFalse(reopened.importWarnings.contains { $0.contains("public Visio content was imported") })

            reopened.diagram.page.nodes[0].text = "Second save after payload shrink"
            for index in reopened.diagram.pages.indices {
                reopened.diagram.pages[index].nodes[0].formatting.sheet["User.Payload"] = ShapeSheetCell(value: "small payload")
            }
            reopened.updateChangeCount(.changeDone)
            try save(reopened, to: savedURL, type: MacVisioDocument.visioType, operation: .saveOperation)
            assertSuccessfulSave(reopened, at: savedURL)

            let finalParts = try VisioPackage.read(savedURL)
            let finalNative = try XCTUnwrap(finalParts["macvisio/document.json"])
            let finalStored = try NativeMetadataStorage.load(finalNative, parts: finalParts)
            let finalSegmentNames = Set(finalParts.keys.filter {
                $0.hasPrefix("macvisio/metadata/segment") && $0.hasSuffix(".mvmeta")
            })
            XCTAssertTrue(finalStored.storageParts.isEmpty)
            XCTAssertTrue(finalSegmentNames.isEmpty, "Shrinking the payload must remove old metadata chunks.")
            XCTAssertEqual(finalParts["vendor/opaque-save-probe.bin"], Data([0x00, 0xFE, 0x13, 0x80, 0x42]))

            let finalReopened = try MacVisioDocument(contentsOf: savedURL, ofType: MacVisioDocument.visioType)
            defer { finalReopened.close() }
            XCTAssertEqual(finalReopened.diagram.pages.compactMap { $0.nodes.first?.id }, stableIDs)
            XCTAssertEqual(finalReopened.diagram.page.nodes.first?.text, "Second save after payload shrink")
            XCTAssertEqual(finalReopened.diagram.page.nodes.first?.formatting.sheet["User.Payload"]?.value, "small payload")
            XCTAssertFalse(finalReopened.importWarnings.contains { $0.contains("public Visio content was imported") })

            var publicParts = finalParts
            publicParts.removeValue(forKey: "macvisio/document.json")
            NativeMetadataStorage.removeSegments(from: &publicParts)
            if let relData = publicParts["_rels/.rels"] {
                let relationships = try VisioXML.document(relData)
                for relationship in relationships.rootElement()?.elementsLocal("Relationship") ?? []
                where relationship.attr("Type") == "urn:macvisio:relationships:diagram" {
                    relationship.detach()
                }
                publicParts["_rels/.rels"] = relationships.xmlData(options: .nodePreserveAll)
            }
            try VisioPackage.write(publicParts, to: publicOnlyURL)
            let publicRead = try VisioFormat.read(from: publicOnlyURL).diagram
            XCTAssertEqual(publicRead.pages.count, 3)
            XCTAssertEqual(publicRead.page.nodes.first?.text, "Second save after payload shrink")
            for page in publicRead.pages {
                XCTAssertEqual(page.nodes.first?.formatting.sheet["User.Payload"]?.value, "small payload")
            }
        }
    }

    func testRejectedInvalidModelSavePreservesExistingFileAndDirtyState() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let url = directory.appendingPathComponent("protected.vsdx")
            var diagram = Diagram()
            diagram.page.nodes = [DiagramNode(kind: .rectangle, x: 100, y: 80, text: "Original file")]
            try VisioFormat.write(diagram, to: url)

            let document = try MacVisioDocument(contentsOf: url, ofType: MacVisioDocument.visioType)
            defer { document.close() }
            let originalBytes = try Data(contentsOf: url)
            document.diagram.page.nodes[0].width = 0
            document.updateChangeCount(.changeDone)

            let saveError = try saveResult(document, to: url, type: MacVisioDocument.visioType, operation: .saveOperation)

            XCTAssertNotNil(saveError, "Invalid model data must be rejected by NSDocument's save pipeline.")
            XCTAssertEqual(try Data(contentsOf: url), originalBytes)
            XCTAssertTrue(document.isDocumentEdited, "A rejected overwrite must leave the user's edit pending.")
            XCTAssertEqual(document.fileURL?.standardizedFileURL, url.standardizedFileURL)
        }
    }

    private func save(
        _ document: MacVisioDocument,
        to url: URL,
        type: String,
        operation: NSDocument.SaveOperationType,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        if let saveError = try saveResult(document, to: url, type: type, operation: operation, file: file, line: line) {
            throw saveError
        }
    }

    private func saveResult(
        _ document: MacVisioDocument,
        to url: URL,
        type: String,
        operation: NSDocument.SaveOperationType,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Error? {
        var completed = false
        var saveError: Error?
        document.save(to: url, ofType: type, for: operation) { error in
            saveError = error
            completed = true
        }

        let deadline = Date().addingTimeInterval(15)
        while !completed && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(completed, "NSDocument save completion did not arrive before the deadline.", file: file, line: line)
        guard completed else { throw DiagramError.invalid("NSDocument save completion timed out.") }
        return saveError
    }

    private func assertSuccessfulSave(
        _ document: MacVisioDocument,
        at url: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), file: file, line: line)
        XCTAssertEqual(document.fileURL?.standardizedFileURL, url.standardizedFileURL, file: file, line: line)
        XCTAssertFalse(document.isDocumentEdited, "A successful save should clear the edited state.", file: file, line: line)
        XCTAssertNotNil(document.fileModificationDate, "A saved document should have a modification date baseline.", file: file, line: line)
        let diskDate = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertNotNil(diskDate ?? nil, "The saved file should have a filesystem modification date.", file: file, line: line)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacVisioDocumentSavingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}
