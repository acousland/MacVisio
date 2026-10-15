import XCTest
@testable import MacVisio

final class ShapeDrawingOrderTests: XCTestCase {
    func testDisplayModesAndMissingModeChooseGroupLayer() {
        let behind = item("group", group: true, mode: 1)
        let behindChild = item("child", parent: behind.id)
        XCTAssertEqual(order([behind, behindChild]), ["group", "child"])

        let front = item("group", group: true, mode: 2)
        let frontChild = item("child", parent: front.id)
        XCTAssertEqual(order([front, frontChild]), ["child", "group"])

        let absentMode = item("group", group: true)
        let absentModeChild = item("child", parent: absentMode.id)
        XCTAssertEqual(order([absentMode, absentModeChild]), ["child", "group"])

        let hidden = item("group", group: true, mode: 0)
        let hiddenChild = item("child", parent: hidden.id)
        XCTAssertEqual(order([hidden, hiddenChild]), ["child"])
    }

    func testNestedGroupsKeepDescendantsTogetherAndPreserveSiblingOrder() {
        let behind = item("behind", group: true, mode: 1)
        let behindChild = item("behind-child", parent: behind.id)
        let unrelatedRoot = item("unrelated")
        let front = item("front", group: true, mode: 2)
        let nestedBehind = item("nested-behind", parent: front.id, group: true, mode: 1)
        let nestedChild = item("nested-child", parent: nestedBehind.id)
        let nestedHidden = item("nested-hidden", parent: front.id, group: true, mode: 0)
        let hiddenChild = item("hidden-child", parent: nestedHidden.id)
        let finalChild = item("final-child", parent: front.id)

        XCTAssertEqual(
            order([behind, behindChild, unrelatedRoot, front, nestedBehind, nestedChild, nestedHidden, hiddenChild, finalChild]),
            ["behind", "behind-child", "unrelated", "nested-behind", "nested-child", "hidden-child", "final-child", "front"]
        )
    }

    func testOrphansAndParentCyclesAreEmittedOnceInStableOrder() {
        let orphan = item("orphan", parent: UUID())
        let root = item("root")
        let first = item("cycle-a", group: true)
        let second = item("cycle-b", parent: first.id, group: true)
        let cycleLeaf = item("cycle-leaf", parent: first.id)
        let cycleA = Item(id: first.id, name: first.name, parentID: second.id, isGroup: true, displayMode: first.displayMode)

        let result = order([orphan, root, cycleA, second, cycleLeaf])
        XCTAssertEqual(result, ["orphan", "root", "cycle-b", "cycle-leaf", "cycle-a"])
        XCTAssertEqual(result.count, Set(result).count)
    }

    private struct Item {
        var id = UUID()
        var name: String
        var parentID: UUID? = nil
        var isGroup = false
        var displayMode: Int? = nil
    }

    private func item(_ name: String, parent: UUID? = nil, group: Bool = false, mode: Int? = nil) -> Item {
        Item(name: name, parentID: parent, isGroup: group, displayMode: mode)
    }

    private func order(_ items: [Item]) -> [String] {
        ShapeDrawingOrder.ordered(
            items,
            id: \.id,
            parentID: \.parentID,
            isGroup: \.isGroup,
            displayMode: \.displayMode
        ).map(\.name)
    }
}
