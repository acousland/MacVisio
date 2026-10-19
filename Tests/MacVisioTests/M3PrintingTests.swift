import AppKit
import CryptoKit
import MacVisioInfrastructure
import PDFKit
import XCTest
@testable import MacVisio

final class M3PrintingTests: XCTestCase {
    func testPreparationCapturesMixedForegroundPagesBackgroundsAndPrintLayerPolicy() throws {
        try onMain {
            _ = NSApplication.shared
            var diagram = fixture()
            let originalIDs = diagram.orderedPages.filter { $0.isBackground != true }.map(\.id)
            let owner = LifecycleJobOwner()
            let input = LifecycleJobInput(ownerID: owner.id, snapshotID: UUID(), revision: 71)
            var outcome: Result<OwnedPreparedPDF, Error>?
            try OwnedPrintJobs.submit(snapshot: diagram, input: input, owner: owner) { outcome = $0 }
            diagram.pages[0].nodes[0].text = "New live text"
            diagram.pages[0].nodes[0].fill = "#00FFFF"
            try pump(until: { outcome != nil })
            let prepared = try XCTUnwrap(outcome).get()
            XCTAssertEqual(prepared.input, input)
            XCTAssertEqual(prepared.pageIDs, originalIDs)
            XCTAssertEqual(prepared.preparation.preparedObjects, 4)
            XCTAssertGreaterThan(prepared.preparation.mainBatches, 0)
            XCTAssertLessThanOrEqual(prepared.data.count, OwnedExportJobs.maximumRecordingBytes)
            let pdf = try document(prepared.data)
            XCTAssertEqual(pdf.numberOfPages, 2)
            XCTAssertEqual(pdf.page(at: 1)?.getBoxRect(.mediaBox).size, CGSize(width: 300, height: 200))
            XCTAssertEqual(pdf.page(at: 2)?.getBoxRect(.mediaBox).size, CGSize(width: 400, height: 250))
            let text = try XCTUnwrap(PDFDocument(data: prepared.data)?.string)
            XCTAssertTrue(text.contains("Captured first"))
            XCTAssertTrue(text.contains("Background label"))
            XCTAssertFalse(text.contains("New live text"))
            XCTAssertFalse(text.contains("Screen only"))
            XCTAssertFalse(text.contains("Hidden layer"))
        }
    }

    func testNativeAllPagePDFPreservesOrderBackgroundAndTwentyMillimetreMarkerAt100Percent() throws {
        try onMain {
            _ = NSApplication.shared
            let prepared = try prepare(fixture())
            let session = try DiagramPrintSession(prepared: prepared, title: "Mixed-size drawing")
            XCTAssertEqual(session.printInfo.scalingFactor, 1)
            XCTAssertEqual(session.printInfo.paperSize, CGSize(width: 400, height: 250))
            XCTAssertEqual(session.printInfo.leftMargin, 0)
            XCTAssertEqual(session.printInfo.rightMargin, 0)
            XCTAssertEqual(session.printInfo.topMargin, 0)
            XCTAssertEqual(session.printInfo.bottomMargin, 0)
            XCTAssertEqual(session.printInfo.horizontalPagination, .clip)
            XCTAssertEqual(session.printInfo.verticalPagination, .clip)
            var range = NSRange()
            XCTAssertTrue(session.view.knowsPageRange(&range))
            XCTAssertEqual(range, NSRange(location: 1, length: 2))
            XCTAssertEqual(session.view.rectForPage(1).size, CGSize(width: 300, height: 200))
            XCTAssertEqual(session.view.rectForPage(2).size, CGSize(width: 400, height: 250))
            XCTAssertEqual(session.view.rectForPage(3), .zero)
            let native = try savePDF(session, testName: #function)
            XCTAssertEqual(native.numberOfPages, 2)
            for number in 1...2 {
                XCTAssertEqual(native.page(at: number)?.getBoxRect(.mediaBox).size, CGSize(width: 400, height: 250))
            }
            let first = try raster(try XCTUnwrap(native.page(at: 1)))
            let second = try raster(try XCTUnwrap(native.page(at: 2)))
            XCTAssertGreaterThan(first.count(where: { $0.red > 0.8 && $0.green < 0.2 && $0.blue < 0.2 }), 400)
            XCTAssertEqual(first.count(where: { $0.blue > 0.8 && $0.red < 0.2 && $0.green < 0.2 }), 0)
            XCTAssertGreaterThan(second.count(where: { $0.blue > 0.8 && $0.red < 0.2 && $0.green < 0.2 }), 400)
            let red = try XCTUnwrap(second.bounds(where: { $0.red > 0.8 && $0.green < 0.2 && $0.blue < 0.2 }))
            // 1000 mm at 1:50 is 20 mm, independently measured in the actual
            // native operation's saved physical PDF at 144 raster pixels/inch.
            XCTAssertEqual(Double(red.width) / 2 / 72 * 25.4, 20, accuracy: 0.3)
            XCTAssertEqual(Double(red.height) / 2, 30, accuracy: 1)
            XCTAssertNil(session.failure)
            XCTAssertNil(session.view.failure)
        }
    }

    func testNativeRangePrintsOnlySelectedForegroundPageAtNaturalSize() throws {
        try onMain {
            _ = NSApplication.shared
            let session = try DiagramPrintSession(prepared: prepare(fixture()), title: "Foreground range")
            session.printInfo.dictionary()[NSPrintInfo.AttributeKey.allPages] = false
            session.printInfo.dictionary()[NSPrintInfo.AttributeKey.firstPage] = 2
            session.printInfo.dictionary()[NSPrintInfo.AttributeKey.lastPage] = 2
            XCTAssertEqual(try session.view.selectedPages(printInfo: session.printInfo), 2...2)
            let native = try savePDF(session, testName: #function)
            XCTAssertEqual(native.numberOfPages, 1)
            let page = try XCTUnwrap(native.page(at: 1))
            let pixels = try raster(page)
            XCTAssertGreaterThan(pixels.count(where: { $0.blue > 0.8 && $0.red < 0.2 && $0.green < 0.2 }), 400)
            let red = try XCTUnwrap(pixels.bounds(where: { $0.red > 0.8 && $0.green < 0.2 && $0.blue < 0.2 }))
            XCTAssertEqual(Double(red.width) / 2 / 72 * 25.4, 20, accuracy: 0.3)
        }
    }

    func testNativeExplicitScaleAndRequestedMarginsProduceHalfSizedPhysicalMarker() throws {
        try onMain {
            _ = NSApplication.shared
            let session = try DiagramPrintSession(prepared: prepare(fixture()), title: "Explicit scale")
            session.printInfo.paperSize = CGSize(width: 300, height: 200)
            session.printInfo.scalingFactor = 0.5
            session.printInfo.leftMargin = 12
            session.printInfo.topMargin = 14
            session.printInfo.rightMargin = 12
            session.printInfo.bottomMargin = 14
            session.printInfo.dictionary()[NSPrintInfo.AttributeKey.allPages] = false
            session.printInfo.dictionary()[NSPrintInfo.AttributeKey.firstPage] = 2
            session.printInfo.dictionary()[NSPrintInfo.AttributeKey.lastPage] = 2
            let native = try savePDF(session, testName: #function)
            XCTAssertEqual(native.numberOfPages, 1)
            let page = try XCTUnwrap(native.page(at: 1))
            XCTAssertEqual(page.getBoxRect(.mediaBox).size, CGSize(width: 300, height: 200))
            let pixels = try raster(page)
            let red = try XCTUnwrap(pixels.bounds(where: { $0.red > 0.8 && $0.green < 0.2 && $0.blue < 0.2 }))
            XCTAssertEqual(Double(red.width) / 2 / 72 * 25.4, 10, accuracy: 0.3)
            XCTAssertEqual(Double(red.minX) / 2, 12 + 50 * 0.5, accuracy: 1)
            // Bitmap rows run from the top. Check top placement against the
            // requested top margin, then convert to PDF's bottom-left space.
            XCTAssertEqual(Double(red.minY) / 2, 14 + 60 * 0.5, accuracy: 1)
            let bottomInPDFPoints = page.getBoxRect(.mediaBox).height - red.maxY / 2
            XCTAssertEqual(bottomInPDFPoints, 200 - 14 - (60 + 30) * 0.5, accuracy: 1)
        }
    }

    func testNativeLandscapeCommonPaperKeepsPhysicalGeometry() throws {
        try onMain {
            _ = NSApplication.shared
            let session = try DiagramPrintSession(prepared: prepare(fixture()), title: "Landscape")
            session.printInfo.paperSize = CGSize(width: 300, height: 450)
            session.printInfo.orientation = .landscape
            XCTAssertEqual(session.printInfo.paperSize, CGSize(width: 450, height: 300))
            session.printInfo.leftMargin = 10
            session.printInfo.rightMargin = 10
            session.printInfo.topMargin = 10
            session.printInfo.bottomMargin = 10
            let native = try savePDF(session, testName: #function)
            XCTAssertEqual(native.numberOfPages, 2)
            let page = try XCTUnwrap(native.page(at: 2))
            XCTAssertEqual(page.getBoxRect(.mediaBox).size, CGSize(width: 450, height: 300))
            let red = try XCTUnwrap(raster(page).bounds(where: { $0.red > 0.8 && $0.green < 0.2 && $0.blue < 0.2 }))
            XCTAssertEqual(Double(red.width) / 2 / 72 * 25.4, 20, accuracy: 0.3)
            XCTAssertEqual(Double(red.minX) / 2, 60, accuracy: 1)
        }
    }

    func testClippingPreflightUsesSelectedRangeAndNeverAutomaticallyFits() throws {
        try onMain {
            _ = NSApplication.shared
            let session = try DiagramPrintSession(prepared: prepare(fixture()), title: "Clipping guard")
            session.printInfo.paperSize = CGSize(width: 300, height: 200)
            XCTAssertThrowsError(try session.view.validate(printInfo: session.printInfo)) {
                XCTAssertEqual($0 as? DiagramPrintingError, .pageDoesNotFit(2))
            }
            XCTAssertEqual(session.printInfo.scalingFactor, 1)
            session.printInfo.dictionary()[NSPrintInfo.AttributeKey.allPages] = false
            session.printInfo.dictionary()[NSPrintInfo.AttributeKey.firstPage] = 1
            session.printInfo.dictionary()[NSPrintInfo.AttributeKey.lastPage] = 1
            XCTAssertNoThrow(try session.view.validate(printInfo: session.printInfo))
            session.printInfo.leftMargin = 1
            XCTAssertThrowsError(try session.view.validate(printInfo: session.printInfo)) {
                XCTAssertEqual($0 as? DiagramPrintingError, .pageDoesNotFit(1))
            }
            XCTAssertNil(session.operation)
        }
    }

    func testSelectedSmallPageCannotExpandUnselectedLargePageBeyondNativeViewBudget() throws {
        try onMain {
            _ = NSApplication.shared
            var diagram = Diagram()
            diagram.page.width = 1
            diagram.page.height = 1
            diagram.page.drawingScale = DrawingScale(page: 1, drawing: 100)
            diagram.pages.append(DiagramPage(name: "Large unselected page", width: 20_000, height: 20_000))
            let session = try DiagramPrintSession(prepared: prepare(diagram), title: "Bounded native coordinates")
            session.printInfo.paperSize = CGSize(width: 595, height: 842)
            session.printInfo.scalingFactor = 1
            session.printInfo.dictionary()[NSPrintInfo.AttributeKey.allPages] = false
            session.printInfo.dictionary()[NSPrintInfo.AttributeKey.firstPage] = 1
            session.printInfo.dictionary()[NSPrintInfo.AttributeKey.lastPage] = 1
            // AppKit can canonicalize an extreme scalingFactor. Exercise the
            // explicit rendering boundary independently: a unit native scale
            // plus 10000x playback makes the selected 0.01 pt page fit A4,
            // but must not create a 200 million point unselected page.
            XCTAssertNoThrow(try session.view.validate(printInfo: session.printInfo, additionalScale: 10_000))
            let originalFrame = session.view.frame
            let originalSecond = session.view.rectForPage(2)
            XCTAssertThrowsError(try session.view.configureRenderingScale(10_000)) {
                XCTAssertEqual($0 as? DiagramPrintingError, .invalidSettings)
            }
            XCTAssertEqual(session.view.frame, originalFrame)
            XCTAssertEqual(session.view.rectForPage(2), originalSecond)
            XCTAssertNil(session.operation)
            XCTAssertNil(NSPrintOperation.current)
        }
    }

    func testOversizedNativePaperAndNonpositiveScaledRectsAreRejectedAtomically() throws {
        try onMain {
            _ = NSApplication.shared
            let session = try DiagramPrintSession(prepared: prepare(fixture()), title: "Paper and scale limits")
            session.printInfo.paperSize = CGSize(width: 20_001, height: 300)
            assertRefusedBeforeFactory(session, expected: .invalidSettings, detail: "Paper exceeds prepared-page dimension limit")
            XCTAssertNil(session.operation)
            XCTAssertNil(NSPrintOperation.current)
            let originalFrame = session.view.frame
            for scale in [CGFloat.zero, -1, .infinity, .nan] {
                XCTAssertThrowsError(try session.view.configureRenderingScale(scale)) {
                    XCTAssertEqual($0 as? DiagramPrintingError, .invalidSettings)
                }
                XCTAssertEqual(session.view.frame, originalFrame)
            }
        }
    }

    func testInvalidRangeNUpAndImplicitFitAreRefusedBeforeNativeOperationCreation() throws {
        try onMain {
            _ = NSApplication.shared
            let session = try DiagramPrintSession(prepared: prepare(fixture()), title: "Invalid settings")
            session.printInfo.dictionary()[NSPrintInfo.AttributeKey.allPages] = false
            session.printInfo.dictionary()[NSPrintInfo.AttributeKey.firstPage] = 0
            session.printInfo.dictionary()[NSPrintInfo.AttributeKey.lastPage] = 1
            XCTAssertThrowsError(try session.makeOperation()) {
                XCTAssertEqual($0 as? DiagramPrintingError, .invalidPageRange)
            }
            session.printInfo.dictionary()[NSPrintInfo.AttributeKey.allPages] = true
            session.printInfo.dictionary()[NSPrintInfo.AttributeKey.pagesAcross] = 2
            XCTAssertThrowsError(try session.makeOperation()) {
                XCTAssertEqual($0 as? DiagramPrintingError, .unsupportedSetting("Multiple pages per sheet"))
            }
            session.printInfo.dictionary()[NSPrintInfo.AttributeKey.pagesAcross] = 1
            session.printInfo.horizontalPagination = .fit
            XCTAssertThrowsError(try session.makeOperation()) {
                XCTAssertEqual($0 as? DiagramPrintingError, .invalidSettings)
            }
            XCTAssertNil(session.operation)
        }
    }

    func testUnsupportedAppKitOptionsAndMalformedNUpAreRefusedBeforeFactoryConstruction() throws {
        try onMain {
            _ = NSApplication.shared
            let prepared = try prepare(fixture())
            let cases: [(NSPrintInfo.AttributeKey, Any, String)] = [
                (.reversePageOrder, true, "Reverse page order"),
                (.selectionOnly, true, "Print selection only"),
                (.headerAndFooter, true, "Headers and footers"),
                (.horizontallyCentered, true, "Centered page placement"),
                (.verticallyCentered, true, "Centered page placement"),
                (.pagesAcross, 1.5, "Multiple pages per sheet"),
                (.pagesDown, 1.9, "Multiple pages per sheet"),
                (.pagesAcross, Double.nan, "Multiple pages per sheet")
            ]
            for (key, value, label) in cases {
                let session = try DiagramPrintSession(prepared: prepared, title: "Unsupported AppKit setting")
                session.printInfo.dictionary()[key] = value
                assertRefusedBeforeFactory(session, expected: .unsupportedSetting(label), detail: "\(key): requested \(value)")
                XCTAssertNil(session.operation)
                XCTAssertNil(NSPrintOperation.current)
            }
        }
    }

    func testNSPrintInfoCanonicalizesInvalidAttributeTypesToSupportedLayoutDefaults() throws {
        try onMain {
            _ = NSApplication.shared
            let prepared = try prepare(fixture())
            for (key, value) in [(NSPrintInfo.AttributeKey.pagesAcross, "1" as Any), (.pagesDown, NSNull())] {
                let session = try DiagramPrintSession(prepared: prepared, title: "Canonical native attributes")
                session.printInfo.dictionary()[key] = value
                // NSPrintInfo's typed dictionary canonicalizes these inputs;
                // no malformed string/null survives as an effective N-up count.
                XCTAssertNoThrow(try session.view.validate(printInfo: session.printInfo))
                if let effective = session.printInfo.dictionary()[key] {
                    let number = try XCTUnwrap(effective as? NSNumber)
                    XCTAssertEqual(number.doubleValue, 1)
                }
                XCTAssertNil(session.operation)
                XCTAssertNil(NSPrintOperation.current)
            }
        }
    }

    func testUnsupportedCorePrintingControlsAreRefusedInBothDocumentedKeySpellings() throws {
        try onMain {
            _ = NSApplication.shared
            let prepared = try prepare(fixture())
            let cases: [(String, Any, String)] = [
                ("com.apple.print.PrintSettings.PMLayoutNUp", true, "Multiple pages per sheet"),
                ("com.apple.print.PrintSettings.PMLayoutRows", 1.2, "Multiple pages per sheet"),
                ("com.apple.print.PrintSettings.PMLayoutColumns", "1", "Multiple pages per sheet"),
                ("com.apple.print.PrintSettings.PMPrintSelectionOnly", true, "Print selection only"),
                ("com.apple.print.PageToPaperMappingType", 2, "Automatic page-to-paper scaling"),
                ("com.apple.print.PageToPaperMappingAllowScalingUp", true, "Automatic page-to-paper scaling"),
                ("OutputOrder", "Reverse", "Reverse page order"),
                ("page-set", "odd", "Odd/even page filtering"),
                ("page-set", "even", "Odd/even page filtering"),
                ("mirror", "true", "Mirrored printing")
            ]
            for (key, value, label) in cases {
                let normalized = key.replacingOccurrences(of: ".", with: "_")
                let spellings = key == normalized ? [key] : [key, normalized]
                for spelling in spellings {
                    let session = try DiagramPrintSession(prepared: prepared, title: "Unsupported backend setting")
                    session.printInfo.printSettings[spelling] = value
                    assertRefusedBeforeFactory(session, expected: .unsupportedSetting(label), detail: "\(spelling): \(value)")
                    XCTAssertNil(session.operation)
                    XCTAssertNil(NSPrintOperation.current)
                }
            }
        }
    }

    func testSessionDefaultsAreIsolatedFromInheritedSettingsAndKeepBenignNativeSettings() throws {
        try onMain {
            _ = NSApplication.shared
            let prepared = try prepare(fixture())
            let inherited = NSPrintInfo.shared.copy() as! NSPrintInfo
            inherited.scalingFactor = 0.25
            inherited.leftMargin = 18
            inherited.isHorizontallyCentered = true
            inherited.dictionary()[NSPrintInfo.AttributeKey.reversePageOrder] = true
            inherited.dictionary()[NSPrintInfo.AttributeKey.selectionOnly] = true
            inherited.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = true
            inherited.dictionary()[NSPrintInfo.AttributeKey.pagesAcross] = 2
            inherited.printSettings["com_apple_print_PrintSettings_PMLayoutNUp"] = true
            inherited.printSettings["com_apple_print_PrintSettings_PMLayoutRows"] = 2
            inherited.printSettings["com_apple_print_PageToPaperMappingType"] = 2
            inherited.printSettings["com_apple_print_PageToPaperMappingAllowScalingUp"] = true
            inherited.printSettings["com.apple.print.PageToPaperMappingType"] = 2
            inherited.printSettings["OutputOrder"] = "Reverse"
            inherited.printSettings["page-set"] = "odd"
            inherited.printSettings["mirror"] = "true"
            // Documented native device/spool options are retained; this is a
            // bounded publication-policy validator, not a printer driver filter.
            inherited.printSettings["com_apple_print_PrintSettings_PMDuplexing"] = 2
            inherited.printSettings["com_apple_print_PrintSettings_PMCopyCollate"] = true
            let originalAttributes = inherited.dictionary().copy() as! NSDictionary
            let originalBackend = inherited.printSettings.copy() as! NSDictionary
            let sharedAttributes = NSPrintInfo.shared.dictionary().copy() as! NSDictionary
            let sharedBackend = NSPrintInfo.shared.printSettings.copy() as! NSDictionary
            let session = try DiagramPrintSession(prepared: prepared, title: "Independent defaults", basePrintInfo: inherited)
            XCTAssertEqual(session.printInfo.scalingFactor, 1)
            XCTAssertEqual(session.printInfo.leftMargin, 0)
            XCTAssertFalse(session.printInfo.isHorizontallyCentered)
            XCTAssertEqual((session.printInfo.printSettings["com_apple_print_PageToPaperMappingType"] as? NSNumber)?.intValue, 1)
            if let rawMapping = session.printInfo.printSettings["com.apple.print.PageToPaperMappingType"] as? NSNumber {
                XCTAssertEqual(rawMapping.intValue, 1)
            }
            XCTAssertEqual(session.printInfo.printSettings["OutputOrder"] as? String, "Normal")
            XCTAssertEqual(session.printInfo.printSettings["page-set"] as? String, "all")
            XCTAssertEqual(session.printInfo.printSettings["mirror"] as? String, "false")
            XCTAssertEqual((session.printInfo.printSettings["com_apple_print_PrintSettings_PMDuplexing"] as? NSNumber)?.intValue, 2)
            XCTAssertEqual((session.printInfo.printSettings["com_apple_print_PrintSettings_PMCopyCollate"] as? NSNumber)?.boolValue, true)
            XCTAssertNoThrow(try session.view.validate(printInfo: session.printInfo))
            XCTAssertTrue(inherited.dictionary().isEqual(originalAttributes))
            XCTAssertTrue(inherited.printSettings.isEqual(originalBackend))
            XCTAssertTrue(NSPrintInfo.shared.dictionary().isEqual(sharedAttributes))
            XCTAssertTrue(NSPrintInfo.shared.printSettings.isEqual(sharedBackend))
        }
    }

    func testOwnedPreparationCancellationAndClosedOwnerCannotDeliverPDF() throws {
        try onMain {
            _ = NSApplication.shared
            var diagram = fixture()
            diagram.pages[0].nodes += (0..<160).map { i in
                marker(x: Double(i % 10) * 25, y: Double(i / 10) * 10, width: 10, height: 5, color: "#FF0000")
            }
            let owner = LifecycleJobOwner()
            let input = LifecycleJobInput(ownerID: owner.id, snapshotID: UUID(), revision: 1)
            var handle: LifecycleJobHandle?
            var outcome: Result<OwnedPreparedPDF, Error>?
            handle = try OwnedPrintJobs.submit(snapshot: diagram, input: input, owner: owner,
                progress: { _ in handle?.cancel() }) { outcome = $0 }
            try pump(until: { outcome != nil })
            XCTAssertThrowsError(try XCTUnwrap(outcome).get()) {
                XCTAssertEqual($0 as? LifecycleJobError, .cancelled)
            }
            let closed = LifecycleJobOwner()
            let closedInput = LifecycleJobInput(ownerID: closed.id, snapshotID: UUID(), revision: 2)
            var closedOutcome: Result<OwnedPreparedPDF, Error>?
            try OwnedPrintJobs.submit(snapshot: fixture(), input: closedInput, owner: closed) { closedOutcome = $0 }
            closed.close()
            try pump(until: { closedOutcome != nil })
            XCTAssertThrowsError(try XCTUnwrap(closedOutcome).get()) {
                XCTAssertTrue([LifecycleJobError.cancelled, .staleInput].contains($0 as? LifecycleJobError ?? .queueFull))
            }
        }
    }

    func testClosedOwnerAndStickyFailurePreventNativeOutput() throws {
        try onMain {
            _ = NSApplication.shared
            let session = try DiagramPrintSession(prepared: prepare(fixture()), title: "Closed owner")
            XCTAssertThrowsError(try session.run(showsPrintPanel: false, isOwnerActive: { false })) {
                XCTAssertEqual($0 as? LifecycleJobError, .staleInput)
            }
            XCTAssertEqual(session.failure as? LifecycleJobError, .staleInput)
            XCTAssertNil(session.operation)
            XCTAssertThrowsError(try session.run(showsPrintPanel: false)) {
                XCTAssertEqual($0 as? LifecycleJobError, .staleInput)
            }
            XCTAssertNil(session.operation)
        }
    }

    func testMalformedPDFWrongPageCountAndNoForegroundAreRejected() throws {
        try onMain {
            _ = NSApplication.shared
            XCTAssertThrowsError(try PrintDocumentView(data: Data("invalid".utf8), expectedPageCount: 1)) {
                XCTAssertEqual($0 as? DiagramPrintingError, .invalidPDF)
            }
            let prepared = try prepare(fixture())
            XCTAssertThrowsError(try PrintDocumentView(data: prepared.data, expectedPageCount: 3)) {
                XCTAssertEqual($0 as? DiagramPrintingError, .invalidPDF)
            }
            var backgroundOnly = fixture()
            backgroundOnly.pages = backgroundOnly.pages.filter { $0.isBackground == true }
            backgroundOnly.activePageID = backgroundOnly.pages[0].id
            let owner = LifecycleJobOwner()
            XCTAssertThrowsError(try OwnedPrintJobs.submit(snapshot: backgroundOnly,
                input: LifecycleJobInput(ownerID: owner.id, snapshotID: UUID(), revision: 1), owner: owner) { _ in })
        }
    }

    func testNativePrintCommandPreparesCapturedForegroundPagesAndRefusesDuplicatePreparation() throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument()
            document.diagram = fixture()
            document.makeWindowControllers()
            defer { document.close() }
            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            let snapshot = document.diagram, state = document.stateID, revision = document.revision
            var runs = 0
            editor.printSessionRunner = { session in
                runs += 1
                XCTAssertEqual(session.prepared.input.snapshotID, state)
                XCTAssertEqual(session.prepared.input.revision, revision)
                XCTAssertEqual(session.prepared.pageIDs, snapshot.orderedPages.filter { $0.isBackground != true }.map(\.id))
                XCTAssertEqual(try self.document(session.prepared.data).numberOfPages, 2)
                XCTAssertEqual(session.printInfo.scalingFactor, 1)
                return true
            }
            editor.printDiagram(nil)
            XCTAssertTrue(editor.isPreparingPrint)
            XCTAssertEqual(runs, 0)
            editor.printDiagram(nil)
            try pump(until: { !editor.isPreparingPrint })
            XCTAssertEqual(runs, 1)
            XCTAssertNil(editor.lastPrintError)
            XCTAssertEqual(document.diagram, snapshot)
            XCTAssertEqual(document.revision, revision)
        }
    }

    func testNativePrintCommandRejectsRapidCommittedMutationBeforeSessionRuns() throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument()
            document.diagram = fixture()
            document.makeWindowControllers()
            defer { document.close() }
            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            var runs = 0
            editor.printSessionRunner = { _ in runs += 1; return true }
            editor.printDiagram(nil)
            XCTAssertTrue(editor.isPreparingPrint)
            document.diagram.page.nodes[0].text = "Changed before native printing"
            document.updateChangeCount(.changeDone)
            try pump(until: { !editor.isPreparingPrint })
            XCTAssertEqual(runs, 0)
            XCTAssertEqual(editor.lastPrintError as? LifecycleJobError, .staleInput)
            editor.updateStatus()
            XCTAssertTrue(editor.root.status.stringValue.contains("Printing:"))
            XCTAssertTrue(editor.root.status.stringValue.contains(LifecycleJobError.staleInput.localizedDescription))
        }
    }

    func testNativePrintCommandCancellationAndOwnerCloseNeverRunSession() throws {
        try onMain {
            _ = NSApplication.shared
            for closeOwner in [false, true] {
                let document = MacVisioDocument()
                document.diagram = fixture()
                document.makeWindowControllers()
                let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
                var runs = 0
                editor.printSessionRunner = { _ in runs += 1; return true }
                let priorOutstanding = LifecycleJobService.shared.statistics.outstanding
                editor.printDiagram(nil)
                XCTAssertTrue(editor.isPreparingPrint)
                if closeOwner { document.close() }
                else { editor.lifecycleJobs.cancelAll() }
                try pump(until: { !editor.isPreparingPrint && LifecycleJobService.shared.statistics.outstanding <= priorOutstanding })
                XCTAssertEqual(runs, 0)
                if closeOwner {
                    XCTAssertFalse(editor.lifecycleJobs.isActive)
                    XCTAssertNil(editor.printSessionRunner)
                } else {
                    XCTAssertEqual(editor.lastPrintError as? LifecycleJobError, .cancelled)
                    document.close()
                }
            }
        }
    }

    func testNativePrintFailureRemainsInStatusUntilNextExplicitPrintAttempt() throws {
        try onMain {
            _ = NSApplication.shared
            let document = MacVisioDocument()
            document.diagram = fixture()
            document.makeWindowControllers()
            defer { document.close() }
            let editor = try XCTUnwrap(document.windowControllers.first as? EditorWindowController)
            editor.printSessionRunner = { _ in throw DiagramPrintingError.pageDoesNotFit(2) }
            editor.printDiagram(nil)
            try pump(until: { !editor.isPreparingPrint })
            XCTAssertEqual(editor.lastPrintError as? DiagramPrintingError, .pageDoesNotFit(2))
            editor.updateStatus()
            XCTAssertEqual(editor.root.status.stringValue, "Printing: " + DiagramPrintingError.pageDoesNotFit(2).localizedDescription)
            editor.refresh()
            XCTAssertEqual(editor.root.status.stringValue, "Printing: " + DiagramPrintingError.pageDoesNotFit(2).localizedDescription)
            editor.printSessionRunner = { _ in true }
            editor.printDiagram(nil)
            try pump(until: { !editor.isPreparingPrint })
            XCTAssertNil(editor.lastPrintError)
        }
    }

    private func fixture() -> Diagram {
        var diagram = Diagram()
        diagram.page.name = "First foreground"
        diagram.page.width = 300
        diagram.page.height = 200
        var first = marker(x: 30, y: 40, width: 160, height: 50, color: "#FF0000")
        first.text = "Captured first"
        diagram.page.nodes = [first]
        var background = DiagramPage(name: "Referenced background", width: 4000, height: 2500)
        background.drawingScale = DrawingScale(page: 1, drawing: 10)
        background.isBackground = true
        background.nodes = [marker(x: 200, y: 1500, width: 400, height: 200, color: "#0000FF")]
        var label = DiagramNode(kind: .text, x: 2000, y: 1800, text: "Background label")
        // Fonts and default text insets are physical point sizes. Give this
        // scaled background's label a real 180 x 50 pt text frame so its 14 pt
        // text fits, rather than testing an unintentionally clipped 20 pt box.
        label.width = 1800
        label.height = 500
        background.nodes.append(label)
        var second = DiagramPage(name: "Second foreground", width: 20_000, height: 12_500)
        second.drawingScale = DrawingScale(page: 1, drawing: 50)
        second.backgroundPageID = background.id
        second.nodes = [marker(x: 50 * 50, y: 60 * 50, width: 1000 / 25.4 * 72, height: 30 * 50, color: "#FF0000")]
        var screenOnly = DiagramNode(x: 10, y: 10, text: "Screen only")
        screenOnly.layer = "Screen layer"
        var hidden = DiagramNode(x: 10, y: 10, text: "Hidden layer")
        hidden.layer = "Hidden layer"
        second.nodes += [screenOnly, hidden]
        second.layers = [DiagramLayer(name: "Screen layer", visible: true, printable: false),
                         DiagramLayer(name: "Hidden layer", visible: false, printable: true)]
        // Background is deliberately stored between the two foreground pages.
        diagram.pages += [background, second]
        return diagram
    }

    private func marker(x: Double, y: Double, width: Double, height: Double, color: String) -> DiagramNode {
        var node = DiagramNode(x: x, y: y, text: "")
        node.width = width
        node.height = height
        node.fill = color
        node.stroke = "#FFFFFF00"
        node.strokeWidth = 0
        return node
    }

    private func prepare(_ diagram: Diagram) throws -> OwnedPreparedPDF {
        let owner = LifecycleJobOwner()
        let input = LifecycleJobInput(ownerID: owner.id, snapshotID: UUID(), revision: 5)
        var outcome: Result<OwnedPreparedPDF, Error>?
        try OwnedPrintJobs.submit(snapshot: diagram, input: input, owner: owner) { outcome = $0 }
        try pump(until: { outcome != nil })
        return try XCTUnwrap(outcome).get()
    }

    private func savePDF(_ session: DiagramPrintSession, testName: String) throws -> CGPDFDocument {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("M3-native-print-\(UUID()).pdf")
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }
        session.printInfo.jobDisposition = .save
        session.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = destination
        let success = try session.run(showsPrintPanel: false)
        XCTAssertTrue(success)
        guard success else { throw DiagramError.invalid("Native save-to-PDF did not complete.") }
        XCTAssertEqual(session.operation?.printInfo.jobDisposition, .save)
        XCTAssertEqual(session.operation?.printInfo.scalingFactor, 1, "The view consumes the requested scale exactly once.")
        XCTAssertNil(NSPrintOperation.current)
        let printed = try XCTUnwrap(CGPDFDocument(destination as CFURL))
        try retainEvidenceIfRequested(session, printed: printed, destination: destination, testName: testName)
        return printed
    }

    private func assertRefusedBeforeFactory(
        _ session: DiagramPrintSession, expected: DiagramPrintingError, detail: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            let operation = try session.makeOperation()
            // Never run an unexpected operation, including with cancel
            // disposition: AppKit can present an error alert from that path.
            // Its documented current-operation property is explicitly writable.
            if NSPrintOperation.current === operation { NSPrintOperation.current = nil }
            XCTFail("Expected preflight refusal: \(detail)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? DiagramPrintingError, expected, detail, file: file, line: line)
        }
    }

    /// Normal tests retain no artifacts. An explicit absolute M3_EVIDENCE_DIR
    /// opts into four fixed test-name subdirectories, each bounded to two PDFs
    /// of at most 16 MiB plus a small manifest. The XCTest log determines whether
    /// the assertions after capture passed; capture itself is not acceptance.
    private func retainEvidenceIfRequested(
        _ session: DiagramPrintSession, printed: CGPDFDocument, destination: URL, testName: String
    ) throws {
        guard let path = ProcessInfo.processInfo.environment["M3_EVIDENCE_DIR"], !path.isEmpty else { return }
        let allowed = [
            "testNativeAllPagePDFPreservesOrderBackgroundAndTwentyMillimetreMarkerAt100Percent()",
            "testNativeRangePrintsOnlySelectedForegroundPageAtNaturalSize()",
            "testNativeExplicitScaleAndRequestedMarginsProduceHalfSizedPhysicalMarker()",
            "testNativeLandscapeCommonPaperKeepsPhysicalGeometry()"
        ]
        guard (path as NSString).isAbsolutePath, allowed.contains(testName) else {
            throw DiagramError.invalid("Print evidence requires an absolute M3_EVIDENCE_DIR and a known native print test.")
        }
        let limit = 16 * 1024 * 1024
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        guard let bytes = attributes[.size] as? NSNumber, bytes.int64Value > 0,
              bytes.int64Value <= Int64(limit), session.prepared.data.count <= limit else {
            throw DiagramError.invalid("A print evidence artifact exceeds the 16 MiB test retention limit.")
        }
        let nativeData = try Data(contentsOf: destination)
        guard nativeData.count <= limit else { throw DiagramError.invalid("Print evidence grew past its retention limit.") }
        let name = String(testName.dropLast(2))
        let directory = URL(fileURLWithPath: path, isDirectory: true)
            .appendingPathComponent("M3PrintingTests", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try session.prepared.data.write(to: directory.appendingPathComponent("prepared.pdf"), options: .atomic)
        try nativeData.write(to: directory.appendingPathComponent("native.pdf"), options: .atomic)
        let capturedPDF = try document(session.prepared.data)
        func pages(_ pdf: CGPDFDocument) throws -> [[String: Any]] {
            try (1...pdf.numberOfPages).map { number in
                let page = try XCTUnwrap(pdf.page(at: number))
                let box = page.getBoxRect(.mediaBox)
                return ["page": number, "media_box_points": [box.minX, box.minY, box.width, box.height],
                        "rotation_degrees": page.rotationAngle]
            }
        }
        func artifact(_ name: String, _ data: Data) -> [String: Any] {
            ["path": name, "byte_count": data.count,
             "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        }
        let selected = try session.view.selectedPages(printInfo: session.printInfo)
        let info = session.printInfo
        let requestedSettings: [String: Any] = [
            "paper_points": [info.paperSize.width, info.paperSize.height],
            "scaling_factor": info.scalingFactor,
            "margins_points": ["left": info.leftMargin, "right": info.rightMargin,
                               "top": info.topMargin, "bottom": info.bottomMargin]
        ]
        let preparation: [String: Any] = [
            "main_batches": session.prepared.preparation.mainBatches,
            "prepared_objects": session.prepared.preparation.preparedObjects,
            "retained_record_bytes": session.prepared.preparation.retainedRecordBytes
        ]
        let manifest: [String: Any] = [
            "schema_version": 1, "test": name,
            "scope": "Actual NSPrintOperation save-to-PDF; no physical printer",
            "assertion_result": "See corresponding XCTest log; artifacts are captured before all assertions finish",
            "qualification": "Local engineering only; no calibrated device or Visio reference acceptance",
            "artifacts": [artifact("prepared.pdf", session.prepared.data), artifact("native.pdf", nativeData)],
            "prepared_pages": try pages(capturedPDF), "native_pages": try pages(printed),
            "foreground_page_ids": session.prepared.pageIDs.map(\.uuidString),
            "selected_foreground_range": [selected.lowerBound, selected.upperBound],
            "requested_settings": requestedSettings, "preparation": preparation
        ]
        let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        guard json.count <= 64 * 1024 else { throw DiagramError.invalid("Print evidence manifest exceeds 64 KiB.") }
        try json.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private func document(_ data: Data) throws -> CGPDFDocument {
        try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: data as CFData))))
    }

    private struct Pixel {
        let red: Double
        let green: Double
        let blue: Double
    }

    private struct Raster {
        let data: Data
        let width: Int
        let height: Int

        func count(where predicate: (Pixel) -> Bool) -> Int {
            var count = 0
            for y in 0..<height { for x in 0..<width { if predicate(pixel(x, y)) { count += 1 } } }
            return count
        }

        func bounds(where predicate: (Pixel) -> Bool) -> CGRect? {
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height { for x in 0..<width where predicate(pixel(x, y)) {
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            } }
            guard maxX >= minX, maxY >= minY else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }

        private func pixel(_ x: Int, _ y: Int) -> Pixel {
            let offset = (y * width + x) * 4
            return Pixel(red: Double(data[offset]) / 255, green: Double(data[offset + 1]) / 255,
                         blue: Double(data[offset + 2]) / 255)
        }
    }

    private func raster(_ page: CGPDFPage) throws -> Raster {
        let box = page.getBoxRect(.mediaBox)
        let width = Int(box.width * 2), height = Int(box.height * 2)
        let drawing = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        drawing.setFillColor(CGColor(gray: 1, alpha: 1))
        drawing.fill(CGRect(x: 0, y: 0, width: width, height: height))
        drawing.scaleBy(x: 2, y: 2)
        drawing.drawPDFPage(page)
        return Raster(data: Data(bytes: try XCTUnwrap(drawing.data), count: width * height * 4),
                      width: width, height: height)
    }

    private func pump(until complete: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(30)
        while !complete() && Date() < deadline {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard complete() else { throw DiagramError.invalid("Print preparation timed out.") }
    }

    private func onMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}
