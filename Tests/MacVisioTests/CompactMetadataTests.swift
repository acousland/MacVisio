import XCTest
@testable import MacVisio

final class CompactMetadataTests: XCTestCase {
    private let nativePart = "macvisio/document.json"

    func testLegacyFormatOneAndTwoEnvelopesRemainReadable() throws {
        let (source, diagram) = try makeSource()
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try XCTUnwrap(diagram.visioArchive)
        let content = contentOnly(diagram)

        for format in [1, 2] {
            let url = temporaryURL("legacy-\(format).vsdx")
            defer { try? FileManager.default.removeItem(at: url) }
            var parts = try publicParts(source)
            let hashes: [String: String]
            if format == 1 {
                hashes = parts.filter { $0.key.hasPrefix("visio/") && ($0.key.hasSuffix(".xml") || $0.key.hasSuffix(".rels")) }.mapValues(VisioFormat.hash)
            } else {
                hashes = parts.mapValues(VisioFormat.hash)
            }
            parts[nativePart] = try encodeEnvelope(format: format, hashes: hashes, diagram: content,
                legacyBindings: nil, compactBindings: nil, pagesPart: original.pagesPart)
            try VisioPackage.write(parts, to: url)

            let restored = try VisioFormat.read(from: url).diagram
            XCTAssertEqual(restored.pages.map(\.name), content.pages.map(\.name))
            XCTAssertEqual(restored.pages.map { $0.nodes.map(\.text) }, content.pages.map { $0.nodes.map(\.text) })
        }
    }

    func testCompactFormatFourReconstructsMatchingBaselinesByPageID() throws {
        let (source, diagram) = try makeSource()
        defer { try? FileManager.default.removeItem(at: source) }
        let original = try XCTUnwrap(diagram.visioArchive)
        var compact = compactBindings(from: original)
        compact.reverse() // Binding order is independent of the current page order.
        let url = try makeMetadataVariant(source: source, diagram: diagram, compactBindings: compact)
        defer { try? FileManager.default.removeItem(at: url) }

        let restored = try VisioFormat.read(from: url).diagram
        XCTAssertEqual(restored.pages.map(\.id), diagram.pages.map(\.id))
        XCTAssertEqual(restored.visioArchive?.pages.map(\.pageID), Array(original.pages.map(\.pageID).reversed()))
        for binding in try XCTUnwrap(restored.visioArchive?.pages) {
            let page = try XCTUnwrap(restored.pages.first { $0.id == binding.pageID })
            XCTAssertEqual(binding.original, page)
        }
        let restoredInherited = try XCTUnwrap(restored.visioArchive?.pages.first(where: { $0.pageID == diagram.pages[0].id })?.inheritedShapes)
        XCTAssertEqual(restoredInherited, try XCTUnwrap(compact.last?.inheritedShapes))
    }

    func testCompactFormatFourKeepsDistinctOriginalFallback() throws {
        let (source, diagram) = try makeSource()
        defer { try? FileManager.default.removeItem(at: source) }
        let archive = try XCTUnwrap(diagram.visioArchive)
        var compact = compactBindings(from: archive)
        var fallback = try XCTUnwrap(archive.pages.first?.original)
        fallback.name = "Older baseline"
        compact[0] = VisioFormat.NativeBinding(pageID: compact[0].pageID, visioID: compact[0].visioID,
            part: compact[0].part, nodeIDs: compact[0].nodeIDs, edgeIDs: compact[0].edgeIDs,
            inheritedShapes: compact[0].inheritedShapes, original: fallback)
        let url = try makeMetadataVariant(source: source, diagram: diagram, compactBindings: compact)
        defer { try? FileManager.default.removeItem(at: url) }

        let restored = try VisioFormat.read(from: url).diagram
        XCTAssertEqual(try XCTUnwrap(restored.visioArchive?.pages.first?.original), fallback)
    }

    func testCompactFormatFourInvalidPageReferencesFallBackToPublicDrawing() throws {
        let (source, diagram) = try makeSource()
        defer { try? FileManager.default.removeItem(at: source) }
        let archive = try XCTUnwrap(diagram.visioArchive)
        let compact = compactBindings(from: archive)
        let first = try XCTUnwrap(compact.first)
        let dangling = VisioFormat.NativeBinding(pageID: UUID(), visioID: first.visioID,
            part: first.part, nodeIDs: first.nodeIDs, edgeIDs: first.edgeIDs,
            inheritedShapes: first.inheritedShapes, original: nil)
        var invalid = compact
        invalid[0] = dangling
        let url = try makeMetadataVariant(source: source, diagram: diagram, compactBindings: invalid)
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try VisioFormat.read(from: url)
        XCTAssertTrue(result.warnings.contains { $0.contains("metadata could not be used") })
        XCTAssertEqual(result.diagram.pages.map(\.name), diagram.pages.map(\.name))
        XCTAssertEqual(result.diagram.pages.map { $0.nodes.map(\.text) }, diagram.pages.map { $0.nodes.map(\.text) })
    }

    func testCompactFormatFourRejectsDuplicateAndMissingPageBindings() throws {
        let (source, diagram) = try makeSource()
        defer { try? FileManager.default.removeItem(at: source) }
        let archive = try XCTUnwrap(diagram.visioArchive)
        let compact = compactBindings(from: archive)

        for invalid in [[compact[0], compact[0]], [compact[0]]] {
            let url = try makeMetadataVariant(source: source, diagram: diagram, compactBindings: invalid)
            defer { try? FileManager.default.removeItem(at: url) }
            let result = try VisioFormat.read(from: url)
            XCTAssertTrue(result.warnings.contains { $0.contains("metadata could not be used") })
            XCTAssertEqual(result.diagram.pages.map(\.name), diagram.pages.map(\.name))
        }
    }

    func testEditingAfterCompactRestoreSurvivesNativeAndPublicReopen() throws {
        let (source, diagram) = try makeSource()
        defer { try? FileManager.default.removeItem(at: source) }
        let archive = try XCTUnwrap(diagram.visioArchive)
        let compact = archive.pages.map { binding in
            VisioFormat.NativeBinding(pageID: binding.pageID, visioID: binding.visioID,
                part: binding.part, nodeIDs: binding.nodeIDs, edgeIDs: binding.edgeIDs,
                inheritedShapes: nil, original: nil)
        }
        let compactURL = try makeMetadataVariant(source: source, diagram: diagram, compactBindings: compact)
        let savedURL = temporaryURL("edited-after-compact.vsdx")
        let publicOnlyURL = temporaryURL("edited-after-compact-public.vsdx")
        defer {
            try? FileManager.default.removeItem(at: compactURL)
            try? FileManager.default.removeItem(at: savedURL)
            try? FileManager.default.removeItem(at: publicOnlyURL)
        }

        var edited = try VisioFormat.read(from: compactURL).diagram
        let pageID = edited.pages[0].id
        let parentID = try XCTUnwrap(edited.pages[0].nodes.first(where: { $0.formatting.isGroup })?.id)
        let childIndex = try XCTUnwrap(edited.pages[0].nodes.firstIndex(where: { $0.parentID == parentID }))
        let childID = edited.pages[0].nodes[childIndex].id
        edited.pages[0].nodes[childIndex].text = "Edited after compact restore"
        try VisioFormat.write(edited, to: savedURL)

        let reopened = try VisioFormat.read(from: savedURL).diagram
        XCTAssertEqual(reopened.pages.count, diagram.pages.count)
        XCTAssertEqual(reopened.pages.map(\.id), diagram.pages.map(\.id))
        let reopenedPage = try XCTUnwrap(reopened.pages.first { $0.id == pageID })
        let reopenedChild = try XCTUnwrap(reopenedPage.nodes.first { $0.id == childID })
        XCTAssertEqual(reopenedChild.text, "Edited after compact restore")
        XCTAssertEqual(reopenedChild.parentID, parentID)

        var parts = try VisioPackage.read(savedURL)
        let stored = try NativeMetadataStorage.load(try XCTUnwrap(parts[nativePart]), parts: parts)
        for name in stored.storageParts { parts.removeValue(forKey: name) }
        parts.removeValue(forKey: nativePart)
        try VisioPackage.write(parts, to: publicOnlyURL)
        let publicImport = try VisioFormat.read(from: publicOnlyURL).diagram
        XCTAssertEqual(publicImport.pages.count, diagram.pages.count)
        let publicPage = try XCTUnwrap(publicImport.pages.first { $0.name == diagram.pages[0].name })
        let publicChild = try XCTUnwrap(publicPage.nodes.first { $0.text == "Edited after compact restore" })
        XCTAssertEqual(publicChild.parentID, publicPage.nodes.first(where: { $0.formatting.isGroup })?.id)
    }

    func testWriterSelectsCompactFormatForLargeMultiPageDrawing() throws {
        let payloadSize = 6 * 1024 * 1024
        let largeValue = String(repeating: "P", count: payloadSize)
        var diagram = Diagram()
        diagram.pages = (0..<3).map { index in
            var page = DiagramPage(name: "Large page \(index + 1)")
            var group = DiagramNode(x: 20, y: 30, text: "")
            group.formatting.isGroup = true
            var child = DiagramNode(x: 45, y: 55, text: "Payload")
            child.parentID = group.id
            child.formatting.sheet["User.Payload"] = ShapeSheetCell(value: largeValue)
            page.nodes = [group, child]
            return page
        }
        diagram.activePageID = diagram.pages[0].id
        let source = temporaryURL("large-compact-source.vsdx")
        let publicOnly = temporaryURL("large-compact-public.vsdx")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: publicOnly)
        }

        try VisioFormat.write(diagram, to: source)
        var parts = try VisioPackage.read(source)
        let stored = try NativeMetadataStorage.load(try XCTUnwrap(parts[nativePart]), parts: parts)
        let envelope = try JSONDecoder().decode(VisioFormat.NativeEnvelope.self, from: stored.data)
        XCTAssertEqual(envelope.format, 4)
        XCTAssertNil(envelope.bindings)
        let compact = try XCTUnwrap(envelope.compactBindings)
        XCTAssertEqual(compact.count, 3)
        XCTAssertTrue(compact.allSatisfy { $0.original == nil })
        XCTAssertGreaterThan(stored.data.count, VisioPackage.partLimit)
        XCTAssertLessThan(stored.data.count, payloadSize * 4)
        XCTAssertEqual(envelope.publicHashes["[Content_Types].xml"], VisioFormat.hash(try XCTUnwrap(parts["[Content_Types].xml"])))

        for binding in compact {
            let page = try XCTUnwrap(envelope.diagram.pages.first { $0.id == binding.pageID })
            XCTAssertEqual(binding.original ?? page, page)
            XCTAssertEqual(Set(binding.nodeIDs.keys), Set(page.nodes.map(\.id)))
            let child = try XCTUnwrap(page.nodes.first { $0.text == "Payload" })
            let parent = try XCTUnwrap(page.nodes.first { $0.id == child.parentID })
            XCTAssertTrue(parent.formatting.isGroup)
        }

        let restored = try VisioFormat.read(from: source).diagram
        XCTAssertEqual(restored.pages.map(\.id), diagram.pages.map(\.id))
        for (originalPage, restoredPage) in zip(diagram.pages, restored.pages) {
            XCTAssertEqual(restoredPage.nodes.map(\.id), originalPage.nodes.map(\.id))
            XCTAssertEqual(restoredPage.nodes.map(\.parentID), originalPage.nodes.map(\.parentID))
            XCTAssertEqual(restoredPage.nodes.last?.formatting.sheet["User.Payload"]?.value.count, payloadSize)
        }

        for name in stored.storageParts { parts.removeValue(forKey: name) }
        parts.removeValue(forKey: nativePart)
        try VisioPackage.write(parts, to: publicOnly)
        let publicImport = try VisioFormat.read(from: publicOnly).diagram
        XCTAssertEqual(publicImport.pages.map(\.name), diagram.pages.map(\.name))
        for page in publicImport.pages {
            XCTAssertEqual(page.nodes.last?.formatting.sheet["User.Payload"]?.value.count, payloadSize)
            XCTAssertEqual(page.nodes.last?.text, "Payload")
            XCTAssertEqual(page.nodes.last?.parentID, page.nodes.first?.id)
        }
    }

    private func makeSource() throws -> (URL, Diagram) {
        var first = DiagramPage(name: "First")
        var group = DiagramNode(x: 20, y: 30, text: "")
        group.formatting.isGroup = true
        var child = DiagramNode(x: 45, y: 55, text: "Child")
        child.parentID = group.id
        first.nodes = [group, child]
        var second = DiagramPage(name: "Second")
        second.nodes = [DiagramNode(x: 80, y: 90, text: "Other page")]
        var diagram = Diagram()
        diagram.pages = [first, second]
        diagram.activePageID = first.id
        let url = temporaryURL("compact-source.vsdx")
        try VisioFormat.write(diagram, to: url)
        return (url, try VisioFormat.read(from: url).diagram)
    }

    private func compactBindings(from archive: VisioDocumentArchive) -> [VisioFormat.NativeBinding] {
        archive.pages.map { binding in
            let inherited: [UUID: VisioInheritedShape]?
            if let parent = binding.original.nodes.first(where: { $0.formatting.isGroup }),
               let child = binding.original.nodes.first(where: { $0.parentID == parent.id }) {
                inherited = [child.id: VisioInheritedShape(masterShapeID: "1", parentID: parent.id, implicit: true)]
            } else {
                inherited = nil
            }
            return VisioFormat.NativeBinding(pageID: binding.pageID, visioID: binding.visioID,
                part: binding.part, nodeIDs: binding.nodeIDs, edgeIDs: binding.edgeIDs,
                inheritedShapes: inherited, original: nil)
        }
    }

    private func makeMetadataVariant(source: URL, diagram: Diagram,
        compactBindings: [VisioFormat.NativeBinding]) throws -> URL {
        let archive = try XCTUnwrap(diagram.visioArchive)
        var parts = try publicParts(source)
        let hashes = parts.mapValues(VisioFormat.hash)
        parts[nativePart] = try encodeEnvelope(format: 4, hashes: hashes, diagram: contentOnly(diagram),
            legacyBindings: nil, compactBindings: compactBindings, pagesPart: archive.pagesPart)
        let url = temporaryURL("compact-\(UUID().uuidString).vsdx")
        try VisioPackage.write(parts, to: url)
        return url
    }

    private func encodeEnvelope(format: Int, hashes: [String: String], diagram: Diagram,
        legacyBindings: [VisioPageBinding]?, compactBindings: [VisioFormat.NativeBinding]?,
        pagesPart: String) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(VisioFormat.NativeEnvelope(format: format, publicHashes: hashes,
            diagram: diagram, bindings: legacyBindings, compactBindings: compactBindings,
            pagesPart: pagesPart, legacyParts: nil, masterExpansionVersion: 1,
            connectorHierarchyVersion: 1, connectionPointsVersion: 1,
            coordinateTransformVersion: 1, textRunsVersion: 1, textFieldsVersion: 1,
            geometryVersion: 4, controlsVersion: 1))
    }

    private func contentOnly(_ diagram: Diagram) -> Diagram {
        var content = diagram
        content.visioArchive = nil
        return content
    }

    private func publicParts(_ url: URL) throws -> [String: Data] {
        var parts = try VisioPackage.read(url)
        parts.removeValue(forKey: nativePart)
        return parts
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MacVisio-\(UUID().uuidString)-\(name)")
    }
}
