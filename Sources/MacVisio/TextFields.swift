import MacVisioInfrastructure
import Foundation

struct ShapeTextField:Codable,Equatable {
    var index:Int
    var cells:[String:ShapeSheetCell]
    var cached:String?
    var valid:Bool { index >= 0 && index <= UInt32.max && cells.count <= 256 && cells.values.allSatisfy{$0.formula.utf8.count <= 16384} && (cached?.utf8.count ?? 0) <= 1_000_000 }
}
enum FieldFormatting {
    static func date(_ text:String) -> Date? {
        if let value = ISO8601DateFormatter().date(from:text) { return value }
        let formatter = DateFormatter();formatter.locale = Locale(identifier:"en_US_POSIX");formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss","yyyy-MM-dd","M/d/yyyy"] { formatter.dateFormat = format;if let result = formatter.date(from:text) { return result } };return nil
    }
    static func format(_ value:SheetValue,picture:String,unit:String = "",type:Int = 0) throws -> String {
        guard picture.utf8.count <= 16384 else { throw DiagramError.invalid("Field format is too long.") }
        var typed = value
        // Date-typed fields (Type 5) read a number or date text as a date.
        if type == 5 { if case .string(let text) = value,let date = self.date(text) { typed = .date(date) } else if let serial = try? value.numeric(),case .number = value { typed = .date(SheetValue.date(serial:serial)) } }
        return try VisioPictureFormat.format(typed,picture:picture,unit:unit)
    }
}

enum TextFieldEngine {
    struct Calculation { var diagram:Diagram;var issues:[String]; var issuesByPage:[UUID:[String]] = [:]; var work = CalculationWork(); var changedNodeIDsByPage:[UUID:Set<UUID>] = [:]; var changedEdgeIDsByPage:[UUID:Set<UUID>] = [:]; var cancelled = false; var diagnosticsByPage: [UUID: [DocumentDiagnostic]] = [:] }
    static func inserting(formula:String,picture:String = "",type:Int = 0,into input:DiagramNode,range requested:NSRange? = nil) throws -> DiagramNode {
        var node = input,fields = node.formatting.textFields ?? [],runs = ShapeRichText.runs(for:node)
        guard fields.count < 1000 else { throw DiagramError.invalid("Too many text fields.") }
        var allocator = try VisioIDAllocator(reserved:fields.map{String($0.index)})
        let index = Int(try allocator.allocate())!,length = node.text.utf16.count
        var range = requested ?? NSRange(location:length,length:0)
        guard range.location >= 0,range.length >= 0,range.location <= length,range.length <= length-range.location else { throw DiagramError.invalid("Invalid field insertion position.") }
        var position = 0
        for run in runs { let span = NSRange(location:position,length:run.text.utf16.count)
            if run.fieldIndex != nil,(NSIntersectionRange(span,range).length > 0 || range.length == 0 && range.location > span.location && range.location < NSMaxRange(span)) { range = NSUnionRange(range,span) };position += span.length
        }
        var prefix:[ShapeTextRun] = [],suffix:[ShapeTextRun] = [],style = runs.last ?? ShapeTextRun(text:"",character:ShapeCharacterStyle(node:node),paragraph:ShapeParagraphStyle(alignment:node.formatting.alignment));position = 0
        for run in runs {
            let end = position+run.text.utf16.count
            if position <= range.location,range.location < end { style = run }
            if position < range.location { var part = run;part.text = (run.text as NSString).substring(to:min(run.text.utf16.count,range.location-position));prefix.append(part) }
            if end > NSMaxRange(range) { var part = run;part.text = (run.text as NSString).substring(from:max(0,NSMaxRange(range)-position));suffix.append(part) };position = end
        }
        fields.append(ShapeTextField(index:index,cells:["Value":ShapeSheetCell(value:"",formula:formula),"Format":ShapeSheetCell(value:picture,unit:"STR"),"Type":ShapeSheetCell(value:String(type))],cached:""))
        style.text = "";style.fieldIndex = index;style.fieldToken = UUID()
        let output = prefix+[style]+suffix;node.text = output.map(\.text).joined();node.formatting.textRuns = output;node.formatting.textFields = fields;return node
    }
    static func recalculate(_ input:Diagram,now:Date = Date(),foreground:DiagramPage? = nil,previous:Diagram? = nil,retainedIssuesByPage:[UUID:[String]] = [:],retainedDiagnosticsByPage:[UUID:[DocumentDiagnostic]] = [:],session:CalculationSession? = nil,changes:DocumentChangeSet? = nil,cancellation:LifecycleJobCancellation? = nil) -> Calculation {
        var result = input,issues = Set<String>(),issuesByPage:[UUID:[String]] = [:]
        var work = CalculationWork()
        var diagnosticsByPage: [UUID: [DocumentDiagnostic]] = [:]
        var changedNodeIDsByPage:[UUID:Set<UUID>] = [:]
        var changedEdgeIDsByPage:[UUID:Set<UUID>] = [:]
        let session = session ?? CalculationSession()
        let oldPages = previous.map { Dictionary(uniqueKeysWithValues: $0.pages.map { ($0.id, $0) }) } ?? [:]
        func documentContext(_ diagram: Diagram) -> [DiagramPage] {
            diagram.pages.map { page in var page = page; page.nodes = []; page.edges = []; return page }
        }
        let changedContext = changes.map { $0.sourceResourcesChanged || $0.documentPropertiesChanged || $0.documentStructureChanged || $0.pages.values.contains { $0.pagePropertiesChanged } }
        let contextUnchanged = foreground == nil && (changedContext.map { !$0 } ?? (previous.map { $0.visioArchive == input.visioArchive && $0.definitions == input.definitions && documentContext($0) == documentContext(input) } == true))
        for p in result.pages.indices {
            if cancellation?.isCancelled == true { return Calculation(diagram:input,issues:[],work:work,cancelled:true) }
            let page = result.pages[p],context = foreground ?? page
            let indexedBefore = session.indexedNodes, comparedBefore = session.comparedSources
            let indexedConnectorsBefore = session.indexedConnectors
            let binding = input.visioArchive?.pages.first { $0.pageID == page.id }
            let pageChanges = changes?.pages[page.id]
            let trusted = previous != nil && changes != nil && changes?.sourceResourcesChanged == false && changes?.insertedPageIDs.contains(page.id) == false
            let dependency = session.index(for: page, binding: binding, fieldIdentifiers: true, changes: pageChanges, trustChanges: trusted)
            work.dependencyNodesIndexed += session.indexedNodes - indexedBefore
            work.dependencySourcesCompared += session.comparedSources - comparedBefore
            work.dependencyConnectorsIndexed += session.indexedConnectors - indexedConnectorsBefore
            guard !dependency.fieldNodeIDs.isEmpty || !dependency.fieldConnectorIDs.isEmpty else { issuesByPage[page.id] = []; continue }
            if contextUnchanged, (trusted ? pageChanges == nil : oldPages[page.id] == page), dependency.volatileNodes.isEmpty {
                let retained = retainedIssuesByPage[page.id, default: []]
                issuesByPage[page.id] = retained; diagnosticsByPage[page.id] = retainedDiagnosticsByPage[page.id] ?? []; issues.formUnion(retained); continue
            }
            var affected: Set<UUID>?
            if contextUnchanged, let oldPage = oldPages[page.id],
               !dependency.requiresFullPage, retainedIssuesByPage[page.id, default: []].isEmpty {
                if trusted, let pageChanges, !pageChanges.pagePropertiesChanged, !pageChanges.hierarchyChanged,
                   !pageChanges.nodeOrderChanged, !pageChanges.edgeOrderChanged,
                   pageChanges.insertedNodeIDs.isEmpty, pageChanges.deletedNodeIDs.isEmpty,
                   pageChanges.insertedEdgeIDs.isEmpty, pageChanges.deletedEdgeIDs.isEmpty {
                    affected = dependency.affected(by: pageChanges.changedNodeIDs.union(pageChanges.changedEdgeIDs))
                } else {
                    work.inputComparisonNodes += page.nodes.count + oldPage.nodes.count
                    work.inputComparisonConnectors += page.edges.count + oldPage.edges.count
                    if let changed = CalculationInvalidation.changedNodes(in: page, comparedTo: oldPage) { affected = dependency.affected(by: changed) }
                }
            }
            let fieldIDs = dependency.fieldNodeIDs.union(dependency.fieldConnectorIDs)
            let selected = affected.map { fieldIDs.intersection($0) } ?? fieldIDs
            let candidates = selected.compactMap { dependency.sourceIndices[$0] }.sorted().map { dependency.sources[$0] }
            guard !candidates.isEmpty else { issuesByPage[page.id] = []; continue }
            work.fieldPages += 1
            var pageIssues = Set<String>()
            var pageDiagnostics: [DocumentDiagnostic] = []
            let preparedBefore = session.preparedHostNodes, connectorsBefore = session.preparedHostConnectors
            let nodes = session.nodes(for: page, changes: pageChanges, trustChanges: trusted)
            work.hostNodesPrepared += session.preparedHostNodes - preparedBefore
            work.hostConnectorsPrepared += session.preparedHostConnectors - connectorsBefore
            let shared = ShapeSheetContext(page: page, binding: binding,
                colorPalette: ShapeSheetColorPalette(documentArchive: input.visioArchive),
                nodesByID: nodes, identifiers: dependency.identifiers, cancellation: cancellation,
                document: input, foreground: foreground, now: now, mode: .typedFields,
                publicIDsByObject: dependency.publicIDsByObject)
            for candidate in candidates {
                if cancellation?.isCancelled == true { return Calculation(diagram:input,issues:[],work:work,cancelled:true) }
                let i = candidate.objectIndex
                var node = candidate.kind == .node ? page.nodes[i] : nodes[candidate.id]!
                guard var fields = node.formatting.textFields,!fields.isEmpty,let originalRuns = node.formatting.textRuns else { continue }
                if candidate.kind == .node { work.fieldNodes += 1 } else { work.fieldConnectors += 1 }
                var displays:[Int:String] = [:]
                for j in fields.indices {
                    let field = fields[j]
                    var failingCell: String? = "Fields.Value[\(field.index + 1)]"
                    do {
                        guard let valueCell = field.cells["Value"] else { throw DiagramError.invalid("Unresolved field definition; cached display is retained.") }
                        let value = try shared.evaluate(valueCell,on:node.id,hostCell:"Fields.Value[\(field.index+1)]")
                        let formatCell = field.cells["Format"] ?? ShapeSheetCell(value:"",unit:"STR")
                        failingCell = "Fields.Format[\(field.index + 1)]"
                        var picture = try shared.evaluate(formatCell,on:node.id,hostCell:"Fields.Format[\(field.index+1)]").text
                        // Only an explicit empty formula hides a field; an unset format shows the general value.
                        if picture.isEmpty,formatCell.formula.isEmpty { picture = "esc(0)" }
                        failingCell = nil
                        let display = try FieldFormatting.format(value,picture:picture,unit:valueCell.unit,type:Int(field.cells["Type"]?.value ?? "0") ?? 0)
                        fields[j].cells["Value"]?.value = value.text;fields[j].cached = display;displays[field.index] = display
                    } catch {
                        pageIssues.insert("Text field \(field.index+1): \(error.localizedDescription)")
                        let message = "Text field \(field.index+1): \(error.localizedDescription)"
                        if candidate.kind == .node {
                            pageDiagnostics.append(.calculationFailure(message, code: "calculation.field.cell",
                                page: page.id, shape: node.id, binding: binding, sourceShapeID: node.formatting.sourceShapeID,
                                cell: failingCell, feature: "text-field"))
                        } else {
                            pageDiagnostics.append(.connectorCalculationFailure(message, code: "calculation.field.cell",
                                page: page.id, connector: node.id, binding: binding, sourceShapeID: node.formatting.sourceShapeID,
                                cell: failingCell, feature: "text-field"))
                        }
                    }
                }
                let runs = originalRuns.map { run in var run = run;if let index = run.fieldIndex,let display = displays[index] { run.text = display };return run }
                node.text = runs.map(\.text).joined();node.formatting.textRuns = runs;node.formatting.textFields = fields
                if candidate.kind == .node {
                    if node != page.nodes[i] { changedNodeIDsByPage[page.id, default: []].insert(node.id) }
                    result.pages[p].nodes[i] = node
                } else {
                    var edge = page.edges[i]
                    edge.label = node.text; edge.details = node.details
                    if edge != page.edges[i] { changedEdgeIDsByPage[page.id, default: []].insert(edge.id) }
                    result.pages[p].edges[i] = edge
                }
            }
            pageDiagnostics.append(contentsOf: shared.definitionDiagnostics)
            work.add(shared.work)
            issuesByPage[page.id] = pageIssues.sorted()
            diagnosticsByPage[page.id] = pageDiagnostics
            issues.formUnion(pageIssues)
        }
        if cancellation?.isCancelled == true { return Calculation(diagram:input,issues:[],work:work,cancelled:true) }
        return Calculation(diagram:result,issues:issues.sorted(),issuesByPage:issuesByPage,work:work,changedNodeIDsByPage:changedNodeIDsByPage,changedEdgeIDsByPage:changedEdgeIDsByPage,diagnosticsByPage:diagnosticsByPage)
    }
    static func patch(_ fields:[ShapeTextField],element:XMLElement,previous:[ShapeTextField] = []) {
        let section = VisioXML.section(element,"Field")
        for field in fields {
            let row = section.elementsLocal("Row").first{$0.attr("IX") == String(field.index)} ?? XMLElement(name:"Row")
            if row.parent == nil { row.setAttr("IX",String(field.index));section.addChild(row) };row.setAttr("Del",nil)
            let old = previous.first{$0.index == field.index}
            for (key,cell) in field.cells where old?.cells[key] != cell {
                let value = VisioXML.set(row,key,cell.value,formula:cell.formula.isEmpty ? nil : cell.formula);value.setAttr("U",cell.unit.isEmpty ? nil : cell.unit)
            }
        }
        for removed in previous where !fields.contains(where:{$0.index == removed.index}) {
            for row in section.elementsLocal("Row") where row.attr("IX") == String(removed.index) { row.detach() }
            if element.attr("Master") != nil || element.attr("MasterShape") != nil { let row = XMLElement(name:"Row");row.setAttr("IX",String(removed.index));row.setAttr("Del","1");section.addChild(row) }
        }
        if section.childCount == 0 { section.detach() }
    }
}
