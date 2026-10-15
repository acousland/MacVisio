import Foundation

/// Resolves typed dependencies against one immutable page snapshot. Public cell
/// names, dependency cycles and limits are shared by geometry and control edits.
final class ShapeSheetContext {
    private enum ThemeState { case noTheme, active(VisioTheme), unavailable(String), unknown }
    private enum ThemeColorSelector { case named(String), oneBasedIndex(Int), quickStyleReference(ShapeSheet.Expression) }
    private enum ThemeLineComponent:Equatable { case effect, connector }
    private enum ThemeLineSelector { case weight(forceConnector:Bool), cap }
    private enum ThemeLineState { case noTheme, active(VisioTheme,ThemeLineComponent), unavailable(String), unknown }
    private enum FormulaHost { case shape(UUID,String?), page(String?) }
    let page:DiagramPage
    private let nodes:[UUID:DiagramNode]
    private var identifiers:[String:UUID] = [:]
    private var cache:[String:SheetValue] = [:],visiting = Set<String>(),steps = 0
    // Exact spellings are safe aliases inside this immutable page snapshot.
    // Resolve them before repeating control and case-insensitive cell scans.
    private var referenceCache:[UUID:[String:SheetValue]] = [:]
    private var expressions:[String:ShapeSheet.Expression] = [:]
    private var sheetKeyIndices:[UUID:[String:String]] = [:]
    private var unicodeSheetKeys = Set<UUID>()
    private var defaultsCache:[UUID:[String:Double]] = [:]
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
        steps += 1;guard steps < 100000,visiting.count < 64 else { throw DiagramError.invalid("ShapeSheet dependency limit exceeded.") }
        if let value = referenceCache[id]?[key] { return value }
        guard let node = nodes[id] else { throw DiagramError.invalid("ShapeSheet dependency limit exceeded.") }
        let canonical:String
        if let (c,axis) = ControlGeometry.address(key,on:node) { canonical = "Controls."+node.formatting.controls[c].name+"."+axis }
        else { canonical = sheetKey(key,on:node) ?? key }
        let token = id.uuidString+"!"+canonical.lowercased()
        if let value = cache[token] { referenceCache[id,default:[:]][key] = value;return value };guard visiting.insert(token).inserted else { throw DiagramError.invalid("Circular ShapeSheet dependency at \(canonical).") };defer { visiting.remove(token) }
        PerformanceEvidence.count(.evaluatedCells)
        let result:SheetValue
        if canonical.caseInsensitiveCompare("TheText") == .orderedSame { result = .string(node.text) }
        else {
            let property = canonical.lowercased().hasPrefix("prop.") ? node.formatting.data.first{$0.key.caseInsensitiveCompare(String(canonical.dropFirst(5))) == .orderedSame} : nil
            let cell = node.formatting.sheet[canonical] ?? ConnectionGeometry.cell(canonical,on:node) ?? GeometrySheet.cell(canonical,on:node) ?? ControlGeometry.cell(canonical,on:node)
            if let formula = cell?.formula,!formula.isEmpty,!["INH","NO FORMULA"].contains(formula.uppercased()) { result = try evaluate(formula,on:id,hostCell:canonical) }
            else if let property {
                let stored = cell?.value ?? property.value
                if property.type == 3 { result = .boolean(stored == "1" || stored.uppercased() == "TRUE") }
                else if property.type == 5,let date = FieldFormatting.date(stored) { result = .date(date) }
                else if [2,6,7].contains(property.type),let number = Double(stored),number.isFinite { result = .number(number) }
                else { result = .string(stored) }
            } else if let cell {
                if cell.unit.uppercased() == "STR" || ["PROMPT","TIP"].contains(canonical.split(separator:".").last.map(String.init)?.uppercased() ?? "") { result = .string(cell.value) }
                else if cell.unit.uppercased() == "DATE",let date = FieldFormatting.date(cell.value) { result = .date(date) }
                else if let color = literalColor(cell,key:canonical) { result = .color(color) }
                else if let number = Double(cell.value),number.isFinite { result = .number(number) }
                else { result = .string(cell.value) }
            } else if canonical.caseInsensitiveCompare("TxtWidth") == .orderedSame { result = .number(try number(id,"Width")*(node.formatting.textBox?.width ?? 1)) }
            else if canonical.caseInsensitiveCompare("TxtHeight") == .orderedSame { result = .number(try number(id,"Height")*(node.formatting.textBox?.height ?? 1)) }
            else if canonical.caseInsensitiveCompare("TxtLocPinX") == .orderedSame { result = .number(try number(id,"TxtWidth")/2) }
            else if canonical.caseInsensitiveCompare("TxtLocPinY") == .orderedSame { result = .number(try number(id,"TxtHeight")/2) }
            else if let number = defaults(for:node).first(where:{$0.key.caseInsensitiveCompare(canonical) == .orderedSame})?.value { result = .number(number) }
            else { throw DiagramError.invalid("Unknown ShapeSheet cell: \(canonical).") }
        };guard result.valid else { throw DiagramError.invalid("Invalid ShapeSheet value.") };cache[token] = result;referenceCache[id,default:[:]][key] = result;return result
    }
    private func defaults(for node:DiagramNode) -> [String:Double] {
        if let values = defaultsCache[node.id] { return values }
        let values = ShapeSheetEngine.defaults(node,page:page,nodesByID:nodes)
        defaultsCache[node.id] = values
        return values
    }
    private func sheetKey(_ reference:String,on node:DiagramNode) -> String? {
        // ASCII ShapeSheet names have an exact case-folded index. Retain
        // Foundation's comparison rules for Unicode names and references.
        func scan() -> String? { node.formatting.sheet.keys.first{$0.caseInsensitiveCompare(reference) == .orderedSame} }
        guard reference.utf8.allSatisfy({$0 < 128}),!unicodeSheetKeys.contains(node.id) else { return scan() }
        if let keys = sheetKeyIndices[node.id] { return keys[reference.lowercased()] }
        var keys:[String:String] = [:]
        for key in node.formatting.sheet.keys {
            guard key.utf8.allSatisfy({$0 < 128}) else { unicodeSheetKeys.insert(node.id);return scan() }
            let folded = key.lowercased()
            if keys[folded] == nil { keys[folded] = key }
        }
        sheetKeyIndices[node.id] = keys
        return keys[reference.lowercased()]
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

        PerformanceEvidence.count(.evaluatedCells)
        let cell = storedKey.flatMap{page.sheet?[$0]}
        let formula = cell?.formula.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        let result:SheetValue
        if !formula.isEmpty && !["INH","NO FORMULA"].contains(formula.uppercased()) {
            result = try evaluate(expression(formula),on:host,host:.page(key))
        } else if let cell {
            let unit = cell.unit.uppercased()
            if unit == "STR" || ["PROMPT","TIP"].contains(key.split(separator:".").last.map(String.init)?.uppercased() ?? "") { result = .string(cell.value) }
            else if unit == "BOOL" { result = .boolean(cell.value == "1" || cell.value.uppercased() == "TRUE") }
            else if unit == "DATE",let date = FieldFormatting.date(cell.value) { result = .date(date) }
            else if let color = literalColor(cell,key:key) { result = .color(color) }
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
        try evaluate(expression(formula),on:id,host:.shape(id,nil))
    }
    func evaluate(_ expression:ShapeSheet.Expression,on id:UUID) throws -> SheetValue {
        try evaluate(expression,on:id,host:.shape(id,nil))
    }
    private func evaluate(_ formula:String,on id:UUID,hostCell:String?) throws -> SheetValue {
        try evaluate(expression(formula),on:id,host:.shape(id,hostCell))
    }
    private func expression(_ formula:String) throws -> ShapeSheet.Expression {
        if let parsed = expressions[formula] { return parsed }
        let parsed = try ShapeSheet.parse(formula)
        expressions[formula] = parsed
        return parsed
    }
    private func evaluate(_ expression:ShapeSheet.Expression,on id:UUID,host:FormulaHost) throws -> SheetValue {
        try TypedShapeSheet.evaluate(expression,resolve:{try self.value(id,$0)},call:{name,_ in throw DiagramError.invalid("Unsupported ShapeSheet function: \(name).")},scalar:true,specialCall:{name,args,eval in
            if name == "THEMEVAL" {
                guard args.count <= 2 else { throw DiagramError.invalid("THEMEVAL accepts at most two arguments.") }
                let colorSelector:ThemeColorSelector?
                let lineSelector:ThemeLineSelector?
                if args.isEmpty {
                    guard let cell = self.hostCell(for:host) else {
                        throw DiagramError.invalid("THEMEVAL() has no supported mapping for this host cell.")
                    }
                    if let selectorName = self.paletteName(cell) {
                        colorSelector = .named(selectorName);lineSelector = nil
                    } else if let line = self.lineSelector(forHostCell:cell) {
                        colorSelector = nil;lineSelector = line
                    } else {
                        throw DiagramError.invalid("THEMEVAL() has no supported palette mapping for host cell \(cell).")
                    }
                } else {
                    if let value = self.themeColorSelector(args[0]) {
                        colorSelector = value;lineSelector = nil
                    } else if case .string(let name) = args[0],let value = self.lineSelector(named:name) {
                        colorSelector = nil;lineSelector = value
                    } else {
                        throw DiagramError.invalid("THEMEVAL theme mapping is unsupported; only palette colors and numeric color selectors are available. The original formula and cached value are retained.")
                    }
                }

                if let lineSelector {
                    let state = self.lineThemeState(for:lineSelector,host:host)
                    if args.count == 2,case .noTheme = state { return try eval(args[1]) }
                    switch state {
                    case .noTheme: throw DiagramError.invalid("THEMEVAL No Theme line values are unavailable; the original cached value is retained.")
                    case .active(let theme,let component): return try self.themeLineValue(selector:lineSelector,component:component,host:host,in:theme)
                    case .unavailable(let reason): throw DiagramError.invalid("THEMEVAL active line theme is unavailable: \(reason). The original formula and cached value are retained.")
                    case .unknown: throw DiagramError.invalid("THEMEVAL line theme selectors are missing or unresolved; the original formula and cached value are retained.")
                    }
                } else if let colorSelector {
                    if args.count == 2, self.hasNoThemeSelector(for:host,includingEffectsAndConnectors:true) {
                        return try eval(args[1])
                    }
                    switch self.colorThemeState(for:host) {
                    case .noTheme:
                        if args.count == 2 { return try eval(args[1]) }
                        throw DiagramError.invalid("THEMEVAL No Theme column values are unavailable for this palette selector; the original formula and cached value are retained.")
                    case .active(let theme):
                        return try self.themeValue(selector:colorSelector,in:theme,evaluate:eval)
                    case .unavailable(let reason): throw DiagramError.invalid("THEMEVAL active theme is unavailable: \(reason). The original formula and cached value are retained.")
                    case .unknown: throw DiagramError.invalid("THEMEVAL theme state is unknown; the original cached value is retained.")
                    }
                }
            }
            if name == "THEMEPROP" {
                guard args.count == 1 else { throw DiagramError.invalid("THEMEPROP expects one argument.") }
                guard case .string(let property) = try eval(args[0]) else {
                    throw DiagramError.invalid("THEMEPROP expects Embellishment or MultiFormat as a string.")
                }
                switch property.lowercased() {
                case "embellishment","multiformat": break
                default: throw DiagramError.invalid("THEMEPROP does not support \(property).")
                }
                guard let theme = try self.themePropTheme(for:host) else { return .number(0) }
                return try self.themePropValue(property.lowercased(),for:host,in:theme)
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
    private func colorThemeState(for host:FormulaHost) -> ThemeState {
        let cells:[String:ShapeSheetCell]?
        switch host {
        case .shape(let id,_): cells = nodes[id]?.formatting.sheet
        case .page: cells = page.sheet
        }
        if hasNoThemeSelector(for:host,includingEffectsAndConnectors:false) { return .noTheme }
        guard let cell = cells?.first(where:{$0.key.caseInsensitiveCompare("ColorSchemeIndex") == .orderedSame})?.value,
              cell.formula.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              let value = Double(cell.value),value.isFinite,value.rounded(.towardZero) == value,
              let index = Int(exactly:value),index >= 0,index <= 65535 else { return .unknown }
        if index == 0 { return .noTheme }
        if index == 65535 { return .unavailable("custom associated-master color schemes are unsupported") }

        let inheritedPageIndex:Int?
        if index == 65534 {
            inheritedPageIndex = cellsValue(page.sheet,"ColorSchemeIndex")
            guard let pageIndex = inheritedPageIndex else { return .unavailable("the page ColorSchemeIndex is missing or unresolved") }
            if pageIndex == 0 { return .noTheme }
            guard pageIndex < 65534 else { return .unknown }
            guard let theme = page.theme,theme.schemeIndex == pageIndex else { return .unavailable("the selected page theme does not match ColorSchemeIndex \(pageIndex)") }
            return .active(theme)
        }

        guard index < 65534 else { return .unknown }
        guard let theme = page.theme,theme.schemeIndex == index else { return .unavailable("no imported page theme matches ColorSchemeIndex \(index)") }
        return .active(theme)
    }

    private func hostCell(for host:FormulaHost) -> String? {
        switch host { case .shape(_,let cell),.page(let cell):return cell }
    }

    private func lineSelector(forHostCell cell:String) -> ThemeLineSelector? {
        switch cell.lowercased() {
        case "lineweight": return .weight(forceConnector:false)
        case "connectorweight": return .weight(forceConnector:true)
        case "linecap": return .cap
        default: return nil
        }
    }

    private func lineSelector(named name:String) -> ThemeLineSelector? {
        switch name.lowercased() {
        case "lineweight": return .weight(forceConnector:false)
        case "connectorweight": return .weight(forceConnector:true)
        case "linecap": return .cap
        default: return nil
        }
    }

    private func lineThemeState(for selector:ThemeLineSelector,host:FormulaHost) -> ThemeLineState {
        let component:ThemeLineComponent
        switch selector {
        case .weight(forceConnector:true): component = .connector
        case .weight(forceConnector:false),.cap:
            let cells:[String:ShapeSheetCell]?
            switch host {
            case .shape(let id,_): cells = nodes[id]?.formatting.sheet
            case .page: cells = page.sheet
            }
            guard let quickStyleType = literalIndex(cells,"QuickStyleType") else { return .unknown }
            switch quickStyleType {
            case 0:
                guard case .shape = host else { return .unknown }
                component = .effect
            case 1,2: component = .effect
            case 3: component = .connector
            default: return .unavailable("QuickStyleType \(quickStyleType) is outside the supported 0...3 range")
            }
        }

        let key = component == .effect ? "EffectSchemeIndex" : "ConnectorSchemeIndex"
        guard let index = themeComponentIndex(key,for:host) else { return .unknown }
        if index == 0 { return .noTheme }
        if index == 65535 { return .unavailable("custom associated-master line schemes are unsupported") }
        guard (1...65533).contains(index) else { return .unknown }
        guard let theme = page.theme else { return .unavailable("the page has no imported Office theme") }
        let expectedIndex = component == .effect ? theme.effectSchemeIndex : theme.connectorSchemeIndex
        guard let expectedIndex,expectedIndex == index else {
            return .unavailable("the selected \(component == .effect ? "effect" : "connector") scheme does not match the imported theme")
        }
        return .active(theme,component)
    }

    private func themeLineValue(selector:ThemeLineSelector,component:ThemeLineComponent,host:FormulaHost,in theme:VisioTheme) throws -> SheetValue {
        let matrix = try quickStyleLineIndex(for:host,in:theme)
        let styles = component == .effect ? theme.effectLineStyles : theme.connectorLineStyles
        guard styles.indices.contains(matrix) else {
            throw DiagramError.invalid("THEMEVAL selected line matrix \(matrix + 1) is absent from the imported \(component == .effect ? "effect" : "connector") scheme.")
        }
        let style = styles[matrix]
        switch selector {
        case .weight:
            guard let width = style.widthEMU,width >= 0 else {
                throw DiagramError.invalid("THEMEVAL selected line matrix has no supported DrawingML width.")
            }
            return .quantity(Double(width)/914400.0,"IN")
        case .cap:
            switch style.cap?.lowercased() {
            case "rnd": return .number(0)
            case "sq": return .number(1)
            case "flat": return .number(2)
            case nil: return .number(1)
            default: throw DiagramError.invalid("THEMEVAL selected line cap is not a supported DrawingML token.")
            }
        }
    }

    private func quickStyleLineIndex(for host:FormulaHost,in theme:VisioTheme) throws -> Int {
        let cells:[String:ShapeSheetCell]?
        switch host {
        case .shape(let id,_): cells = nodes[id]?.formatting.sheet
        case .page: cells = page.sheet
        }
        guard let matrix = literalIndex(cells,"QuickStyleLineMatrix") else {
            throw DiagramError.invalid("THEMEVAL QuickStyleLineMatrix is missing or unresolved; the original cached value is retained.")
        }
        let selected:Int
        switch matrix {
        case 1...6: selected = matrix
        case 100...103:
            let variation = try variationIndex("VariationStyleIndex",for:host,theme:theme)
            let offset = matrix - 100
            guard let styles = theme.variationStyleSchemes[variation]?.styles,styles.indices.contains(offset),
                  let index = styles[offset].lineIndex else {
                throw DiagramError.invalid("THEMEVAL selected style variation has no lineIdx for QuickStyleLineMatrix \(matrix).")
            }
            selected = index
        case 0:
            throw DiagramError.invalid("THEMEVAL QuickStyleLineMatrix 0 selects the root style, whose value is not imported as a dynamic theme line.")
        default:
            throw DiagramError.invalid("THEMEVAL QuickStyleLineMatrix \(matrix) is outside the supported dynamic theme range.")
        }
        guard (1...6).contains(selected) else {
            throw DiagramError.invalid("THEMEVAL selected lineIdx \(selected) is outside the supported dynamic theme range 1...6.")
        }
        return selected - 1
    }

    private func themeColorSelector(_ expression:ShapeSheet.Expression) -> ThemeColorSelector? {
        switch expression {
        case .string(let name):
            if let palette = paletteName(name) { return .named(palette) }
            if let index = Int(name),String(index) == name,(1...8).contains(index) { return .oneBasedIndex(index) }
        case .number(let number):
            if let index = Int(exactly:number),(1...8).contains(index) { return .oneBasedIndex(index) }
        case .reference(let reference):
            let cell = reference.split(separator:"!").last.map(String.init) ?? reference
            if ["QuickStyleFillColor","QuickStyleLineColor"].contains(where:{$0.caseInsensitiveCompare(cell) == .orderedSame}) {
                return .quickStyleReference(expression)
            }
        default: break
        }
        return nil
    }

    private func themeValue(selector:ThemeColorSelector,in theme:VisioTheme,evaluate:(ShapeSheet.Expression)throws->SheetValue) throws -> SheetValue {
        switch selector {
        case .named(let name): return try themeValue(named:name,in:theme)
        case .oneBasedIndex(let index): return try themeValue(index:index,in:theme,quickStyle:false)
        case .quickStyleReference(let expression):
            switch try evaluate(expression) {
            case .number(let number):
                guard let index = Int(exactly:number) else { throw DiagramError.invalid("THEMEVAL QuickStyle color selector must be an integer.") }
                return try themeValue(index:index,in:theme,quickStyle:true)
            case .string(let name): return try themeValue(named:name,in:theme)
            default: throw DiagramError.invalid("THEMEVAL QuickStyle color selector must be a string or integer.")
            }
        }
    }

    private func themeValue(index:Int,in theme:VisioTheme,quickStyle:Bool) throws -> SheetValue {
        let name:String
        if quickStyle,(0...8).contains(index) {
            name = ["Dark","Light","AccentColor1","AccentColor2","AccentColor3","AccentColor4","AccentColor5","AccentColor6","BackgroundColor"][index]
        } else if (1...8).contains(index) {
            name = ["Dark","Light","AccentColor1","AccentColor2","AccentColor3","AccentColor4","AccentColor5","AccentColor6"][index-1]
        } else if quickStyle,(100...106).contains(index) {
            name = "VariantColor\(index % 100 + 1)"
        } else {
            throw DiagramError.invalid("THEMEVAL does not support theme color index \(index).")
        }
        return try themeValue(named:name,in:theme)
    }

    private func themeValue(named requested:String,in theme:VisioTheme) throws -> SheetValue {
        guard let name = paletteName(requested) else {
            throw DiagramError.invalid("THEMEVAL theme mapping \(requested) is unsupported; only palette colors and variants are available. The original formula and cached value are retained.")
        }
        if let color = theme.colors.first(where:{$0.key.caseInsensitiveCompare(name) == .orderedSame})?.value {
            guard color.count == 7,color.hasPrefix("#"),color.dropFirst().allSatisfy(\.isHexDigit) else { throw DiagramError.invalid("THEMEVAL theme color \(requested) is not a supported RGB value.") }
            guard let rgb = ShapeSheetColor(hex:color) else { throw DiagramError.invalid("THEMEVAL theme color \(requested) is not a supported RGB value.") }
            return .color(rgb)
        }
        throw DiagramError.invalid("THEMEVAL theme mapping \(requested) is unavailable; the original formula and cached value are retained.")
    }

    private func paletteName(_ requested:String) -> String? {
        let canonical = requested.caseInsensitiveCompare("AccentColor") == .orderedSame ? "AccentColor1" : requested
        let names = ["Dark","Light","BackgroundColor","AccentColor1","AccentColor2","AccentColor3","AccentColor4","AccentColor5","AccentColor6"]
            + (1...7).map { "VariantColor\($0)" }
        return names.first{$0.caseInsensitiveCompare(canonical) == .orderedSame}
    }

    private func hasNoThemeSelector(for host:FormulaHost,includingEffectsAndConnectors:Bool) -> Bool {
        let cells:[String:ShapeSheetCell]?
        switch host {
        case .shape(let id,_): cells = nodes[id]?.formatting.sheet
        case .page: cells = page.sheet
        }
        let selectorNames = includingEffectsAndConnectors
            ? ["ThemeIndex","ColorSchemeIndex","EffectSchemeIndex","ConnectorSchemeIndex","FontSchemeIndex"]
            : ["ThemeIndex","ColorSchemeIndex","FontSchemeIndex"]
        return selectorNames.contains { key in
            let value = literalIndex(cells,key)
            if value == 0 { return true }
            guard case .shape = host,value == 65534 else { return false }
            return literalIndex(page.sheet,key) == 0
        }
    }

    /// Returns nil when any explicit or inherited component selector selects
    /// the root/no-theme style. Missing or unresolved selectors stay errors;
    /// the imported page theme alone does not prove a shape's active selection.
    private func themePropTheme(for host:FormulaHost) throws -> VisioTheme? {
        let selectors = ["ThemeIndex","ColorSchemeIndex","EffectSchemeIndex","ConnectorSchemeIndex","FontSchemeIndex"]
        let indexes = selectors.map { themeComponentIndex($0,for:host) }
        if indexes.contains(where:{$0 == 0}) { return nil }
        guard indexes.allSatisfy({$0 != nil}) else {
            throw DiagramError.invalid("THEMEPROP theme component selectors are missing or unresolved; the original formula and cached value are retained.")
        }
        let values = indexes.map{$0!}
        guard values.enumerated().allSatisfy({offset,value in value > 0 && (offset == 1 ? value <= 65535 : value <= 65534)}) else {
            throw DiagramError.invalid("THEMEPROP uses an unsupported custom or invalid theme component selector; the original formula and cached value are retained.")
        }
        let colorIndex = values[1]
        guard colorIndex < 65534 else {
            throw DiagramError.invalid("THEMEPROP custom associated-master color schemes are unsupported; the original formula and cached value are retained.")
        }
        guard let theme = page.theme,theme.schemeIndex == colorIndex else {
            throw DiagramError.invalid("THEMEPROP has no imported theme matching ColorSchemeIndex \(colorIndex); the original formula and cached value are retained.")
        }
        return theme
    }

    /// Shape-level component selectors use 65534 to inherit the corresponding
    /// PageSheet selector. Other missing/formula-backed selector sources are
    /// deliberately unresolved.
    private func themeComponentIndex(_ key:String,for host:FormulaHost) -> Int? {
        let cells:[String:ShapeSheetCell]?
        let isShape:Bool
        switch host {
        case .shape(let id,_): cells = nodes[id]?.formatting.sheet;isShape = true
        case .page: cells = page.sheet;isShape = false
        }
        guard let value = literalIndex(cells,key) else { return nil }
        if value == 65534 {
            guard isShape else { return nil }
            guard let inherited = literalIndex(page.sheet,key),inherited != 65534 else { return nil }
            return inherited
        }
        return value
    }

    private func literalIndex(_ cells:[String:ShapeSheetCell]?,_ key:String) -> Int? {
        guard let cell = cells?.first(where:{$0.key.caseInsensitiveCompare(key) == .orderedSame})?.value,
              cell.formula.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              let number = Double(cell.value),number.isFinite,number.rounded(.towardZero) == number else { return nil }
        return Int(exactly:number)
    }

    private func themePropValue(_ property:String,for host:FormulaHost,in theme:VisioTheme) throws -> SheetValue {
        if property == "multiformat" {
            let index = try variationIndex("VariationColorIndex",for:host,theme:theme)
            guard let monotone = theme.variationColorSchemeMonotone[index] else {
                throw DiagramError.invalid("THEMEPROP MultiFormat has no imported color variation at index \(index); the original formula and cached value are retained.")
            }
            return .number(monotone ? 1 : 0)
        }

        let embellishment = try embellishmentIndex(for:host)
        if embellishment != 0 { return .number(Double(embellishment)) }
        let index = try variationIndex("VariationStyleIndex",for:host,theme:theme)
        guard let value = theme.variationStyleSchemes[index]?.embellishment,(0...255).contains(value) else {
            throw DiagramError.invalid("THEMEPROP Embellishment has no imported style variation at index \(index); the original formula and cached value are retained.")
        }
        return .number(Double(value))
    }

    private func embellishmentIndex(for host:FormulaHost) throws -> Int {
        let direct:ShapeSheetCell?
        let isShape:Bool
        switch host {
        case .shape(let id,_): direct = nodes[id]?.formatting.sheet.first{$0.key.caseInsensitiveCompare("EmbellishmentIndex") == .orderedSame}?.value;isShape = true
        case .page: direct = page.sheet?.first{$0.key.caseInsensitiveCompare("EmbellishmentIndex") == .orderedSame}?.value;isShape = false
        }
        let value:Int
        if let direct {
            guard direct.formula.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  let parsed = Int(direct.value),parsed >= 0,parsed <= 255 || (isShape && parsed == 65534) else {
                throw DiagramError.invalid("THEMEPROP EmbellishmentIndex is not a supported literal value; the original formula and cached value are retained.")
            }
            if parsed == 65534 {
                guard isShape else { throw DiagramError.invalid("THEMEPROP PageSheet EmbellishmentIndex cannot inherit from another page.") }
                value = try pageEmbellishmentIndex()
            } else { value = parsed }
        } else { value = 0 }
        return value
    }

    private func pageEmbellishmentIndex() throws -> Int {
        guard let cell = page.sheet?.first(where:{$0.key.caseInsensitiveCompare("EmbellishmentIndex") == .orderedSame})?.value else { return 0 }
        guard cell.formula.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              let value = Int(cell.value),value >= 0,value <= 255 else {
            throw DiagramError.invalid("THEMEPROP inherited PageSheet EmbellishmentIndex is missing or unresolved.")
        }
        return value
    }

    private func variationIndex(_ key:String,for host:FormulaHost,theme:VisioTheme) throws -> Int {
        let pageSelected = try pageVariationIndex(key,theme:theme)
        let direct:ShapeSheetCell?
        let isShape:Bool
        switch host {
        case .shape(let id,_): direct = nodes[id]?.formatting.sheet.first{$0.key.caseInsensitiveCompare(key) == .orderedSame}?.value;isShape = true
        case .page: direct = page.sheet?.first{$0.key.caseInsensitiveCompare(key) == .orderedSame}?.value;isShape = false
        }
        guard let direct else { return pageSelected }
        guard direct.formula.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              let parsed = Int(direct.value),parsed >= 0 else {
            throw DiagramError.invalid("THEMEPROP \(key) is missing or unresolved; the original formula and cached value are retained.")
        }
        if parsed == 65534 {
            guard isShape else {
                throw DiagramError.invalid("THEMEPROP inherited \(key) is unavailable; the original formula and cached value are retained.")
            }
            return pageSelected
        }
        guard parsed <= 3 else {
            throw DiagramError.invalid("THEMEPROP \(key) index \(parsed) is outside the imported variation range.")
        }
        return parsed
    }

    private func pageVariationIndex(_ key:String,theme:VisioTheme) throws -> Int {
        if let cell = page.sheet?.first(where:{$0.key.caseInsensitiveCompare(key) == .orderedSame})?.value {
            guard cell.formula.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  let value = Int(cell.value),value >= 0,value <= 3 else {
                throw DiagramError.invalid("THEMEPROP PageSheet \(key) is missing or unresolved; the original formula and cached value are retained.")
            }
            return value
        }
        let selected = key.caseInsensitiveCompare("VariationStyleIndex") == .orderedSame
            ? theme.variationStyleIndex : theme.variationColorIndex
        guard let selected else { return 0 }
        guard (0...3).contains(selected) else {
            throw DiagramError.invalid("THEMEPROP selected \(key) is outside the imported variation range.")
        }
        return selected
    }

    private func cellsValue(_ cells:[String:ShapeSheetCell]?,_ key:String) -> Int? {
        guard let cell = cells?.first(where:{$0.key.caseInsensitiveCompare(key) == .orderedSame})?.value,
              cell.formula.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              let value = Double(cell.value),value.isFinite,value.rounded(.towardZero) == value else { return nil }
        return Int(exactly:value)
    }
    private func literalColor(_ cell:ShapeSheetCell,key:String) -> ShapeSheetColor? {
        let name = key.lowercased()
        let colorCell = cell.unit.caseInsensitiveCompare("COLOR") == .orderedSame
            || name == "fillforegnd" || name == "fillbkgnd" || name == "color"
            || name.hasSuffix(".color") || name.hasSuffix("fillcolor") || name.hasSuffix("linecolor")
            || name.hasSuffix("shdwcolor") || name.hasSuffix("backgroundcolor")
        return colorCell ? ShapeSheetColor(hex:cell.value) : nil
    }
    static func cached(_ value:SheetValue) -> String {
        switch value { case .boolean(let value):return value ? "1" : "0";case .number(let number),.quantity(let number,_):return CompositeGeometry.number(number);default:return value.text }
    }
}
