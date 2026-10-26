import AppKit
import XCTest

@testable import MacVisio

final class DocumentSaveImpactTests: XCTestCase {
    func testOpaqueBytesAndUnrelatedEditsStayQuietWhileAffectedForeignObjectNeedsReview() {
        let original = fixture(shapeXML: "<ForeignData ForeignType=\"Object\"/>")
        let baseline = DocumentSaveImpact.Baseline(snapshot: original)
        var unrelated = original
        unrelated.page.nodes[1].text = "Unrelated edit"
        XCTAssertFalse(
            DocumentSaveImpact.assess(
                snapshot: unrelated, baseline: baseline, diagnostics: [], format: .visio
            ).requiresReview)
        var affected = original
        affected.page.nodes[0].text = "Changed foreign object"
        let assessment = DocumentSaveImpact.assess(
            snapshot: affected, baseline: baseline, diagnostics: [], format: .visio)
        XCTAssertEqual(assessment.risks.map(\.feature), [.foreignObject])
        XCTAssertEqual(
            assessment.risks.first?.target, .shape(page: original.page.id, shape: original.page.nodes[0].id))
        XCTAssertFalse(
            DocumentSaveImpact.assess(snapshot: original, baseline: baseline, diagnostics: [], format: .visio)
                .requiresReview,
            "Undo to the immutable source baseline removes the edit impact.")
        XCTAssertFalse(
            DocumentSaveImpact.assess(
                snapshot: affected, baseline: baseline, diagnostics: [], format: .native
            ).requiresReview)
    }

    func testMovingSupportedBitmapIsQuietWhileMalformedBytesAndUnknownForeignFeaturesNeedReview() throws {
        try onMain {
            _ = NSApplication.shared
            let bitmap = try XCTUnwrap(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32))
            let pixels = try XCTUnwrap(bitmap.bitmapData)
            pixels[0] = 255
            pixels[1] = 0
            pixels[2] = 0
            pixels[3] = 255
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let xml =
                "<ForeignData ForeignType=\"Bitmap\" CompressionType=\"PNG\"><Rel xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\" r:id=\"rId1\"/></ForeignData>"
            var original = fixture(shapeXML: xml)
            original.page.nodes[0].formatting.image = EmbeddedImage(data: png, mimeType: "image/png")
            var moved = original
            moved.page.nodes[0].x += 20
            XCTAssertFalse(
                DocumentSaveImpact.assess(
                    snapshot: moved, baseline: .init(snapshot: original),
                    diagnostics: [], format: .visio
                ).requiresReview)
            moved.page.nodes[0].formatting.image?.data = Data("malformed image".utf8)
            XCTAssertEqual(
                DocumentSaveImpact.assess(
                    snapshot: moved, baseline: .init(snapshot: original),
                    diagnostics: [], format: .visio
                ).risks.first?.feature, .foreignObject)
            var unknown = fixture(
                shapeXML: xml.replacingOccurrences(
                    of: "</ForeignData>", with: "<UnknownAction/></ForeignData>"))
            unknown.page.nodes[0].formatting.image = EmbeddedImage(data: png, mimeType: "image/png")
            // Moving it writes the object back unchanged; an edit to the object itself needs review.
            var affected = unknown
            affected.page.nodes[0].text = "Edited"
            XCTAssertEqual(
                DocumentSaveImpact.assess(
                    snapshot: affected, baseline: .init(snapshot: unknown),
                    diagnostics: [], format: .visio
                ).risks.first?.feature, .foreignObject)
        }
    }

    func testKnownSectionsAndLiteralMetadataStayQuietButAffectedUnknownFeaturesRemainUnresolved() {
        let known = fixture(
            shapeXML: """
                <Cell N="UnknownLiteralMetadata" V="1" F="1"/>
                <Cell N="LocPinX" V="0.5" F="Width*0.5"/>
                <Section N="User"><Row N="Custom"><Cell N="Value" V="2" F="GUARD(1+1)"/></Row></Section>
                <Section N="Property"><Row N="Owner"><Cell N="Value" V="Name"/></Row></Section>
                <Section N="Character"><Row IX="0"><Cell N="Font" V="Arial" F="FONT(&quot;Arial&quot;)"/></Row></Section>
                <Section N="Geometry"><Row IX="0"><Cell N="X" V="0.5" F="Width*0.5"/></Row></Section>
                <Section N="Paragraph"/><Section N="Hyperlink"/><Section N="Connection"/>
                <Section N="Control"/><Section N="Controls"/><Section N="Field"/>
                """)
        var changed = known
        changed.page.nodes[0].text = "Edited"
        XCTAssertFalse(
            DocumentSaveImpact.assess(
                snapshot: changed, baseline: .init(snapshot: known),
                diagnostics: [], format: .visio
            ).requiresReview)
        for xml in [
            "<Section N=\"UnknownSolution\"/>", "<UnknownFeature/>",
            "<Cell N=\"EventDblClick\" F=\"GUARD(Width)\"/>",
            "<Section N=\"User\"><Row N=\"Bad\"><Cell N=\"Value\" F=\"UnknownFunction()\"/></Row></Section>",
        ] {
            let original = fixture(shapeXML: xml)
            var unrelated = original
            unrelated.page.nodes[1].text = "Other owner edit"
            XCTAssertFalse(
                DocumentSaveImpact.assess(
                    snapshot: unrelated, baseline: .init(snapshot: original),
                    diagnostics: [], format: .visio
                ).requiresReview)
            var affected = original
            affected.page.nodes[0].text = "Affected owner edit"
            let impact = DocumentSaveImpact.assess(
                snapshot: affected, baseline: .init(snapshot: original),
                diagnostics: [], format: .visio)
            XCTAssertEqual(impact.risks.first?.feature, .unresolvedSource)
            XCTAssertEqual(
                impact.risks.first?.target, .shape(page: original.page.id, shape: original.page.nodes[0].id))
            XCTAssertFalse(
                DocumentSaveImpact.assess(
                    snapshot: original, baseline: .init(snapshot: original),
                    diagnostics: [], format: .visio
                ).requiresReview)
        }
    }

    func testMissingBoundElementIsUnresolvedWhileUnboundNativeObjectsStayQuiet() {
        var original = fixture()
        original.visioArchive?.parts["visio/pages/page1.xml"] = Data(
            "<PageContents><Shapes><Shape ID=\"2\"/></Shapes></PageContents>".utf8)
        var affected = original
        affected.page.nodes[0].text = "Changed missing source owner"
        let impact = DocumentSaveImpact.assess(
            snapshot: affected, baseline: .init(snapshot: original), diagnostics: [], format: .visio)
        XCTAssertEqual(impact.risks.first?.feature, .unresolvedSource)
        XCTAssertEqual(
            impact.risks.first?.target, .shape(page: original.page.id, shape: original.page.nodes[0].id))
        XCTAssertEqual(impact.risks.first?.source.visioID, "1")
        XCTAssertEqual(impact.risks.first?.source.feature, "missing-bound-source")
        var unrelated = original
        unrelated.page.nodes[1].text = "Changed existing owner"
        XCTAssertFalse(
            DocumentSaveImpact.assess(
                snapshot: unrelated, baseline: .init(snapshot: original), diagnostics: [], format: .visio
            ).requiresReview)
        var native = DiagramNode()
        native.formatting.sourceShapeID = "99"
        original.page.nodes.append(native)
        var nativeEdit = original
        nativeEdit.page.nodes[2].text = "Changed unbound native owner"
        XCTAssertFalse(
            DocumentSaveImpact.assess(
                snapshot: nativeEdit, baseline: .init(snapshot: original), diagnostics: [], format: .visio
            ).requiresReview)
    }

    func testActionsAreExplicitUnsupportedBehaviorOnAnAffectedObject() {
        let original = fixture(
            shapeXML:
                "<Section N=\"Actions\"><Row N=\"Run\"><Cell N=\"Action\" F=\"RUNADDON(&quot;Example&quot;)\"/></Row></Section>"
        )
        var changed = original
        changed.page.nodes[0].text = "Changed"
        let impact = DocumentSaveImpact.assess(
            snapshot: changed, baseline: .init(snapshot: original),
            diagnostics: [], format: .visio)
        XCTAssertEqual(impact.risks.map(\.feature), [.actions])
        XCTAssertEqual(impact.risks.first?.dimension, .behavior)
        XCTAssertEqual(impact.risks.first?.source.feature, "Section:Actions")
    }

    func testSignatureSolutionAndMasterCellChangesHaveExplicitDimensions() {
        var original = fixture(shapeAttributes: "Master=\"9\"")
        original.visioArchive?.parts["_xmlsignatures/sig1.xml"] = Data("signature".utf8)
        original.visioArchive?.parts["visio/solutions/solution1.xml"] = Data("solution".utf8)
        var changed = original
        changed.page.nodes[0].formatting.sheet["User.Custom"] = ShapeSheetCell(
            value: "5", formula: "UnknownFunction()")
        let assessment = DocumentSaveImpact.assess(
            snapshot: changed, baseline: .init(snapshot: original), diagnostics: [], format: .visio)
        XCTAssertEqual(
            Set(assessment.risks.map { $0.feature.rawValue }), ["signature", "solution", "masterRelation"])
        XCTAssertEqual(assessment.risks.first { $0.feature == .signature }?.dimension, .preservation)
        XCTAssertEqual(assessment.risks.first { $0.feature == .masterRelation }?.source.visioID, "1")
        XCTAssertEqual(assessment.risks.first { $0.feature == .solution }?.target, .document)
    }

    func testInheritedFormulaCacheRefreshDoesNotBecomeMasterOverrideButAuthoredEditsDo() {
        var original = fixture(shapeAttributes: "Master=\"9\"", shapeXML: "<Cell N=\"TxtLocPinX\" V=\"1\" F=\"TxtWidth/2\"/>")
        original.page.nodes[0].formatting.sheet["TxtLocPinX"] = ShapeSheetCell(value: "1", formula: "TxtWidth/2")
        var cache = original
        cache.page.nodes[0].formatting.sheet["TxtLocPinX"]?.value = "1.5"
        XCTAssertFalse(DocumentSaveImpact.assess(snapshot: cache, baseline: .init(snapshot: original),
            diagnostics: [], format: .visio).risks.contains { $0.feature == .masterRelation })
        var formula = cache
        formula.page.nodes[0].formatting.sheet["TxtLocPinX"]?.formula = "TxtWidth/3"
        var unit = cache
        unit.page.nodes[0].formatting.sheet["TxtLocPinX"]?.unit = "MM"
        var literal = cache
        literal.page.nodes[0].formatting.sheet["TxtLocPinX"]?.formula = ""
        var parent = cache
        parent.page.nodes[0].parentID = original.page.nodes[1].id
        for edited in [formula, unit, literal, parent] {
            XCTAssertTrue(DocumentSaveImpact.assess(snapshot: edited, baseline: .init(snapshot: original),
                diagnostics: [], format: .visio).risks.contains { $0.feature == .masterRelation })
        }
        // Moving or resizing an instance writes its own geometry, as Visio does; that keeps the master link.
        var resized = original
        resized.page.nodes[0].formatting.sheet["LocPinX"] = ShapeSheetCell(value: "2", formula: "Width*0.5")
        resized.page.nodes[0].x += 10
        XCTAssertFalse(DocumentSaveImpact.assess(snapshot: resized, baseline: .init(snapshot: original),
            diagnostics: [], format: .visio).risks.contains { $0.feature == .masterRelation })
    }

    func testFailedFormulaMustBeCurrentAndItsObjectAffected() {
        let original = fixture()
        let node = original.page.nodes[0]
        let issue = DocumentDiagnostic.calculationFailure(
            "Unknown", code: "calculation.geometry.cell",
            page: original.page.id, shape: node.id, binding: original.visioArchive?.pages.first,
            sourceShapeID: nil, cell: "User.Bad", feature: "geometry")
        var changed = original
        changed.page.nodes[0].x += 10
        XCTAssertEqual(
            DocumentSaveImpact.assess(
                snapshot: changed, baseline: .init(snapshot: original), diagnostics: [issue], format: .visio
            ).risks.map(\.feature), [.failedFormula])
        var stale = issue
        stale.displayState = .stale
        XCTAssertFalse(
            DocumentSaveImpact.assess(
                snapshot: changed, baseline: .init(snapshot: original), diagnostics: [stale], format: .visio
            ).requiresReview)
        var unrelated = original
        unrelated.page.nodes[1].x += 10
        XCTAssertFalse(
            DocumentSaveImpact.assess(
                snapshot: unrelated, baseline: .init(snapshot: original), diagnostics: [issue], format: .visio
            ).requiresReview)
        var evaluated = issue
        evaluated.displayState = .evaluated
        evaluated.severity = .information
        XCTAssertFalse(
            DocumentSaveImpact.assess(
                snapshot: changed, baseline: .init(snapshot: original),
                diagnostics: [evaluated], format: .visio
            ).requiresReview)
        var otherCode = issue
        otherCode.code = "calculation.unrelated"
        XCTAssertFalse(
            DocumentSaveImpact.assess(
                snapshot: changed, baseline: .init(snapshot: original),
                diagnostics: [otherCode], format: .visio
            ).requiresReview)
    }

    func testLegacyReconstructionAndUnresolvedSourceDoNotBecomeAssumedSafe() {
        var original = fixture()
        original.legacySource = LegacyVisioSource(
            data: Data("original".utf8), title: original.title, pages: original.pages)
        XCTAssertFalse(
            DocumentSaveImpact.assess(
                snapshot: original, baseline: .init(snapshot: original), diagnostics: [], format: .legacy
            ).requiresReview)
        var changed = original
        changed.page.nodes[0].text = "Changed"
        XCTAssertEqual(
            DocumentSaveImpact.assess(
                snapshot: changed, baseline: .init(snapshot: original), diagnostics: [], format: .legacy
            ).risks.first?.feature, .legacyReconstruction)
        original.visioArchive?.parts["visio/pages/page1.xml"] = Data("broken".utf8)
        changed = original
        changed.page.nodes[0].text = "Changed"
        XCTAssertEqual(
            DocumentSaveImpact.assess(
                snapshot: changed, baseline: .init(snapshot: original), diagnostics: [], format: .visio
            ).risks.first?.feature, .unresolvedSource)
    }

    func testAutosaveRejectsUnsafeOriginalWithoutTouchingItsBytesAndOtherDocumentStaysIndependent() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = try directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = try signedSource(in: directory)
            let originalBytes = try Data(contentsOf: source)
            let document = try MacVisioDocument(contentsOf: source, ofType: MacVisioDocument.visioType)
            let other = MacVisioDocument()
            defer {
                document.close()
                other.close()
            }
            var next = document.diagram
            next.page.nodes[0].text = "Edited"
            document.replace(with: next, action: "Edit")
            var prompted = false
            document.resolveSaveImpact = { _ in
                prompted = true
                return .cancel
            }
            let error = try save(
                document, to: source, type: MacVisioDocument.visioType, operation: .autosaveInPlaceOperation)
            XCTAssertTrue(error is DocumentSaveImpact.UnsafeOverwrite)
            XCTAssertFalse(prompted)
            XCTAssertEqual(try Data(contentsOf: source), originalBytes)
            XCTAssertTrue(document.isDocumentEdited)
            XCTAssertTrue(document.lastSaveImpact.requiresReview)
            XCTAssertFalse(other.lastSaveImpact.requiresReview)
            XCTAssertTrue(other.currentDiagnostics.isEmpty)
        }
    }

    func testSeparateNativeCopyUsesCapturedSnapshotAndFailedCopyDoesNotAcknowledgeOrChangeOriginal() throws {
        try onMain {
            _ = NSApplication.shared
            let directory = try directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let source = try signedSource(in: directory)
            let originalBytes = try Data(contentsOf: source)
            let document = try MacVisioDocument(contentsOf: source, ofType: MacVisioDocument.visioType)
            defer { document.close() }
            var next = document.diagram
            next.page.nodes[0].text = "Captured edit"
            document.replace(with: next, action: "Edit")
            let missing = directory.appendingPathComponent("missing/copy.macvisio")
            document.resolveSaveImpact = { _ in .nativeCopy(missing) }
            XCTAssertNotNil(
                try save(document, to: source, type: MacVisioDocument.visioType, operation: .saveOperation))
            XCTAssertTrue(document.isDocumentEdited)
            XCTAssertEqual(try Data(contentsOf: source), originalBytes)
            let copy = directory.appendingPathComponent("copy.macvisio")
            document.resolveSaveImpact = { _ in .nativeCopy(copy) }
            document.didCaptureSaveSnapshot = {
                document.diagram.page.nodes[0].text = "Later edit"
                document.updateChangeCount(.changeDone)
            }
            defer { document.didCaptureSaveSnapshot = nil }
            XCTAssertNil(
                try save(document, to: source, type: MacVisioDocument.visioType, operation: .saveOperation))
            let reopened = try JSONDecoder().decode(Diagram.self, from: Data(contentsOf: copy))
            XCTAssertEqual(reopened.page.nodes[0].text, "Captured edit")
            XCTAssertEqual(document.diagram.page.nodes[0].text, "Later edit")
            XCTAssertEqual(try Data(contentsOf: source), originalBytes)
            XCTAssertEqual(document.fileURL, source)
            XCTAssertTrue(document.isDocumentEdited)
            XCTAssertTrue(document.lastSaveImpact.requiresReview)
        }
    }

    private func fixture(shapeAttributes: String = "", shapeXML: String = "") -> Diagram {
        var model = Diagram()
        model.page.nodes = [DiagramNode(), DiagramNode()]
        let binding = VisioPageBinding(
            pageID: model.page.id, visioID: "1", part: "visio/pages/page1.xml", original: model.page,
            nodeIDs: [model.page.nodes[0].id: "1", model.page.nodes[1].id: "2"], edgeIDs: [:])
        model.visioArchive = VisioDocumentArchive(
            parts: [
                "visio/pages/page1.xml": Data(
                    "<PageContents><Shapes><Shape ID=\"1\" \(shapeAttributes)>\(shapeXML)</Shape><Shape ID=\"2\"/></Shapes></PageContents>"
                        .utf8),
                "custom/harmless.bin": Data("opaque bytes".utf8),
            ], pagesPart: "visio/pages/pages.xml", pages: [binding])
        return model
    }
    private func signedSource(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("source.vsdx")
        var model = Diagram()
        model.page.nodes = [DiagramNode(text: "Original")]
        try VisioFormat.write(model, to: url)
        var parts = try VisioPackage.read(url)
        parts["_xmlsignatures/sig1.xml"] = Data("<Signature/>".utf8)
        try VisioPackage.write(parts, to: url)
        return url
    }
    private func save(
        _ document: MacVisioDocument, to url: URL, type: String, operation: NSDocument.SaveOperationType
    ) throws -> Error? {
        var completed = false
        var result: Error?
        document.save(to: url, ofType: type, for: operation) {
            result = $0
            completed = true
        }
        let deadline = Date().addingTimeInterval(20)
        while !completed && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard completed else { throw DiagramError.invalid("Save-impact test timed out") }
        return result
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacVisioSaveImpact-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}
