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
        let text = picture.trimmingCharacters(in:.whitespacesAndNewlines)
        let code:Int? = text.hasPrefix("esc(") && text.hasSuffix(")") ? Int(text.dropFirst(4).dropLast()) : text.hasPrefix("{<") && text.hasSuffix(">}") ? Int(text.dropFirst(2).dropLast(2)) : nil
        if let code,[37,38,39].contains(code) { return code == 38 ? value.text.lowercased() : code == 39 ? value.text.uppercased() : value.text }
        if type == 5 || {if case .date = value { return true };return false}() {
            let date:Date
            if case .date(let d) = value { date = d }
            else if let d = self.date(value.text) { date = d }
            else { date = Date(timeIntervalSince1970:(try value.numeric()-25569)*86400) }
            guard (-62135596800...253402300799).contains(date.timeIntervalSince1970) else { throw DiagramError.invalid("Date outside supported range.") }
            let formats:[Int:String] = [20:"M/d/yyyy",21:"EEEE, MMMM d, yyyy",22:"M/d/yy",23:"MM/dd/yy",24:"MMM d, yyyy",25:"MMMM d, yyyy",26:"d/M/yy",27:"dd/MM/yy",28:"d MMM yyyy",29:"d MMMM yyyy",44:"yyyy-MM-dd",45:"yy-MM-dd",64:"yyyy-M-d",65:"yy-MM-dd",200:"M/d/yyyy",201:"EEEE, MMMM d, yyyy",202:"MMMM d, yyyy",204:"yyyy-MM-dd",209:"MMMM yyyy",210:"MMM yy",215:"HH:mm",216:"HH:mm:ss",31:"H:mm",32:"HH:mm",33:"H:mm",34:"HH:mm",35:"h:mm a",36:"hh:mm a"]
            let pattern = code.flatMap{formats[$0]} ?? text
            guard !pattern.isEmpty,code == nil || formats[code!] != nil,pattern.range(of:"^[yMdEHhmsa :/.,'-]+$",options:.regularExpression) != nil else { throw DiagramError.invalid("Unsupported date format; cached field text is retained.") }
            let formatter = DateFormatter();formatter.locale = .current;formatter.timeZone = .current;formatter.dateFormat = pattern;return formatter.string(from:date)
        }
        if case .string = value,type == 0,text.isEmpty || text == "@" { return value.text }
        if text.isEmpty { return value.text }
        var n = try value.numeric(),suffix = ""
        let units:[String:(Double,String)] = ["IN":(1,"in."),"INCH":(1,"in."),"PT":(72,"pt."),"MM":(25.4,"mm"),"CM":(2.54,"cm"),"M":(0.0254,"m"),"FT":(1/12,"ft."),"DEG":(180 / .pi,"deg."),"RAD":(1,"rad.")]
        if let code {
            guard (0...9).contains(code) else { throw DiagramError.invalid("Unsupported field format code \(code); cached text is retained.") }
            if let conversion = units[(unit.isEmpty ? value.unit ?? "" : unit).uppercased()] { n *= conversion.0;if code % 2 == 1 { suffix = " "+conversion.1 } }
            let digits = code < 2 ? nil : (code-2)/2
            return (digits.map{String(format:"%.*f",locale:Locale(identifier:"en_US_POSIX"),$0,n)} ?? ShapeSheetEngine.format(n))+suffix
        }
        guard text.range(of:"^[#,0]+(?:\\.[0#]+)?%?$",options:.regularExpression) != nil else { throw DiagramError.invalid("Unsupported format picture; cached field text is retained.") }
        if text.hasSuffix("%") { n *= 100;suffix = "%" }
        let decimals = text.split(separator:".",omittingEmptySubsequences:false).dropFirst().first.map{String($0).filter{$0 == "0" || $0 == "#"}} ?? ""
        let formatter = NumberFormatter();formatter.locale = Locale(identifier:"en_US_POSIX");formatter.numberStyle = .decimal;formatter.usesGroupingSeparator = text.contains(",");formatter.minimumFractionDigits = decimals.filter{$0 == "0"}.count;formatter.maximumFractionDigits = decimals.count;formatter.roundingMode = .halfUp
        guard let result = formatter.string(from:NSNumber(value:n)) else { throw DiagramError.invalid("Field number cannot be formatted.") };return result+suffix
    }
}

enum TextFieldEngine {
    struct Calculation { var diagram:Diagram;var issues:[String]; var issuesByPage:[UUID:[String]] = [:]; var work = CalculationWork(); var changedNodeIDsByPage:[UUID:Set<UUID>] = [:]; var cancelled = false }
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
    static func recalculate(_ input:Diagram,now:Date = Date(),foreground:DiagramPage? = nil,previous:Diagram? = nil,retainedIssuesByPage:[UUID:[String]] = [:],session:CalculationSession? = nil,changes:DocumentChangeSet? = nil,cancellation:LifecycleJobCancellation? = nil) -> Calculation {
        var result = input,issues = Set<String>(),issuesByPage:[UUID:[String]] = [:]
        var work = CalculationWork()
        var changedNodeIDsByPage:[UUID:Set<UUID>] = [:]
        let session = session ?? CalculationSession()
        let oldPages = previous.map { Dictionary(uniqueKeysWithValues: $0.pages.map { ($0.id, $0) }) } ?? [:]
        func documentContext(_ diagram: Diagram) -> [DiagramPage] {
            diagram.pages.map { page in var page = page; page.nodes = []; page.edges = []; return page }
        }
        let changedContext = changes.map { $0.sourceResourcesChanged || $0.documentStructureChanged || $0.pages.values.contains { $0.pagePropertiesChanged } }
        let contextUnchanged = foreground == nil && (changedContext.map { !$0 } ?? (previous.map { $0.visioArchive == input.visioArchive && documentContext($0) == documentContext(input) } == true))
        for p in result.pages.indices {
            if cancellation?.isCancelled == true { return Calculation(diagram:input,issues:[],work:work,cancelled:true) }
            let page = result.pages[p],context = foreground ?? page
            let indexedBefore = session.indexedNodes, comparedBefore = session.comparedSources
            let pageChanges = changes?.pages[page.id]
            let trusted = previous != nil && changes != nil && changes?.sourceResourcesChanged == false && changes?.insertedPageIDs.contains(page.id) == false
            let dependency = session.index(for: page, binding: nil, fieldIdentifiers: true, changes: pageChanges, trustChanges: trusted)
            work.dependencyNodesIndexed += session.indexedNodes - indexedBefore
            work.dependencySourcesCompared += session.comparedSources - comparedBefore
            guard !dependency.fieldNodeIDs.isEmpty else { issuesByPage[page.id] = []; continue }
            if contextUnchanged, (trusted ? pageChanges == nil : oldPages[page.id] == page), dependency.volatileNodes.isEmpty {
                let retained = retainedIssuesByPage[page.id, default: []]
                issuesByPage[page.id] = retained; issues.formUnion(retained); continue
            }
            var affected: Set<UUID>?
            if contextUnchanged, let oldPage = oldPages[page.id],
               !dependency.requiresFullPage, retainedIssuesByPage[page.id, default: []].isEmpty {
                if trusted, let pageChanges, !pageChanges.pagePropertiesChanged, !pageChanges.hierarchyChanged,
                   !pageChanges.nodeOrderChanged, pageChanges.insertedNodeIDs.isEmpty, pageChanges.deletedNodeIDs.isEmpty {
                    affected = dependency.affected(by: pageChanges.changedNodeIDs)
                } else {
                    work.inputComparisonNodes += page.nodes.count + oldPage.nodes.count
                    if let changed = CalculationInvalidation.changedNodes(in: page, comparedTo: oldPage) { affected = dependency.affected(by: changed) }
                }
            }
            let selected = affected.map { dependency.fieldNodeIDs.intersection($0) } ?? dependency.fieldNodeIDs
            let candidates = selected.compactMap { dependency.nodeIndices[$0] }.sorted()
            guard !candidates.isEmpty else { issuesByPage[page.id] = []; continue }
            work.fieldPages += 1
            work.contexts += 1
            var pageIssues = Set<String>()
            let preparedBefore = session.preparedHostNodes
            let nodes = session.nodes(for: page, changes: pageChanges, trustChanges: trusted)
            work.hostNodesPrepared += session.preparedHostNodes - preparedBefore
            let identifiers = dependency.identifiers
            var cache:[String:SheetValue] = [:],active = Set<String>();var resolutions = 0
            func resolve(_ id:UUID,_ key:String) throws -> SheetValue {
                try cancellation?.check()
                work.cellRequests += 1
                resolutions += 1;guard resolutions < 1_000_000,active.count < 64 else { throw DiagramError.invalid("Field dependency limit exceeded.") }
                var id = id,name = key
                if let mark = name.lastIndex(of:"!") {
                    let owner = String(name[..<mark]),cell = String(name[name.index(after:mark)...])
                    if owner.lowercased() == "thepage" {
                        let values:[String:Double] = ["pagewidth":context.width/72,"pageheight":context.height/72,"pagescale":context.drawingScale?.page ?? 1,"drawingscale":context.drawingScale?.drawing ?? 1]
                        guard let v = values[cell.lowercased()] else { throw DiagramError.invalid("Unresolved page cell \(cell)") };return ["pagewidth","pageheight"].contains(cell.lowercased()) ? .quantity(v,context.drawingScale?.drawingUnit ?? "IN") : .number(v)
                    }
                    guard owner.lowercased().hasPrefix("sheet."),let target = identifiers[String(owner.dropFirst(6))] else { throw DiagramError.invalid("Unresolved field shape \(owner)") };id = target;name = cell
                }
                let token = id.uuidString+":"+name.lowercased();if let value = cache[token] { return value }
                work.evaluatedCells += 1
                guard active.insert(token).inserted,let node = nodes[id] else { throw DiagramError.invalid("Circular or missing field reference.") };defer{active.remove(token)}
                let value:SheetValue
                if let fieldIndex = indexed(name,"Fields.Value"),let field = node.formatting.textFields?.first(where:{$0.index == fieldIndex-1}) { value = try evaluate(field.cells["Value"] ?? ShapeSheetCell(value:""),id:id) }
                else if name.lowercased().hasPrefix("prop."),let property = node.formatting.data.first(where:{$0.key.caseInsensitiveCompare(String(name.dropFirst(5))) == .orderedSame}) {
                    let cell = node.formatting.sheet.first{$0.key.caseInsensitiveCompare(name) == .orderedSame}?.value
                    if let cell,!cell.formula.isEmpty,cell.formula != "No Formula" { value = try evaluate(cell,id:id) }
                    else if property.type == 3 { value = .boolean(property.value == "1" || property.value.uppercased() == "TRUE") }
                    else if [2,6,7].contains(property.type),let n = Double(property.value),n.isFinite { value = cell.flatMap{cell in SheetValue.factor(cell.unit).map{_ in SheetValue.quantity(n,cell.unit)}} ?? .number(n) }
                    else if property.type == 5,let date = FieldFormatting.date(property.value) { value = .date(date) }
                    else { value = .string(property.value) }
                }
                else if var cell = node.formatting.sheet.first(where:{$0.key.caseInsensitiveCompare(name) == .orderedSame})?.value {
                    if cell.unit.isEmpty,["Width","Height","PinX","PinY","LocPinX","LocPinY","LineWeight","Char.Size","Angle"].contains(where:{$0.caseInsensitiveCompare(name) == .orderedSame}) { cell.unit = name.caseInsensitiveCompare("Angle") == .orderedSame ? "RAD" : page.drawingScale?.drawingUnit ?? "IN" }
                    value = try evaluate(cell,id:id)
                }
                else if let n = ShapeSheetEngine.defaults(node,page:page,onDefaultPinFormulaEvaluation:{work.defaultPinFormulaEvaluations += 1}).first(where:{$0.key.caseInsensitiveCompare(name) == .orderedSame})?.value { value = name.caseInsensitiveCompare("Angle") == .orderedSame ? .quantity(n,"RAD") : ["Width","Height","PinX","PinY","LocPinX","LocPinY","LineWeight","Char.Size"].contains(where:{$0.caseInsensitiveCompare(name) == .orderedSame}) ? .quantity(n,"IN") : .number(n) }
                else { throw DiagramError.invalid("Unresolved field cell \(name).") }
                cache[token] = value;return value
            }
            func evaluate(_ cell:ShapeSheetCell,id:UUID) throws -> SheetValue {
                try cancellation?.check()
                if cell.formula.isEmpty || ["No Formula","Inh"].contains(cell.formula) {
                    if cell.unit.uppercased() == "DATE",let date = FieldFormatting.date(cell.value) { return .date(date) }
                    if cell.unit.uppercased() == "STR" { return .string(cell.value) }
                    if let n = Double(cell.value),n.isFinite { return SheetValue.factor(cell.unit).map{_ in .quantity(n,cell.unit)} ?? .number(n) };return .string(cell.value)
                }
                work.formulaEvaluations += 1
                return try TypedShapeSheet.evaluate(cell.formula,resolve:{try resolve(id,$0)},call:{name,values in
                    func count(_ n:Int) throws { guard values.count == n else { throw DiagramError.invalid("\(name) expects \(n) arguments.") } }
                    switch name {
                    case "PAGENAME":guard values.count <= 1 else { throw DiagramError.invalid("Invalid PAGENAME arguments") };return .string(context.name)
                    case "PAGENUMBER":try count(0);return .number(context.isBackground == true ? 0 : Double((input.pages.filter{$0.isBackground != true}.firstIndex{$0.id == context.id} ?? -1)+1))
                    case "PAGECOUNT":try count(0);return .number(Double(input.pages.filter{$0.isBackground != true}.count))
                    case "BKGPAGENAME":guard values.count <= 1 else { throw DiagramError.invalid("Invalid BKGPAGENAME arguments") };return .string(input.pages.first{$0.id == context.backgroundPageID}?.name ?? "")
                    case "ID":try count(0);guard let key = identifiers.first(where:{$0.value == id})?.key,let value = Double(key) else { throw DiagramError.invalid("Invalid shape ID") };return .number(value)
                    case "NOW":try count(0);return .date(now)
                    case "TODAY":try count(0);let calendar = Calendar(identifier:.gregorian);return .date(calendar.startOfDay(for:now))
                    case "DATE":try count(3);let calendar = Calendar(identifier:.gregorian);let numbers = try values.map{try $0.numeric()};guard numbers.allSatisfy({$0.isFinite && abs($0)<10000}),let date = calendar.date(from:DateComponents(year:Int(numbers[0]),month:Int(numbers[1]),day:Int(numbers[2]))) else { throw DiagramError.invalid("Invalid date") };return .date(date)
                    case "FORMAT":try count(2);return .string(try FieldFormatting.format(values[0],picture:values[1].text,unit:cell.unit))
                    default:throw DiagramError.invalid("Unsupported field function \(name); cached text is retained.")
                    }
                })
            }
            for i in candidates {
                if cancellation?.isCancelled == true { return Calculation(diagram:input,issues:[],work:work,cancelled:true) }
                var node = page.nodes[i];guard var fields = node.formatting.textFields,!fields.isEmpty,let originalRuns = node.formatting.textRuns else { continue }
                work.fieldNodes += 1
                var displays:[Int:String] = [:]
                for j in fields.indices {
                    let field = fields[j]
                    do {
                        guard let valueCell = field.cells["Value"] else { throw DiagramError.invalid("Unresolved field definition; cached display is retained.") }
                        let value = try evaluate(valueCell,id:node.id)
                        let formatCell = field.cells["Format"] ?? ShapeSheetCell(value:"",unit:"STR")
                        let picture = try evaluate(formatCell,id:node.id).text
                        let display = try FieldFormatting.format(value,picture:picture,unit:valueCell.unit,type:Int(field.cells["Type"]?.value ?? "0") ?? 0)
                        fields[j].cells["Value"]?.value = value.text;fields[j].cached = display;displays[field.index] = display
                    } catch { pageIssues.insert("Text field \(field.index+1): \(error.localizedDescription)") }
                }
                let runs = originalRuns.map { run in var run = run;if let index = run.fieldIndex,let display = displays[index] { run.text = display };return run }
                node.text = runs.map(\.text).joined();node.formatting.textRuns = runs;node.formatting.textFields = fields
                if node != page.nodes[i] { changedNodeIDsByPage[page.id, default: []].insert(node.id) }
                result.pages[p].nodes[i] = node
            }
            issuesByPage[page.id] = pageIssues.sorted()
            issues.formUnion(pageIssues)
        }
        if cancellation?.isCancelled == true { return Calculation(diagram:input,issues:[],work:work,cancelled:true) }
        return Calculation(diagram:result,issues:issues.sorted(),issuesByPage:issuesByPage,work:work,changedNodeIDsByPage:changedNodeIDsByPage)
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
    private static func indexed(_ text:String,_ prefix:String) -> Int? {
        guard text.lowercased().hasPrefix(prefix.lowercased()+"["),text.hasSuffix("]") else { return nil };return Int(text.dropFirst(prefix.count+1).dropLast())
    }
}
