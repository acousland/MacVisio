import Foundation

/// Resolves typed dependencies against one immutable page snapshot. Public cell
/// names, dependency cycles and limits are shared by geometry and control edits.
final class ShapeSheetContext {
    private enum ThemeState { case noTheme, active, unknown }
    private enum FormulaHost { case shape(UUID), page }
    let page:DiagramPage
    private let nodes:[UUID:DiagramNode]
    private var identifiers:[String:UUID] = [:]
    private var cache:[String:SheetValue] = [:],visiting = Set<String>(),steps = 0
    private let colorPalette:ShapeSheetColorPalette
    init(page:DiagramPage,binding:VisioPageBinding? = nil,colorPalette:ShapeSheetColorPalette = ShapeSheetColorPalette()) {
        self.page = page;nodes = Dictionary(uniqueKeysWithValues:page.nodes.map{($0.id,$0)})
        self.colorPalette = colorPalette
        for (i,n) in page.nodes.enumerated() { let id = binding?.nodeIDs[n.id] ?? n.formatting.sourceShapeID ?? String(i+1);if identifiers[id] == nil { identifiers[id] = n.id } }
    }
    func target(_ reference:String,from id:UUID) throws -> (UUID,String) {
        guard let mark = reference.firstIndex(of:"!") else { return (id,reference) }
        let owner = String(reference[..<mark]),key = String(reference[reference.index(after:mark)...])
        if owner.caseInsensitiveCompare("ParentShape") == .orderedSame,let parent = nodes[id]?.parentID { return (parent,key) }
        guard owner.uppercased().hasPrefix("SHEET."),let target = identifiers[String(owner.dropFirst(6))] ?? UInt32(owner.dropFirst(6)).flatMap({identifiers[String($0)]}) else { throw DiagramError.invalid("Unknown ShapeSheet reference: \(reference).") };return (target,key)
    }
    func number(_ id:UUID,_ reference:String) throws -> Double { try value(id,reference).numeric() }
    func value(_ id:UUID,_ reference:String) throws -> SheetValue {
        if reference.uppercased().hasPrefix("THEPAGE!") {
            return try pageValue(String(reference.dropFirst(8)),from:id)
        }
        let (id,key) = try target(reference,from:id)
        steps += 1;guard steps < 100000,visiting.count < 64,let node = nodes[id] else { throw DiagramError.invalid("ShapeSheet dependency limit exceeded.") }
        let canonical:String
        if let (c,axis) = ControlGeometry.address(key,on:node) { canonical = "Controls."+node.formatting.controls[c].name+"."+axis }
        else { canonical = node.formatting.sheet.keys.first{$0.caseInsensitiveCompare(key) == .orderedSame} ?? key }
        let token = id.uuidString+"!"+canonical.lowercased()
        if let value = cache[token] { return value };guard visiting.insert(token).inserted else { throw DiagramError.invalid("Circular ShapeSheet dependency at \(canonical).") };defer { visiting.remove(token) }
        let result:SheetValue
        if canonical.caseInsensitiveCompare("TheText") == .orderedSame { result = .string(node.text) }
        else {
            let property = canonical.lowercased().hasPrefix("prop.") ? node.formatting.data.first{$0.key.caseInsensitiveCompare(String(canonical.dropFirst(5))) == .orderedSame} : nil
            let cell = node.formatting.sheet[canonical] ?? ConnectionGeometry.cell(canonical,on:node) ?? GeometrySheet.cell(canonical,on:node) ?? ControlGeometry.cell(canonical,on:node)
            if let formula = cell?.formula,!formula.isEmpty,!["INH","NO FORMULA"].contains(formula.uppercased()) { result = try evaluate(formula,on:id) }
            else if let property {
                let stored = cell?.value ?? property.value
                if property.type == 3 { result = .boolean(stored == "1" || stored.uppercased() == "TRUE") }
                else if property.type == 5,let date = FieldFormatting.date(stored) { result = .date(date) }
                else if [2,6,7].contains(property.type),let number = Double(stored),number.isFinite { result = .number(number) }
                else { result = .string(stored) }
            } else if let cell {
                if cell.unit.uppercased() == "STR" || ["PROMPT","TIP"].contains(canonical.split(separator:".").last.map(String.init)?.uppercased() ?? "") { result = .string(cell.value) }
                else if cell.unit.uppercased() == "DATE",let date = FieldFormatting.date(cell.value) { result = .date(date) }
                else if let number = Double(cell.value),number.isFinite { result = .number(number) }
                else { result = .string(cell.value) }
            } else if canonical.caseInsensitiveCompare("TxtWidth") == .orderedSame { result = .number(try number(id,"Width")*(node.formatting.textBox?.width ?? 1)) }
            else if canonical.caseInsensitiveCompare("TxtHeight") == .orderedSame { result = .number(try number(id,"Height")*(node.formatting.textBox?.height ?? 1)) }
            else if canonical.caseInsensitiveCompare("TxtLocPinX") == .orderedSame { result = .number(try number(id,"TxtWidth")/2) }
            else if canonical.caseInsensitiveCompare("TxtLocPinY") == .orderedSame { result = .number(try number(id,"TxtHeight")/2) }
            else if let number = ShapeSheetEngine.defaults(node,page:page).first(where:{$0.key.caseInsensitiveCompare(canonical) == .orderedSame})?.value { result = .number(number) }
            else { throw DiagramError.invalid("Unknown ShapeSheet cell: \(canonical).") }
        };guard result.valid else { throw DiagramError.invalid("Invalid ShapeSheet value.") };cache[token] = result;return result
    }
    private func pageValue(_ reference:String,from host:UUID) throws -> SheetValue {
        steps += 1
        guard steps < 100000,visiting.count < 64 else { throw DiagramError.invalid("ShapeSheet dependency limit exceeded.") }
        let storedKey = page.sheet?.keys.first{$0.caseInsensitiveCompare(reference) == .orderedSame}
        let key = storedKey ?? reference
        let token = page.id.uuidString+"!"+key.lowercased()
        if let value = cache[token] { return value }
        guard visiting.insert(token).inserted else { throw DiagramError.invalid("Circular ShapeSheet dependency at ThePage!\(key).") }
        defer { visiting.remove(token) }

        let cell = storedKey.flatMap{page.sheet?[$0]}
        let formula = cell?.formula.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        let result:SheetValue
        if !formula.isEmpty && !["INH","NO FORMULA"].contains(formula.uppercased()) {
            result = try evaluate(ShapeSheet.parse(formula),on:host,host:.page)
        } else if let cell {
            let unit = cell.unit.uppercased()
            if unit == "STR" || ["PROMPT","TIP"].contains(key.split(separator:".").last.map(String.init)?.uppercased() ?? "") { result = .string(cell.value) }
            else if unit == "BOOL" { result = .boolean(cell.value == "1" || cell.value.uppercased() == "TRUE") }
            else if unit == "DATE",let date = FieldFormatting.date(cell.value) { result = .date(date) }
            else if let number = Double(cell.value),number.isFinite { result = .number(number) }
            else { result = .string(cell.value) }
        } else {
            let values = ["pagewidth":page.width/72,"pageheight":page.height/72,"pagescale":page.drawingScale?.page ?? 1,"drawingscale":page.drawingScale?.drawing ?? 1]
            guard let number = values[key.lowercased()] else { throw DiagramError.invalid("Unknown page cell: ThePage!\(reference).") }
            result = .number(number)
        }
        guard result.valid else { throw DiagramError.invalid("Invalid ShapeSheet page value.") }
        cache[token] = result
        return result
    }
    func evaluate(_ formula:String,on id:UUID) throws -> SheetValue {
        try evaluate(ShapeSheet.parse(formula),on:id,host:.shape(id))
    }
    func evaluate(_ expression:ShapeSheet.Expression,on id:UUID) throws -> SheetValue {
        try evaluate(expression,on:id,host:.shape(id))
    }
    private func evaluate(_ expression:ShapeSheet.Expression,on id:UUID,host:FormulaHost) throws -> SheetValue {
        try TypedShapeSheet.evaluate(expression,resolve:{try self.value(id,$0)},call:{name,_ in throw DiagramError.invalid("Unsupported ShapeSheet function: \(name).")},scalar:true,specialCall:{name,args,eval in
            if name == "THEMEVAL" {
                guard args.count == 2 else { throw DiagramError.invalid("THEMEVAL is supported only with an explicit default when No Theme is applied.") }
                switch self.themeState(for:host) {
                case .noTheme: return try eval(args[1])
                case .active: throw DiagramError.invalid("THEMEVAL for an active theme is unsupported; the original formula and cached value are retained.")
                case .unknown: throw DiagramError.invalid("THEMEVAL theme state is unknown; the original formula and cached value are retained.")
                }
            }
            if name == "ISTHEMED" {
                guard args.isEmpty else { throw DiagramError.invalid("ISTHEMED expects no arguments.") }
                return .boolean(try self.value(id,"ColorSchemeIndex").numeric() > 0)
            }
            guard ["SHAPETEXT","TEXTWIDTH","TEXTHEIGHT"].contains(name) else { return nil }
            guard (1...2).contains(args.count),case .reference(let reference) = args[0] else { throw DiagramError.invalid("\(name) requires a TheText reference and an optional parameter.") }
            let (owner,key) = try self.target(reference,from:id);guard key.caseInsensitiveCompare("TheText") == .orderedSame,let source = self.nodes[owner] else { throw DiagramError.invalid("\(name) requires a shape's TheText cell.") }
            if name == "SHAPETEXT" {
                let number = args.count == 2 ? try eval(args[1]).numeric() : 0;guard let flags = Int(exactly:number) else { throw DiagramError.invalid("Invalid SHAPETEXT flags.") };return .string(try ShapeTextFunctions.text(source,flags:flags))
            }
            var node = source
            if source.formatting.sheet["Char.Size"] != nil { let size = try self.number(owner,"Char.Size")*72;guard (1...500).contains(size) else { throw DiagramError.invalid("Invalid text measurement font size.") };node.fontSize = size
                if var runs = node.formatting.textRuns { for i in runs.indices where runs[i].character.size == source.fontSize { runs[i].character.size = size };node.formatting.textRuns = runs }
            }
            if ["LeftMargin","RightMargin","TopMargin","BottomMargin"].contains(where:{source.formatting.sheet[$0] != nil}) {
                var box = node.formatting.textBox ?? ShapeTextBox()
                if source.formatting.sheet["LeftMargin"] != nil { box.left = try self.number(owner,"LeftMargin")*72 };if source.formatting.sheet["RightMargin"] != nil { box.right = try self.number(owner,"RightMargin")*72 };if source.formatting.sheet["TopMargin"] != nil { box.top = try self.number(owner,"TopMargin")*72 };if source.formatting.sheet["BottomMargin"] != nil { box.bottom = try self.number(owner,"BottomMargin")*72 };node.formatting.textBox = box
            }
            let maximum = args.count == 2 ? try eval(args[1]).numeric() : name == "TEXTHEIGHT" ? try self.number(owner,"TxtWidth") : nil,metrics = try ShapeTextFunctions.metrics(node,page:self.page,maximumWidth:maximum)
            return .number(name == "TEXTWIDTH" ? metrics.width : metrics.height)
        },colorPalette:colorPalette)
    }
    private func themeState(for host:FormulaHost) -> ThemeState {
        guard case .shape(let id) = host,let node = nodes[id],
              let cell = node.formatting.sheet.first(where:{$0.key.caseInsensitiveCompare("ColorSchemeIndex") == .orderedSame})?.value,
              cell.formula.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              let value = Double(cell.value),value.isFinite,value.rounded(.towardZero) == value,
              let index = Int(exactly:value),index >= 0 else { return .unknown }
        return index == 0 ? .noTheme : .active
    }
    static func cached(_ value:SheetValue) -> String {
        switch value { case .boolean(let value):return value ? "1" : "0";case .number(let number),.quantity(let number,_):return CompositeGeometry.number(number);default:return value.text }
    }
}
