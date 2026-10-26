import XCTest
@testable import MacVisio

/// Dragging shapes into, between and out of containers, against Visio 2019's own behaviour on the same
/// drawing (visio-containers.vsdx, made by scripts/windows/Probe-VisioContainers.ps1 with real drags).
/// Customer report: a shape dragged onto another container did not join it, and containers would not move.
final class ContainerDropTests: XCTestCase {
    private var diagram = Diagram()
    private var page: DiagramPage { diagram.page }

    override func setUpWithError() throws {
        _ = NSApplication.shared
        let url = try XCTUnwrap(Bundle.module.url(forResource: "visio-containers", withExtension: "vsdx", subdirectory: "Fixtures/Reference"))
        let document = MacVisioDocument()
        try document.read(from: url, ofType: MacVisioDocument.visioType)
        diagram = document.diagram
    }
    private func container(_ title: String) throws -> DiagramNode {
        try XCTUnwrap(page.nodes.first { node in ContainerDrops.isContainer(node) && page.nodes.contains { $0.parentID == node.id && $0.text == title } })
    }
    private var box: DiagramNode { page.nodes.first { $0.text == "Box" }! }
    /// Drags the box so its centre is at (x, y) in Visio's page inches, as a canvas move commits it.
    private func drag(toInches x: Double, _ y: Double) {
        let i = page.nodes.firstIndex { $0.text == "Box" }!
        diagram.pages[diagram.pages.firstIndex { $0.id == page.id }!].nodes[i].x = x * 72 - box.width / 2
        diagram.pages[diagram.pages.firstIndex { $0.id == page.id }!].nodes[i].y = page.height - y * 72 - box.height / 2
        diagram = ContainerDrops.apply(to: diagram, pageID: page.id, dragged: [box.id], moving: [box.id])
    }
    private func containers(of id: UUID) throws -> Set<String> {
        let index = try DiagramMemberships.index(in: diagram, pageID: page.id)
        return Set(try index.containers.filter { index.contains(member: id, container: $0.id) }.map { entry in
            try XCTUnwrap(page.nodes.first { $0.parentID == entry.id && !$0.text.isEmpty }).text
        })
    }

    func testDraggedShapeJoinsTheContainerItLandsInAndLeavesItsOldOne() throws {
        XCTAssertEqual(try containers(of: box.id), ["Outer"])
        drag(toInches: 9.25, 4.5)
        XCTAssertEqual(try containers(of: box.id), ["Other"])
        drag(toInches: 5.0, 5.0)
        XCTAssertEqual(try containers(of: box.id), ["Outer"])
    }

    func testOverlappingContainersThatDoNotHoldEachOtherBothTakeTheShape() throws {
        // Inner sits inside Outer without being its member; Visio adds the box to both.
        drag(toInches: 3.0, 4.0)
        XCTAssertEqual(try containers(of: box.id), ["Inner", "Outer"])
    }

    func testCentreOutsideLeavesEvenWhileOverlapping() throws {
        drag(toInches: 9.25, 4.5)
        let other = try container("Other")
        drag(toInches: other.rect.maxX / 72 + 0.1, 4.5)
        XCTAssertTrue(box.rect.intersects(try container("Other").rect))
        XCTAssertEqual(try containers(of: box.id), [])
        drag(toInches: 13.4, 4.5)
        XCTAssertEqual(try containers(of: box.id), [])
    }

    func testContainerExpandsToKeepItsMemberInsideItsMarginAndBelowItsHeading() throws {
        drag(toInches: 9.25, 4.5)
        let before = try container("Other")
        drag(toInches: before.rect.maxX / 72 - 0.1, 4.5)
        let other = try container("Other")
        // Visio: the right edge moves to the box's edge plus the 3 mm margin; the left edge stays.
        XCTAssertEqual(other.rect.maxX, box.rect.maxX + 3 / 25.4 * 72, accuracy: 1e-6)
        XCTAssertEqual(other.rect.minX, before.rect.minX, accuracy: 1e-6)
        let heading = try XCTUnwrap(page.nodes.first { $0.parentID == other.id && $0.text == "Other" })
        XCTAssertEqual(heading.rect.maxX, other.rect.maxX, accuracy: 1e-6, "The heading spans the grown container")
        // Into Inner near its top: Visio grew Inner from 5 in to 5.2176 in for a box whose top was at 4.75 in.
        drag(toInches: 3.0, 4.5)
        XCTAssertEqual((page.height - (try container("Inner")).rect.minY) / 72, 5.2176, accuracy: 0.01)
    }

    func testContainersWithMembersMoveAndResize() throws {
        let outer = try container("Outer")
        XCTAssertNil(DiagramMemberships.transformBlockReason(outer, in: page))
        XCTAssertNil(NativeEditProtection.blockReason(for: "X", node: outer, in: page))
        XCTAssertNil(NativeEditProtection.blockReason(for: "Width", node: outer, in: page))
    }

    func testDeletedMemberPlaceholdersAreNotRelationships() throws {
        let formula = try DiagramMemberships.parse(ShapeSheetCell(value: "0", formula: "SUM(DEPENDSON(1,REF(),Sheet.7!SheetRef(),REF()),DEPENDSON(4,REF()))"))
        XCTAssertEqual(formula.targets(.containerMembers), [7])
        XCTAssertEqual(formula.targets(.containers), [])
        XCTAssertEqual(formula.replacing(.containerMembers, with: [7, 9]), "SUM(DEPENDSON(1,Sheet.7!SheetRef(),Sheet.9!SheetRef()),DEPENDSON(4,REF()))")
    }
}
