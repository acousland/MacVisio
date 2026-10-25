import MacVisioInfrastructure
import Foundation

/// Resolves typed dependencies against one immutable page snapshot. Public cell
/// names, dependency cycles and limits are shared by geometry and control edits.
final class ShapeSheetContext {
    enum ValueMode: Equatable { case scalarGeometry, typedFields }
    private enum ThemeState { case noTheme, active(VisioTheme), unavailable(String), unknown }
    private enum ThemeColorSelector { case named(String), oneBasedIndex(Int), quickStyleReference(ShapeSheet.Expression) }
    private enum ThemeLineComponent:Equatable { case effect, connector }
    private enum ThemeLineSelector { case weight(forceConnector:Bool), cap }
    private enum ThemeLineState { case noTheme, active(VisioTheme,ThemeLineComponent), unavailable(String), unknown }
    private enum FormulaHost { case shape(UUID,String?), page(String?) }
    private var measuredWork = CalculationWork(contexts: 1)
    var work: CalculationWork {
        var result = measuredWork
        if let foregroundContext { result.add(foregroundContext.work) }
        return result
    }
    let page:DiagramPage
    let nodes:[UUID:DiagramNode]
    private var identifiers:[String:UUID] = [:]
    let publicIDsByObject: [UUID: String]
    private var cache:[String:SheetValue] = [:],visiting = Set<String>(),steps = 0
    // Exact spellings are safe aliases inside this immutable page snapshot.
    // Resolve them before repeating control and case-insensitive cell scans.
    private var referenceCache:[UUID:[String:SheetValue]] = [:]
    private var expressions:[String:ShapeSheet.Expression] = [:]
    private var sheetKeyIndices:[UUID:[String:String]] = [:]
    private var unicodeSheetKeys = Set<UUID>()
    private var defaultsCache:[UUID:[String:Double]] = [:]
    private let colorPalette:ShapeSheetColorPalette
    private let cancellation:LifecycleJobCancellation?
    let document: Diagram?
    /// The saved file, for FILENAME() and DIRECTORY(); nil for a drawing that has not been saved.
    var documentURL: URL?
    let pageBinding: VisioPageBinding?
    private let foreground: DiagramPage?
    let now: Date
    private let mode: ValueMode
    private var definitionSheets: [UUID: DefinitionSheet]?
    private var definitionScopes: [UUID: [String: UUID]] = [:]
    private var definitionCells: [UUID: [String: DefinitionCell]] = [:]
    private var foregroundContext: ShapeSheetContext?
    private var failuresByDefinitionCell: [String: DocumentDiagnostic] = [:]
    var definitionDiagnostics: [DocumentDiagnostic] {
        let local = failuresByDefinitionCell.keys.sorted().compactMap { failuresByDefinitionCell[$0] }
        return local + (foregroundContext?.definitionDiagnostics ?? [])
    }
    init(page:DiagramPage,binding:VisioPageBinding? = nil,colorPalette:ShapeSheetColorPalette = ShapeSheetColorPalette(),nodesByID:[UUID:DiagramNode]? = nil,identifiers:[String:UUID]? = nil,cancellation:LifecycleJobCancellation? = nil,
         document: Diagram? = nil, foreground: DiagramPage? = nil, now: Date = Date(), mode: ValueMode = .scalarGeometry,
         publicIDsByObject: [UUID: String]? = nil) {
        self.page = page
        pageBinding = binding
        var objects = nodesByID ?? Dictionary(uniqueKeysWithValues:page.nodes.map{($0.id,$0)})
        if nodesByID == nil {
            for edge in page.edges { objects[edge.id] = ConnectorSheetHost.node(edge,in:page,nodesByID:objects) }
        }
        nodes = objects
        self.colorPalette = colorPalette
        self.cancellation = cancellation
        self.document = document; self.foreground = foreground; self.now = now; self.mode = mode
        if let publicIDsByObject { self.publicIDsByObject = publicIDsByObject }
        else if let identifiers { self.publicIDsByObject = Dictionary(identifiers.map { ($0.value, $0.key) }, uniquingKeysWith: { first,_ in first }) }
        else { self.publicIDsByObject = CalculationDependencyIndex.publicIDs(page:page,binding:binding) }
        if let identifiers { self.identifiers = identifiers }
        else {
            for id in page.nodes.map(\.id) + page.edges.map(\.id) {
                if let key = self.publicIDsByObject[id], self.identifiers[key] == nil { self.identifiers[key] = id }
            }
        }
    }
    func target(_ reference:String,from id:UUID) throws -> (UUID,String) {
        guard let mark = reference.firstIndex(of:"!") else { return (id,reference) }
        let owner = String(reference[..<mark]),key = String(reference[reference.index(after:mark)...])
        if owner.caseInsensitiveCompare("ThePage") == .orderedSame { return (page.id, key) }
        if owner.caseInsensitiveCompare("TheDoc") == .orderedSame, let sheet = document?.definitions?.documentSheet { return (sheet.id, key) }
        if owner.caseInsensitiveCompare("ParentShape") == .orderedSame,let parent = nodes[id]?.parentID { return (parent,key) }
        if owner.caseInsensitiveCompare("ParentShape") == .orderedSame, let parent = definitionSheet(id)?.parentID { return (parent,key) }
        if owner.uppercased().hasPrefix("SHEET."), definitionSheet(id) != nil {
            let keyID = String(owner.dropFirst(6))
            guard let target = definitionScopes[id]?[keyID] ?? UInt32(keyID).flatMap({ definitionScopes[id]?[String($0)] }) else {
                throw DiagramError.invalid("Unknown definition sheet reference: \(reference).")
            }
            return (target, key)
        }
        guard owner.uppercased().hasPrefix("SHEET."),let target = identifiers[String(owner.dropFirst(6))] ?? UInt32(owner.dropFirst(6)).flatMap({identifiers[String($0)]}) else { throw DiagramError.invalid("Unknown ShapeSheet reference: \(reference).") };return (target,key)
    }
    func number(_ id:UUID,_ reference:String) throws -> Double { try value(id,reference).numeric() }
    func value(_ id:UUID,_ reference:String) throws -> SheetValue {
        try cancellation?.check()
        measuredWork.cellRequests += 1
        let (id,key) = try target(reference,from:id)
        if id == page.id { return try pageValue(key, from: page.id) }
        if nodes[id] == nil, let sheet = definitionSheet(id) { return try definitionValue(sheet, key) }
        steps += 1;guard steps < 100000,visiting.count < 64 else { throw DiagramError.invalid("ShapeSheet dependency limit exceeded.") }
        if let value = referenceCache[id]?[key] { return value }
        guard let node = nodes[id] else { throw DiagramError.invalid("ShapeSheet dependency limit exceeded.") }
        let canonical:String
        if let (c,axis) = ControlGeometry.address(key,on:node) { canonical = "Controls."+node.formatting.controls[c].name+"."+axis }
        else { canonical = sheetKey(key,on:node) ?? key }
        let token = id.uuidString+"!"+canonical.lowercased()
        if let value = cache[token] { referenceCache[id,default:[:]][key] = value;return value };guard visiting.insert(token).inserted else { throw DiagramError.invalid("Circular ShapeSheet dependency at \(canonical).") };defer { visiting.remove(token) }
        measuredWork.evaluatedCells += 1
        PerformanceEvidence.count(.evaluatedCells)
        let result:SheetValue
        if canonical.caseInsensitiveCompare("TheText") == .orderedSame { result = .string(node.text) }
        else {
            let property = canonical.lowercased().hasPrefix("prop.") ? node.formatting.data.first{$0.key.caseInsensitiveCompare(String(canonical.dropFirst(5))) == .orderedSame} : nil
            let cell = node.formatting.sheet[canonical] ?? fieldCell(canonical,on:node) ?? ConnectionGeometry.cell(canonical,on:node) ?? GeometrySheet.cell(canonical,on:node) ?? ControlGeometry.cell(canonical,on:node)
            if let formula = cell?.formula,!formula.isEmpty,!["INH","NO FORMULA"].contains(formula.uppercased()) { result = try evaluate(formula,on:id,hostCell:canonical) }
            else if let property {
                let stored = mode == .typedFields ? property.value : cell?.value ?? property.value
                if property.type == 3 { result = .boolean(stored == "1" || stored.uppercased() == "TRUE") }
                else if property.type == 5,let date = FieldFormatting.date(stored) { result = .date(date) }
                else if [2,6,7].contains(property.type),let number = Double(stored),number.isFinite { result = numericValue(number, unit: cell?.unit ?? "") }
                // A type 0 value Visio stored without STR is a number (CELLREF-6).
                else if property.type == 0,let unit = property.valueUnit,unit.uppercased() != "STR",let number = Double(stored),number.isFinite { result = numericValue(number, unit: unit) }
                else { result = .string(stored) }
            } else if let cell {
                result = literalValue(cell, key: canonical)
            } else if canonical.caseInsensitiveCompare("TxtWidth") == .orderedSame { result = numericValue(try number(id,"Width")*(node.formatting.textBox?.width ?? 1), unit: implicitUnit(canonical)) }
            else if canonical.caseInsensitiveCompare("TxtHeight") == .orderedSame { result = numericValue(try number(id,"Height")*(node.formatting.textBox?.height ?? 1), unit: implicitUnit(canonical)) }
            else if canonical.caseInsensitiveCompare("TxtLocPinX") == .orderedSame { result = numericValue(try number(id,"TxtWidth")/2, unit: implicitUnit(canonical)) }
            else if canonical.caseInsensitiveCompare("TxtLocPinY") == .orderedSame { result = numericValue(try number(id,"TxtHeight")/2, unit: implicitUnit(canonical)) }
            else if let number = defaults(for:node).first(where:{$0.key.caseInsensitiveCompare(canonical) == .orderedSame})?.value { result = numericValue(number, unit: implicitUnit(canonical)) }
            else { throw DiagramError.invalid("Unknown ShapeSheet cell: \(canonical).") }
        };guard result.valid else { throw DiagramError.invalid("Invalid ShapeSheet value.") };cache[token] = result;referenceCache[id,default:[:]][key] = result;return result
    }
    /// Values keep their unit in both modes: geometry needs it for display-unit rounding
    /// (CEILING(...,1) on a millimetre value rounds to whole millimetres), and still reads numbers.
    private func numericValue(_ number: Double, unit: String) -> SheetValue {
        SheetValue.factor(unit) != nil ? .quantity(number,unit) : .number(number)
    }
    /// A drawing-unit (DL) value shown in this page's drawing unit.
    func displayValue(_ value: SheetValue) -> SheetValue {
        guard case .quantity(let number, let unit) = value, unit.uppercased() == "DL" else { return value }
        return .quantity(number, page.drawingScale?.drawingUnit ?? "IN")
    }
    private func implicitUnit(_ key: String) -> String {
        if ["Angle","TxtAngle"].contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) { return "RAD" }
        if ["PageWidth","PageHeight"].contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) { return page.drawingScale?.drawingUnit ?? "IN" }
        // Geometry cells stored without a unit are Visio drawing units (DL): they display in the
        // drawing's unit but round in internal units (ROUNDING-16).
        if (ShapeSheetEngine.geometryKeys + ShapeSheetEngine.textKeys).contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame && $0 != "VerticalAlign" }) {
            return "DL"
        }
        return ""
    }
    private func literalValue(_ cell: ShapeSheetCell, key: String) -> SheetValue {
        let unit = cell.unit.uppercased()
        if unit == "STR" || ["PROMPT","TIP"].contains(key.split(separator:".").last.map(String.init)?.uppercased() ?? "") { return .string(cell.value) }
        if unit == "BOOL" { return .boolean(cell.value == "1" || cell.value.uppercased() == "TRUE") }
        if unit == "DATE", let date = FieldFormatting.date(cell.value) { return .date(date) }
        if let color = literalColor(cell,key:key) { return .color(color) }
        if let number = Double(cell.value), number.isFinite { return numericValue(number,unit: unit.isEmpty ? implicitUnit(key) : unit) }
        return .string(cell.value)
    }
    private func fieldCell(_ key: String, on node: DiagramNode) -> ShapeSheetCell? {
        guard key.lowercased().hasPrefix("fields.value["), key.hasSuffix("]"),
              let number = UInt32(key.dropFirst(13).dropLast()), number > 0 else { return nil }
        return node.formatting.textFields?.first { $0.index == Int(number)-1 }?.cells["Value"]
    }
    private func definitionSheet(_ id: UUID) -> DefinitionSheet? {
        if let sheet = document?.definitions?.documentSheet, sheet.id == id { return sheet }
        if nodes[id] != nil || id == page.id { return nil }
        if definitionSheets == nil {
            var sheets: [UUID: DefinitionSheet] = [:]
            for definition in (document?.definitions?.masters ?? []) + (document?.definitions?.styles ?? []) {
                let scope = Dictionary(definition.sheets.map { ($0.publicID,$0.id) }, uniquingKeysWith: { first,_ in first })
                for sheet in definition.sheets { sheets[sheet.id] = sheet; definitionScopes[sheet.id] = scope }
            }
            definitionSheets = sheets
        }
        return definitionSheets?[id]
    }
    private func definitionValue(_ sheet: DefinitionSheet, _ reference: String) throws -> SheetValue {
        steps += 1
        guard steps < 100000, visiting.count < 64 else { throw DiagramError.invalid("ShapeSheet dependency limit exceeded.") }
        if definitionCells[sheet.id] == nil { definitionCells[sheet.id] = try DefinitionSheetReferences.cells(sheet) }
        guard let cell = definitionCells[sheet.id]?[reference.lowercased()] else { throw DiagramError.invalid("Unknown definition cell: \(reference).") }
        let token = sheet.id.uuidString + "!" + cell.address.key
        if let value = cache[token] { return value }
        guard visiting.insert(token).inserted else { throw DiagramError.invalid("Circular ShapeSheet dependency at \(reference).") }
        defer { visiting.remove(token) }
        measuredWork.evaluatedCells += 1; PerformanceEvidence.count(.evaluatedCells)
        do {
            let result = try evaluate(cell.value,on:sheet.id,hostCell:reference)
            guard result.valid else { throw DiagramError.invalid("Invalid definition cell value.") }
            cache[token] = result
            return result
        } catch {
            let registry = document?.definitions
            let owner = ((registry?.masters ?? []) + (registry?.styles ?? [])).first { $0.sheets.contains { $0.id == sheet.id } }
            failuresByDefinitionCell[token] = DocumentDiagnostic(code: "calculation.definition.cell",
                origin: .calculation, severity: .warning, dimension: .behavior,
                target: .definition(sheet: sheet.id),
                source: .init(part: owner?.part ?? registry?.documentPart, visioID: sheet.publicID,
                    cell: reference, definitionCell: cell.address, feature: "definition-sheet"),
                displayState: .cached, message: error.localizedDescription,
                requestedActions: [.viewDetails, .revealTarget, .inspectCell])
            throw error
        }
    }
    private func defaults(for node:DiagramNode) -> [String:Double] {
        if let values = defaultsCache[node.id] { return values }
        let values = ShapeSheetEngine.defaults(node,page:page,nodesByID:nodes,onDefaultPinFormulaEvaluation:{self.measuredWork.defaultPinFormulaEvaluations += 1})
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
    /// A page sheet cell (ThePage!reference), evaluated from its formula when it has one.
    func pageCellValue(_ reference:String) throws -> SheetValue { try pageValue(reference,from:page.id) }
    private func pageValue(_ reference:String,from host:UUID) throws -> SheetValue {
        if let foreground, foreground.id != page.id {
            if foregroundContext == nil {
                foregroundContext = ShapeSheetContext(page: foreground,
                    binding: document?.visioArchive?.pages.first { $0.pageID == foreground.id },
                    colorPalette: colorPalette, cancellation: cancellation, document: document, now: now, mode: mode)
            }
            return try foregroundContext!.value(foreground.id, reference)
        }
        steps += 1
        guard steps < 100000,visiting.count < 64 else { throw DiagramError.invalid("ShapeSheet dependency limit exceeded.") }
        let page = foreground ?? self.page
        let storedKey = page.sheet?.keys.first{$0.caseInsensitiveCompare(reference) == .orderedSame}
        let key = storedKey ?? reference
        let token = page.id.uuidString+"!"+key.lowercased()
        if let value = cache[token] { return value }
        guard visiting.insert(token).inserted else { throw DiagramError.invalid("Circular ShapeSheet dependency at ThePage!\(key).") }
        defer { visiting.remove(token) }
        measuredWork.evaluatedCells += 1
        PerformanceEvidence.count(.evaluatedCells)

        let cell = storedKey.flatMap{page.sheet?[$0]}
        let formula = cell?.formula.trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
        let result:SheetValue
        if !formula.isEmpty && !["INH","NO FORMULA"].contains(formula.uppercased()) {
            result = try evaluate(expression(formula),on:self.page.id,host:.page(key))
        } else if let cell {
            result = literalValue(cell,key:key)
        } else {
            let values = ["pagewidth":page.width/72,"pageheight":page.height/72,"pagescale":page.drawingScale?.page ?? 1,"drawingscale":page.drawingScale?.drawing ?? 1]
            guard let number = values[key.lowercased()] else { throw DiagramError.invalid("Unknown page cell: ThePage!\(reference).") }
            result = numericValue(number,unit:["pagewidth","pageheight"].contains(key.lowercased()) ? page.drawingScale?.drawingUnit ?? "IN" : "")
        }
        guard result.valid else { throw DiagramError.invalid("Invalid ShapeSheet page value.") }
        cache[token] = result
        return result
    }
    func evaluate(_ formula:String,on id:UUID) throws -> SheetValue {
        try evaluate(expression(formula),on:id,host:.shape(id,nil))
    }
    func evaluate(_ cell: ShapeSheetCell, on id: UUID, hostCell: String? = nil) throws -> SheetValue {
        let formula = cell.formula.trimmingCharacters(in:.whitespacesAndNewlines)
        if formula.isEmpty || ["INH","NO FORMULA"].contains(formula.uppercased()) { return literalValue(cell,key:hostCell ?? "") }
        return try evaluate(formula,on:id,hostCell:hostCell)
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
        try cancellation?.check()
        measuredWork.formulaEvaluations += 1
        return try TypedShapeSheet.evaluate(expression,resolve:{try self.value(id,$0)},call:{name,values in try self.contextFunction(name,values:values,id:id)},scalar:mode == .scalarGeometry,specialCall:{name,args,eval in
            if name == "THEMEVAL" {
                guard args.count <= 2 else { throw DiagramError.invalid("THEMEVAL accepts at most two arguments.") }
                if let value = try self.noThemeValue(args,host:host,evaluate:eval) { return value }
                let colorSelector:ThemeColorSelector?
                let lineSelector:ThemeLineSelector?
                if let value = try self.quickStyleThemeValue(args,host:host,evaluate:eval) { return value }
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
                // 65534 follows the page's scheme; a page without one (or 0) has no theme (ISTHEMED-1).
                var index = try self.value(id,"ColorSchemeIndex").numeric()
                if index == 65534 { index = Double(self.cellsValue(self.page.sheet,"ColorSchemeIndex") ?? 0) }
                return .boolean(index > 0 && index != 65534)
            }
            if let value = try self.referencePathFunction(name, arguments: args, evaluate: eval, id: id) { return value }
            guard ["SHAPETEXT","TEXTWIDTH","TEXTHEIGHT"].contains(name) else { return nil }
            // Visio 2019 requires TEXTHEIGHT's maximum width (TEXTHEIGHT-1 is rejected).
            guard name != "TEXTHEIGHT" || args.count == 2 else { throw DiagramError.invalid("TEXTHEIGHT expects a TheText reference and a maximum width.") }
            guard (1...2).contains(args.count) else { throw DiagramError.invalid("\(name) requires a TheText reference and an optional parameter.") }
            // Anything but a cell reference measures no text (VEC-SHAPETEXT-text, VEC-TEXTWIDTH-length).
            guard case .reference(let reference) = args[0] else {
                guard name != "TEXTHEIGHT" else { throw DiagramError.invalid("TEXTHEIGHT requires a TheText reference.") }
                _ = try eval(args[0])  // an error argument still propagates (VEC-SHAPETEXT-error)
                return name == "SHAPETEXT" ? .string("") : .quantity(0,"DL")
            }
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
            self.measuredWork.textMeasurements += 1
            let maximum = args.count == 2 ? try eval(args[1]).numeric() : name == "TEXTHEIGHT" ? try self.number(owner,"TxtWidth") : nil
            let metrics = try ShapeTextFunctions.metrics(node,page:self.page,maximumWidth:maximum,cancellation:self.cancellation)
            // Visio returns a length in the drawing's unit (ARIAL-*, METRIC-*).
            return .quantity(name == "TEXTWIDTH" ? metrics.width : metrics.height,"DL")
        },colorPalette:colorPalette)
    }
    private func contextFunction(_ name: String, values: [SheetValue], id: UUID) throws -> SheetValue {
        // A sheet-qualified call such as Sheet.1!ID() evaluates on that sheet (ID-2).
        if let mark = name.lastIndex(of: "!") {
            // Visio accepts a sheet qualifier only on argument-free functions (GEOM-5/7 are rejected).
            guard values.isEmpty else { throw DiagramError.invalid("\(name) cannot take a sheet qualifier (#NAME?).") }
            let (owner, _) = try target(String(name[..<mark]) + "!PinX", from: id)
            return try contextFunction(String(name[name.index(after: mark)...]), values: values, id: owner)
        }
        func arity(_ count: Int) throws {
            guard values.count == count else { throw DiagramError.invalid("\(name) expects \(count) arguments.") }
        }
        let context = foreground ?? page
        let pages = document?.pages ?? [page]
        switch name {
        case "PAGENAME":
            // Visio shows nothing for surplus or text arguments (VEC-PAGENAME-many, VEC-PAGENAME-text).
            if values.count > 1 || values.first.map({ if case .string = $0 { return true }; return false }) == true { return .string("") }
            return .string(context.name)
        case "PAGENUMBER":
            // Visio returns 0 whenever an argument is supplied (reference cases PAGENUMBER-2, EXPR-53/54).
            guard values.count <= 1 else { throw DiagramError.invalid("PAGENUMBER expects at most one argument.") }
            if values.count == 1 { return .number(0) }
            return .number(context.isBackground == true ? 0 : Double((pages.filter { $0.isBackground != true }.firstIndex { $0.id == context.id } ?? -1)+1))
        case "PAGECOUNT": try arity(0); return .number(Double(pages.filter { $0.isBackground != true }.count))
        case "BKGPAGENAME":
            if values.count > 1 || values.first.map({ if case .string = $0 { return true }; return false }) == true { return .string("") }
            return .string(pages.first { $0.id == context.backgroundPageID }?.name ?? "<no background>")  // BKGPAGENAME-1
        case "ID":
            try arity(0)
            guard let key = publicIDsByObject[id] ?? definitionSheet(id)?.publicID,
                  let value = Double(key), value.isFinite else { throw DiagramError.invalid("Invalid shape ID; this owner has no numeric public identifier.") }
            return .number(value)
        // Evaluation never runs actions: OPENTEXTWIN is FALSE, GETREF yields the referenced value and
        // SETF returns 0 without writing (Visio applies SETF only as an action).
        case "OPENTEXTWIN": try arity(0); return .boolean(false)
        case "GETREF": try arity(1); return values[0]
        case "SETF": try arity(2); return .number(0)
        case "POLYLINE":
            guard values.count >= 2, values.count % 2 == 0 else { throw DiagramError.invalid("POLYLINE expects x and y types followed by point pairs.") }
            let flags = try values[0..<2].map { String(Int(try $0.numeric())) }
            let points = try stride(from: 2, to: values.count, by: 2).map { String(format: "%.4f,%.4f", try values[$0].numeric(), try values[$0+1].numeric()) }
            return .string("POLYLINE(" + (flags + points).joined(separator: ", ") + ")")
        case "NOW": try arity(0); return .date(now)
        case "TODAY": try arity(0); return .date(Calendar(identifier:.gregorian).startOfDay(for:now))
        case "DATE":
            try arity(3)
            let numbers = try values.map { try $0.numeric() }
            guard numbers.allSatisfy({ $0.isFinite && abs($0) < 10000 }),
                  let date = Calendar(identifier:.gregorian).date(from:DateComponents(year:Int(numbers[0]),month:Int(numbers[1]),day:Int(numbers[2]))) else {
                throw DiagramError.invalid("Invalid date.")
            }
            return .date(date)
        case "FORMAT": try arity(2); return .string(try VisioPictureFormat.format(displayValue(values[0]),picture:values[1].text))
        default:
            if let value = try referenceFunction(name, values: values, id: id) { return value }
            throw DiagramError.invalid("Unsupported ShapeSheet function: \(name).")
        }
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

    enum QuickStylePart { case fill, line, font }

    /// THEMEVAL() in a fill, line or text color cell, and the FillColor/LineColor/TextColor/ConnectorColor
    /// selectors, resolve through the shape's quick style when a theme is active (quick-style reference).
    private func quickStyleThemeValue(_ args:[ShapeSheet.Expression],host:FormulaHost,evaluate:(ShapeSheet.Expression) throws -> SheetValue) throws -> SheetValue? {
        guard case .active(let theme) = colorThemeState(for:host) else { return nil }
        let part:QuickStylePart,connector:Bool
        if let first = args.first {
            guard case .string(let name) = try evaluate(first) else { return nil }
            switch name.lowercased() {
            case "fillcolor": (part,connector) = (.fill,false)
            case "linecolor": (part,connector) = (.line,false)
            case "textcolor": (part,connector) = (.font,isConnectorHost(host))
            case "connectorcolor": (part,connector) = (.line,true)
            default: return nil
            }
        } else {
            switch hostCell(for:host)?.lowercased() {
            case "fillforegnd": (part,connector) = (.fill,false)
            case "linecolor": (part,connector) = (.line,isConnectorHost(host))
            case "char.color": (part,connector) = (.font,isConnectorHost(host))
            default: return nil
            }
        }
        return try quickStyleColor(part,connector:connector,host:host,theme:theme).map { .color($0) }
    }

    private func isConnectorHost(_ host:FormulaHost) -> Bool {
        guard case .shape(let id,_) = host else { return false }
        return page.edges.contains { $0.id == id } || literalIndex(nodes[id]?.formatting.sheet,"QuickStyleType") == 3
    }

    /// The theme color a shape's quick style gives one part, or nil without an active, imported theme.
    func themedColor(_ part:QuickStylePart,for id:UUID) -> ShapeSheetColor? {
        let host = FormulaHost.shape(id,nil)
        guard case .active(let theme) = colorThemeState(for:host) else { return nil }
        return try? quickStyleColor(part,connector:isConnectorHost(host),host:host,theme:theme)
    }

    private func quickStyleColor(_ part:QuickStylePart,connector:Bool,host:FormulaHost,theme:VisioTheme) throws -> ShapeSheetColor? {
        let cells:[String:ShapeSheetCell]?
        switch host {
        case .shape(let id,_): cells = nodes[id]?.formatting.sheet
        case .page: cells = page.sheet
        }
        let name = part == .fill ? "Fill" : part == .line ? "Line" : "Font"
        guard let matrix = literalIndex(cells,"QuickStyle\(name)Matrix") ?? (part == .line ? nil : 100),
              let colorIndex = literalIndex(cells,"QuickStyle\(name)Color") ?? Optional(100) else { return nil }
        // Matrix 0 is the root (classic) style: white fill, black line and text.
        if matrix == 0 { return part == .fill ? ShapeSheetColor(red:255,green:255,blue:255) : ShapeSheetColor(red:0,green:0,blue:0) }
        var selected = matrix
        if (100...103).contains(matrix) {
            let variation = try variationIndex("VariationStyleIndex",for:host,theme:theme)
            guard let style = theme.variationStyleSchemes[variation]?.styles[safe:matrix-100] else { return nil }
            selected = (part == .fill ? style.fillIndex : part == .line ? style.lineIndex : style.fontIndex) ?? 0
        }
        let list = part == .fill ? theme.fillPaints : part == .line ? (connector ? theme.connectorLinePaints : theme.linePaints) : (connector ? theme.connectorFontPaints : theme.fontPaints)
        guard let paints = list,paints.indices.contains(selected-1) else { return nil }
        guard case .color(let placeholder) = try themeValue(index:colorIndex,in:theme,quickStyle:true) else { return nil }
        guard let resolved = try resolve(paints[selected-1],placeholder:placeholder,theme:theme) else { return nil }
        // QuickStyleVariation bit 2 keeps text legible: light text takes the darker of the shape's line
        // and fill colors (quick-style reference, variation=2/3 in three themes).
        if part == .font,let variation = literalIndex(cells,"QuickStyleVariation"),variation & 2 != 0,resolved.hsl.luminosity > 168,
           let line = try quickStyleColor(.line,connector:connector,host:host,theme:theme),let fill = try quickStyleColor(.fill,connector:false,host:host,theme:theme) {
            return line.hsl.luminosity <= fill.hsl.luminosity ? line : fill
        }
        return resolved
    }

    private func resolve(_ paint:VisioThemePaint,placeholder:ShapeSheetColor,theme:VisioTheme) throws -> ShapeSheetColor? {
        if paint.gradient { return placeholder }
        var color:ShapeSheetColor
        switch paint.base {
        case "none": return nil
        case "phClr": color = placeholder
        case let hex where hex.hasPrefix("#"): guard let value = ShapeSheetColor(hex:hex) else { return nil };color = value
        default:
            let slots = ["dk1":"Dark","lt1":"Light","tx1":"Dark","bg1":"Light","dk2":"Dark2","lt2":"Light2","tx2":"Dark2","bg2":"Light2"]
            let key = slots[paint.base] ?? (paint.base.hasPrefix("accent") ? "AccentColor"+paint.base.dropFirst(6) : paint.base)
            guard let hex = theme.colors.first(where:{$0.key.caseInsensitiveCompare(key) == .orderedSame})?.value,let value = ShapeSheetColor(hex:hex) else { return nil }
            color = value
        }
        return ThemeColorMath.apply(paint.modifiers,to:color)
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
        } else if quickStyle,(100...106).contains(index) || (200...206).contains(index) {
            // A monotone variation uses its first color for every variant selector (flowchart reference:
            // QuickStyleFillColor 102 resolves to varColor1 in the Office theme's monotone variation).
            let variation = theme.variationColorIndex ?? 0
            name = theme.variationColorSchemeMonotone[variation] == true ? "VariantColor1" : "VariantColor\(index % 100 + 1)"
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

    /// Visio's values for a drawing with no theme applied (THEMEVALX reference cases). An explicit
    /// default argument wins; selectors Visio cannot resolve without a theme are #VALUE!.
    private func noThemeValue(_ args:[ShapeSheet.Expression],host:FormulaHost,evaluate:(ShapeSheet.Expression) throws -> SheetValue) throws -> SheetValue? {
        // Only when the host's effective scheme is "no theme": an explicit 0, or nothing selected on a
        // page without a theme. A selected theme that was not imported stays unavailable.
        let own:ShapeSheetCell?
        switch host {
        case .shape(let id,_): own = nodes[id]?.formatting.sheet.first { $0.key.caseInsensitiveCompare("ColorSchemeIndex") == .orderedSame }?.value
        case .page: own = page.sheet?.first { $0.key.caseInsensitiveCompare("ColorSchemeIndex") == .orderedSame }?.value
        }
        let explicit = own.flatMap { $0.formula.caseInsensitiveCompare("Inh") == .orderedSame ? nil : Double($0.value) }
        // An explicit 0 is "no theme"; otherwise only a page without an imported theme or scheme is.
        let noTheme = explicit == 0 || (explicit == nil || explicit == 65534) && page.theme == nil && (cellsValue(page.sheet,"ColorSchemeIndex") ?? 0) == 0
        guard noTheme else { return nil }
        if args.count == 2 { return try evaluate(args[1]) }
        func rgb(_ r:Int,_ g:Int,_ b:Int) -> SheetValue { .color(ShapeSheetColor(red:r,green:g,blue:b)) }
        let palette = [rgb(0,0,0),rgb(255,255,255),rgb(192,80,70),rgb(157,187,97),rgb(171,154,192),rgb(75,172,198),rgb(245,157,86),rgb(255,192,0)]
        let named:[String:SheetValue] = ["fillcolor":rgb(150,175,207),"fillcolor2":rgb(191,206,225),"linecolor":rgb(31,71,125),"shadowcolor":rgb(70,70,70),
            "lineweight":.quantity(0.75/72,"PT"),"connectorweight":.quantity(0.75/72,"PT"),"linecap":.number(0),"linepattern":.number(1),"fillpattern":.number(1),
            "shadowpattern":.number(0),"dark":palette[0],"light":palette[1],"textcolor":palette[0]]
        let selector:String
        if let first = args.first {
            let value = try evaluate(first)
            if case .string(let text) = value { selector = text.lowercased() }
            else {
                let index = Int(try value.numeric())
                guard palette.indices.contains(index) else { throw ShapeSheetError(kind:.value,message:"THEMEVAL color index is outside the no-theme palette (#VALUE!).") }
                return palette[index]
            }
        } else {
            // THEMEVAL() in a host cell gives Visio's classic defaults without a theme: black line and
            // text, white fill, 0.75 pt, solid patterns (round-trip snapshot, intelligent drawing).
            let cell = hostCell(for:host)?.lowercased() ?? ""
            let hostDefaults:[String:SheetValue] = ["linecolor":palette[0],"fillforegnd":palette[1],"fillbkgnd":palette[0],"char.color":palette[0],
                "lineweight":.quantity(0.75/72,"PT"),"linepattern":.number(1),"fillpattern":.number(1),"shdwpattern":.number(0),"linecap":.number(0)]
            guard let value = hostDefaults[cell] else { throw ShapeSheetError(kind:.na,message:"THEMEVAL() has no theme value for this cell (#N/A).") }
            return value
        }
        guard let value = named[selector] else { throw ShapeSheetError(kind:.value,message:"THEMEVAL \(selector) needs an applied theme (#VALUE!).") }
        return value
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

/// DrawingML color modifiers. shade and tint work in linear light (shade 75% of RGB(70,114,196) is
/// RGB(61,100,172), as Visio reports); luminance and saturation modifiers work in HSL.
enum ThemeColorMath {
    static func apply(_ modifiers:[VisioThemeColorModifier],to color:ShapeSheetColor) -> ShapeSheetColor {
        func linear(_ v:Double) -> Double { v <= 0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4) }
        func gamma(_ v:Double) -> Double { let c = max(0,min(1,v));return c <= 0.0031308 ? c*12.92 : 1.055*pow(c,1/2.4)-0.055 }
        // sRGB components in 0...1, kept unrounded between modifiers.
        var rgb = [Double(color.red)/255,Double(color.green)/255,Double(color.blue)/255]
        for modifier in modifiers {
            switch modifier.name {
            case "shade": rgb = rgb.map { gamma(linear($0)*modifier.value) }
            case "tint": rgb = rgb.map { gamma(linear($0)*modifier.value+(1-modifier.value)) }
            case "lumMod","lumOff","satMod":
                // DrawingML keeps HSL in 1/100000 units (quick-style reference, Integral theme).
                func unit(_ v:Double) -> Double { (v*100000).rounded()/100000 }
                var (h,s,l) = hsl(rgb);h = unit(h);s = unit(s);l = unit(l)
                if modifier.name == "lumMod" { l *= modifier.value } else if modifier.name == "lumOff" { l += modifier.value } else { s *= modifier.value }
                rgb = fromHSL(h,max(0,min(1,unit(s))),max(0,min(1,unit(l))))
            default: break  // alpha and other modifiers do not change the RGB value
            }
        }
        let channels = rgb.map { Int(($0*255).rounded()) }
        return ShapeSheetColor(red:channels[0],green:channels[1],blue:channels[2])
    }
    private static func hsl(_ c:[Double]) -> (Double,Double,Double) {
        let maxV = c.max()!,minV = c.min()!,l = (maxV+minV)/2
        guard maxV != minV else { return (0,0,l) }
        let d = maxV-minV,s = l > 0.5 ? d/(2-maxV-minV) : d/(maxV+minV)
        let h = maxV == c[0] ? (c[1]-c[2])/d+(c[1] < c[2] ? 6 : 0) : maxV == c[1] ? (c[2]-c[0])/d+2 : (c[0]-c[1])/d+4
        return (h/6,s,l)
    }
    private static func fromHSL(_ h:Double,_ s:Double,_ l:Double) -> [Double] {
        guard s > 0 else { return [l,l,l] }
        let q = l < 0.5 ? l*(1+s) : l+s-l*s,p = 2*l-q
        func channel(_ t0:Double) -> Double { var t = t0;if t < 0 { t += 1 };if t > 1 { t -= 1 }
            return t < 1.0/6 ? p+(q-p)*6*t : t < 0.5 ? q : t < 2.0/3 ? p+(q-p)*(2.0/3-t)*6 : p }
        return [channel(h+1.0/3),channel(h),channel(h-1.0/3)]
    }
}

extension Array { subscript(safe index:Int) -> Element? { indices.contains(index) ? self[index] : nil } }
