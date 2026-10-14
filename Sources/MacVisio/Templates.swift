import Foundation

enum DiagramTemplate: String, CaseIterable {
    case blank, flowchart, organization, network, swimlane

    var title: String {
        switch self {
        case .blank: return "Blank diagram"
        case .flowchart: return "Basic flowchart"
        case .organization: return "Organization chart"
        case .network: return "Network diagram"
        case .swimlane: return "Cross-functional flowchart"
        }
    }

    var subtitle: String {
        switch self {
        case .blank: return "Start with an empty landscape page."
        case .flowchart: return "Map a process, decision, and approval loop."
        case .organization: return "Show teams and reporting relationships."
        case .network: return "Connect users, services, and infrastructure."
        case .swimlane: return "Follow a process across responsible teams."
        }
    }

    var symbol: String {
        switch self {
        case .blank: return "doc"
        case .flowchart: return "arrow.triangle.branch"
        case .organization: return "person.3"
        case .network: return "network"
        case .swimlane: return "rectangle.split.3x1"
        }
    }

    func makeDiagram() -> Diagram {
        var diagram = Diagram()
        switch self {
        case .blank:
            diagram.title = "Untitled Diagram"
        case .flowchart:
            diagram.title = "Purchase approval"
            diagram.page.name = "Approval process"
            let start = Self.node(.roundedRectangle, 480, 40, "Purchase request", height: 60, palette: .green)
            let request = Self.node(.document, 480, 150, "Prepare request\nand estimate", height: 70)
            let review = Self.node(.rectangle, 480, 260, "Manager review", height: 70)
            let decision = Self.node(.diamond, 485, 375, "Approved?", palette: .amber)
            let revise = Self.node(.rectangle, 790, 390, "Revise request", width: 190, height: 80, palette: .rose)
            let order = Self.node(.document, 480, 535, "Issue purchase order", height: 70)
            let send = Self.node(.rectangle, 480, 645, "Send to supplier", height: 70)
            let finish = Self.node(.roundedRectangle, 480, 760, "Order confirmed", height: 50, palette: .green)
            diagram.page.nodes = [start, request, review, decision, revise, order, send, finish]
            diagram.page.edges = [
                Self.edge(start, request), Self.edge(request, review), Self.edge(review, decision),
                Self.edge(decision, order, "Yes", color: "#41876A"),
                Self.edge(decision, revise, "No", color: "#BE6977"),
                Self.edge(revise, request, "Resubmit", color: "#BE6977"),
                Self.edge(order, send), Self.edge(send, finish)
            ]
        case .organization:
            diagram.title = "Team organization"
            diagram.page.name = "Organization"
            let ceo = Self.node(.roundedRectangle, 470, 70, "Chief Executive", width: 180, height: 80, palette: .navy)
            let technology = Self.node(.roundedRectangle, 130, 280, "Technology", width: 180, height: 80)
            let finance = Self.node(.roundedRectangle, 470, 280, "Finance", width: 180, height: 80, palette: .green)
            let operations = Self.node(.roundedRectangle, 810, 280, "Operations", width: 180, height: 80, palette: .purple)
            let engineering = Self.node(.rectangle, 50, 540, "Engineering", width: 150, height: 80)
            let design = Self.node(.rectangle, 240, 540, "Design", width: 150, height: 80)
            let accounting = Self.node(.rectangle, 485, 540, "Accounting", width: 150, height: 80, palette: .green)
            let delivery = Self.node(.rectangle, 730, 540, "Delivery", width: 150, height: 80, palette: .purple)
            let support = Self.node(.rectangle, 920, 540, "Customer support", width: 150, height: 80, palette: .purple)
            diagram.page.nodes = [ceo, technology, finance, operations, engineering, design, accounting, delivery, support]
            diagram.page.edges = [
                Self.edge(ceo, technology, arrow: false), Self.edge(ceo, finance, arrow: false), Self.edge(ceo, operations, arrow: false),
                Self.edge(technology, engineering, arrow: false), Self.edge(technology, design, arrow: false),
                Self.edge(finance, accounting, arrow: false), Self.edge(operations, delivery, arrow: false), Self.edge(operations, support, arrow: false)
            ]
        case .network:
            diagram.title = "Office network"
            diagram.page.name = "Infrastructure"
            let internet = Self.node(.cloud, 470, 50, "Internet", width: 180, height: 100, palette: .purple)
            let firewall = Self.node(.hexagon, 480, 230, "Firewall", palette: .amber)
            let networkSwitch = Self.node(.roundedRectangle, 480, 390, "Network switch", palette: .navy)
            let users = Self.node(.rectangle, 100, 390, "Office workstations", width: 190)
            let wireless = Self.node(.rectangle, 830, 390, "Wireless access", width: 190)
            let service = Self.node(.cylinder, 480, 570, "Application\nserver", width: 160, height: 120)
            let database = Self.node(.cylinder, 810, 590, "Database", width: 160, height: 120, palette: .green)
            let backup = Self.node(.cylinder, 150, 590, "Backup storage", width: 160, height: 120, palette: .green)
            diagram.page.nodes = [internet, firewall, networkSwitch, users, wireless, service, database, backup]
            diagram.page.edges = [
                Self.edge(internet, firewall, "WAN", arrow: false), Self.edge(firewall, networkSwitch, "LAN", arrow: false),
                Self.edge(networkSwitch, users, arrow: false), Self.edge(networkSwitch, wireless, arrow: false),
                Self.edge(networkSwitch, service, arrow: false), Self.edge(service, database, arrow: false), Self.edge(service, backup, arrow: false)
            ]
        case .swimlane:
            diagram.title = "Expense reimbursement"
            diagram.page.name = "Responsibilities"
            let requester = Self.lane(80, 100, "Requester", palette: .blue)
            let operations = Self.lane(80, 320, "Operations", palette: .purple)
            let finance = Self.lane(80, 540, "Finance", palette: .green)
            let submit = Self.node(.roundedRectangle, 240, 155, "Submit expense", width: 170, height: 70)
            let check = Self.node(.rectangle, 455, 375, "Check receipts", width: 170, height: 70, palette: .purple)
            let approve = Self.node(.diamond, 700, 355, "Approved?", width: 150, height: 110, palette: .amber)
            let revise = Self.node(.rectangle, 690, 155, "Update submission", width: 170, height: 70, palette: .rose)
            let pay = Self.node(.rectangle, 690, 595, "Pay reimbursement", width: 170, height: 70, palette: .green)
            let finish = Self.node(.roundedRectangle, 240, 595, "Expense closed", width: 170, height: 70, palette: .green)
            diagram.page.nodes = [requester, operations, finance, submit, check, approve, revise, pay, finish]
            diagram.page.edges = [
                Self.edge(submit, check), Self.edge(check, approve),
                Self.edge(approve, revise, "No", color: "#BE6977"), Self.edge(revise, submit, "Resubmit", color: "#BE6977"),
                Self.edge(approve, pay, "Yes", color: "#41876A"), Self.edge(pay, finish)
            ]
        }
        return diagram
    }

    private enum Palette {
        case blue, green, amber, rose, purple, navy
        var colors: (fill: String, stroke: String, text: String) {
            switch self {
            case .blue: return ("#E8F0FE", "#4375BC", "#20334F")
            case .green: return ("#E6F4EC", "#41876A", "#234D3C")
            case .amber: return ("#FFF3D9", "#B28A35", "#68501D")
            case .rose: return ("#FCEBED", "#BE6977", "#743744")
            case .purple: return ("#F0EBFA", "#8A70AD", "#50406C")
            case .navy: return ("#315A89", "#274B73", "#FFFFFF")
            }
        }
    }

    private static func node(_ kind: ShapeKind, _ x: Double, _ y: Double, _ text: String,
                             width: Double? = nil, height: Double? = nil, palette: Palette = .blue) -> DiagramNode {
        var node = DiagramNode(kind: kind, x: x, y: y, text: text)
        if let width { node.width = width }
        if let height { node.height = height }
        node.fill = palette.colors.fill
        node.stroke = palette.colors.stroke
        node.textColor = palette.colors.text
        node.fontSize = 14
        node.bold = kind == .roundedRectangle || kind == .diamond
        return node
    }

    private static func lane(_ x: Double, _ y: Double, _ title: String, palette: Palette) -> DiagramNode {
        var lane = node(.swimlane, x, y, title, width: 960, height: 190, palette: palette)
        lane.fill = "#F7F9FC"
        lane.strokeWidth = 1
        lane.bold = true
        lane.locked = true
        lane.layer = "Lanes"
        return lane
    }

    private static func edge(_ source: DiagramNode, _ target: DiagramNode, _ label: String = "",
                             color: String = "#697D99", arrow: Bool = true) -> DiagramEdge {
        DiagramEdge(source: source.id, target: target.id, label: label, color: color, arrow: arrow)
    }
}
