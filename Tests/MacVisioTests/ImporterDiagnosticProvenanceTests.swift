import AppKit
import XCTest
@testable import MacVisio

final class ImporterDiagnosticProvenanceTests: XCTestCase {
    private var directories: [URL] = []
    override func tearDown() {
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories = []; super.tearDown()
    }

    func testRealImporterWarningsKeepDistinctObjectCellAndPartProvenance() throws {
        let url = try fixture { shapes in
            for shape in shapes { VisioXML.set(shape, "FillPattern", "2") }
        }
        let imported = try VisioFormat.read(from: url)
        let issues = imported.diagnostics.filter { $0.code == "import.fill-pattern" }
        XCTAssertEqual(issues.count, 2)
        XCTAssertEqual(Set(issues.map(\.id)).count, 2)
        XCTAssertEqual(Set(issues.compactMap { $0.target.objectID }), Set(imported.diagram.page.nodes.map(\.id)))
        XCTAssertTrue(issues.allSatisfy { $0.source.part == "visio/pages/page1.xml" && $0.source.cell == "FillPattern" && $0.source.visioID != nil && $0.displayState == .cached })
        let document = try MacVisioDocument(contentsOf: url, ofType: MacVisioDocument.visioType)
        defer { document.close() }
        XCTAssertEqual(document.currentDiagnostics.filter { $0.code == "import.fill-pattern" }.count, 2)
        XCTAssertFalse(document.currentDiagnostics.contains { $0.code == "import.anonymous" && $0.message == issues.first?.message })
        XCTAssertTrue(document.currentDiagnostics.filter { $0.origin == .importer }.allSatisfy { $0.inputKey == document.diagnosticInputKey })
    }

    func testTypedSourceFactsSurviveNativeEnvelopeFastPathAndNativeFileRead() throws {
        let url = try fixture { shapes in
            for shape in shapes { VisioXML.set(shape, "FillPattern", "2") }
        }
        let original = try VisioFormat.read(from: url)
        let fast = url.deletingLastPathComponent().appendingPathComponent("Fast.vsdx")
        // An unchanged public source is deliberately copied byte-for-byte and
        // gains no private envelope. A harmless page rename exercises the real
        // metadata writer while retaining the patterned source shapes.
        var nativeModel = original.diagram; nativeModel.page.name = "Native envelope"
        try VisioFormat.write(nativeModel, to: fast)
        var phases: [String] = []
        let reopened = try VisioFormat.read(from: fast, trace: { phases.append($0) })
        XCTAssertTrue(phases.contains("nativeMetadata"))
        XCTAssertEqual(Set(reopened.diagnostics.filter { $0.code == "import.fill-pattern" }.map(\.id)),
                       Set(original.diagnostics.filter { $0.code == "import.fill-pattern" }.map(\.id)))
        let native = MacVisioDocument(); defer { native.close() }
        try native.read(from: JSONEncoder().encode(original.diagram), ofType: MacVisioDocument.nativeType)
        XCTAssertEqual(native.currentDiagnostics.filter { $0.code == "import.fill-pattern" }.count, 2)
    }

    func testHarmlessOpaquePartHasNoMaterialWarningAndCachedPolicyIsInformation() throws {
        let url = try fixture { _ in }
        var parts = try VisioPackage.read(url); parts["vendor/harmless.bin"] = Data([0, 0xFF, 0xA5])
        try VisioPackage.write(parts, to: url)
        let document = try MacVisioDocument(contentsOf: url, ofType: MacVisioDocument.visioType)
        defer { document.close() }
        let policy = try XCTUnwrap(document.currentDiagnostics.first { $0.code == "import.cached-policy" })
        XCTAssertEqual(policy.severity, .information)
        XCTAssertFalse(document.currentDiagnostics.contains(where: \.isMaterial))
        XCTAssertEqual(document.diagram.visioArchive?.parts["vendor/harmless.bin"], Data([0, 0xFF, 0xA5]))
    }

    func testSuccessfulSourceRebaseRetiresResolvedTypedWarningWithoutAnonymousResurrection() throws {
        _ = NSApplication.shared
        let url = try fixture { shapes in
            for shape in shapes { VisioXML.set(shape, "FillPattern", "2") }
        }
        let document = try MacVisioDocument(contentsOf: url, ofType: MacVisioDocument.visioType)
        defer { document.close() }
        let warning = try XCTUnwrap(document.currentDiagnostics.first { $0.code == "import.fill-pattern" })
        var next = document.diagram
        for index in next.page.nodes.indices { next.page.nodes[index].fill = "#123456" }
        document.replace(with: next, action: "Replace patterned fill")
        // A separate public destination is authorized without acknowledging a
        // potentially destructive same-original overwrite.
        let destination = url.deletingLastPathComponent().appendingPathComponent("Resolved.vsdx")
        var completed = false, saveError: Error?
        document.save(to: destination, ofType: MacVisioDocument.visioType, for: .saveAsOperation) {
            saveError = $0; completed = true
        }
        let deadline = Date().addingTimeInterval(20)
        while !completed && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(completed); XCTAssertNil(saveError)
        XCTAssertFalse(document.currentDiagnostics.contains { $0.code == "import.fill-pattern" })
        XCTAssertFalse(document.currentDiagnostics.contains { $0.code == "import.anonymous" && $0.message == warning.message })
        XCTAssertFalse(try VisioFormat.read(from: destination).diagnostics.contains { $0.code == "import.fill-pattern" })
    }

    func testIgnoredActionsHaveActualSourceProvenanceWithoutExecution() throws {
        let url = try fixture { shapes in
            let section = XMLElement(name: "Section"); section.setAttr("N", "Actions")
            let row = XMLElement(name: "Row"); row.setAttr("IX", "0")
            let cell = XMLElement(name: "Cell"); cell.setAttr("N", "Action"); cell.setAttr("F", "RUNADDON(\"not-an-executable\")"); cell.setAttr("V", "0")
            row.addChild(cell); section.addChild(row); shapes[0].addChild(section)
        }
        let imported = try VisioFormat.read(from: url)
        let issue = try XCTUnwrap(imported.diagnostics.first { $0.code == "import.ignored-shape-action" })
        XCTAssertEqual(issue.target, .shape(page: imported.diagram.page.id, shape: imported.diagram.page.nodes[0].id))
        XCTAssertEqual(issue.source.feature, "Actions"); XCTAssertEqual(issue.dimension, .behavior)
        XCTAssertTrue(ImportedSourceDiagnostics.scan(imported.diagram).contains { $0.id == issue.id })
    }

    func testExplicitOpenIdentityCoalescesSymlinkAliasesWithoutChangingHistoryURL() throws {
        let folder = try directory()
        let original = folder.appendingPathComponent("Original.macvisio"), alias = folder.appendingPathComponent("Alias.macvisio")
        let bytes = Data("owned identity fixture".utf8); try bytes.write(to: original)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        XCTAssertEqual(DocumentWorkflow.canonicalDrawingURL(original), DocumentWorkflow.canonicalDrawingURL(alias))
        XCTAssertNotEqual(RecentDrawingStore.canonical(original), RecentDrawingStore.canonical(alias))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("M2-import-diagnostics-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url); return url
    }
    private func fixture(_ change: ([XMLElement]) throws -> Void) throws -> URL {
        var diagram = Diagram(); diagram.page.nodes = [DiagramNode(text: "First"), DiagramNode(x: 400, text: "Second")]
        let url = try directory().appendingPathComponent("Source.vsdx")
        try VisioFormat.write(diagram, to: url)
        var parts = try VisioPackage.read(url)
        parts.removeValue(forKey: "macvisio/document.json"); NativeMetadataStorage.removeSegments(from: &parts)
        let pagePart = "visio/pages/page1.xml"
        let xml = try VisioXML.document(try XCTUnwrap(parts[pagePart]))
        let shapes = try XCTUnwrap(xml.rootElement()?.firstLocal("Shapes")).elementsLocal("Shape")
        try change(shapes); parts[pagePart] = xml.xmlData
        try VisioPackage.write(parts, to: url); return url
    }
}
