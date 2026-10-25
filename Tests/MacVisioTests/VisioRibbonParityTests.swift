import XCTest
@testable import MacVisio

/// The ribbon's tabs, groups and commands must match Microsoft Visio 2019's, by name and order, as captured
/// from Visio's own UI Automation tree (Fixtures/Reference/visio-2019-ribbon.json,
/// scripts/windows/Capture-VisioUI.ps1). A split button's primary command (New Page's Blank Page) counts once.
final class VisioRibbonParityTests: XCTestCase {
    private struct Reference: Decodable {
        struct Item: Decodable { let name: String; let kind: String }
        struct Group: Decodable { let name: String; let items: [Item] }
        struct Tab: Decodable { let name: String; let groups: [Group] }
        let tabs: [String]; let tellMe: String; let ribbon: [Tab]
    }
    private func reference() throws -> Reference {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "visio-2019-ribbon", withExtension: "json", subdirectory: "Fixtures/Reference"))
        return try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
    }

    func testTabsMatchVisio() throws {
        XCTAssertEqual(RibbonDefinition.tabs, try reference().tabs)
    }

    func testGroupsAndCommandsMatchVisioByNameAndOrder() throws {
        let reference = try reference()
        XCTAssertEqual(RibbonDefinition.ribbon.map(\.name), reference.ribbon.map(\.name))
        for tab in reference.ribbon {
            let mine = try XCTUnwrap(RibbonDefinition.ribbon.first { $0.name == tab.name })
            XCTAssertEqual(mine.groups.map(\.name), tab.groups.map(\.name), tab.name)
            for group in tab.groups {
                guard let ours = mine.groups.first(where: { $0.name == group.name }) else { continue }
                let names = ours.commands.flatMap { [$0.name] + $0.aliases }
                XCTAssertEqual(names, group.items.map(\.name), "\(tab.name) > \(group.name)")
            }
        }
    }

    func testEveryAvailableCommandResolvesToAnAction() throws {
        _ = NSApplication.shared
        for tab in RibbonDefinition.ribbon { for group in tab.groups { for command in group.commands {
            if let action = command.action {
                let target: AnyClass = command.target == .ribbon ? VisioRibbonView.self : (action == #selector(NSApplication.showHelp(_:)) ? NSApplication.self : EditorWindowController.self)
                XCTAssertTrue(target.instancesRespond(to: action), "\(tab.name) > \(group.name) > \(command.name)")
            }
            for (title, action) in command.menu { if let action {
                let responds = [VisioRibbonView.self, EditorWindowController.self].contains { ($0 as AnyClass).instancesRespond(to: action) }
                XCTAssertTrue(responds, "\(command.name) > \(title)")
            } }
        } } }
    }

    /// Records how much of Visio's ribbon MacVisio supports, so progress is measured rather than claimed.
    func testReportSupportedCommandCoverage() throws {
        let commands = RibbonDefinition.ribbon.flatMap { $0.groups.flatMap(\.commands) }
        let supported = commands.filter(\.available).count
        print("Ribbon coverage: \(supported) of \(commands.count) Visio 2019 ribbon commands available")
        XCTAssertGreaterThan(supported, 0)
    }
}
