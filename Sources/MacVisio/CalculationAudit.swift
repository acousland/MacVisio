import Foundation

/// Measures formula coverage over authored ShapeSheet cells. This is a parser and
/// evaluator audit, not a substitute for running the same workbook in Visio.
enum CalculationAudit {
    private struct Totals {
        var formulas = 0
        var evaluated = 0
        var failed = 0
        var parseFailures = 0
        var functions: [String:Int] = [:]
        var sections: [String:Int] = [:]
        var failures: [String:Int] = [:]

        mutating func merge(_ other:Totals) {
            formulas += other.formulas;evaluated += other.evaluated;failed += other.failed;parseFailures += other.parseFailures
            for (key,value) in other.functions { functions[key,default:0] += value }
            for (key,value) in other.sections { sections[key,default:0] += value }
            for (key,value) in other.failures { failures[key,default:0] += value }
        }
    }

    /// A package-wide inventory keeps formulas in masters and document styles
    /// visible even when the page evaluator cannot give them a faithful host
    /// context. These counts are syntax inventory only, not evaluated results.
    private struct PackageInventory {
        var formulaCells = 0
        var parsedFormulas = 0
        var formulaParseFailures = 0
        var xmlParts = 0
        var malformedXMLParts = 0
        var byPartRole:[String:Int] = [:]
        var functions:[String:Int] = [:]

        mutating func merge(_ other:PackageInventory) {
            formulaCells += other.formulaCells;parsedFormulas += other.parsedFormulas
            formulaParseFailures += other.formulaParseFailures;xmlParts += other.xmlParts
            malformedXMLParts += other.malformedXMLParts
            for (key,value) in other.byPartRole { byPartRole[key,default:0] += value }
            for (key,value) in other.functions { functions[key,default:0] += value }
        }

        mutating func inspect(_ parts:[String:Data]) {
            for (name,data) in parts where name.lowercased().hasSuffix(".xml") {
                xmlParts += 1
                let root:XMLElement
                do {
                    let document = try VisioXML.document(data)
                    guard let parsedRoot = document.rootElement() else { throw DiagramError.invalid("Missing XML root.") }
                    root = parsedRoot
                }
                catch { malformedXMLParts += 1;continue }
                let role = Self.role(for:name)
                func walk(_ element:XMLElement) {
                    if element.localTag == "Cell",let formula = element.attr("F") {
                        let source = formula.trimmingCharacters(in:.whitespacesAndNewlines)
                        if !source.isEmpty && !["INH","NO FORMULA"].contains(source.uppercased()) {
                            formulaCells += 1;byPartRole[role,default:0] += 1
                            do { collectFunctions(try ShapeSheet.parse(source),into:&functions);parsedFormulas += 1 }
                            catch { formulaParseFailures += 1 }
                        }
                    }
                    for child in (element.children ?? []).compactMap({$0 as? XMLElement}) { walk(child) }
                }
                walk(root)
            }
        }

        var report:[String:Any] { [
            "xmlParts":xmlParts,
            "malformedXMLParts":malformedXMLParts,
            "formulaCells":formulaCells,
            "parsedFormulas":parsedFormulas,
            "formulaParseFailures":formulaParseFailures,
            "formulaCellsByPartRole":byPartRole,
            "functionCalls":functions,
            "scope":"Syntax inventory only across XML package parts; formulas are not evaluated here."
        ] }

        private static func role(for part:String) -> String {
            let key = part.lowercased()
            if key == "visio/document.xml" { return "documentAndStyles" }
            if key.hasPrefix("visio/pages/") { return "pages" }
            if key.hasPrefix("visio/masters/") { return "masters" }
            if key.hasPrefix("visio/theme/") || key.hasPrefix("visio/themes/") { return "themes" }
            return "other"
        }
    }

    private struct FileAudit {
        var totals:Totals
        var packageInventory:PackageInventory
    }

    static func inspect(_ input:URL,to output:URL) throws {
        let files:[URL]
        if (try? input.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true {
            let supported:Set<String> = ["vsdx","vsd","vssx","vss","vstx","vst"]
            guard let enumerator = FileManager.default.enumerator(at:input,includingPropertiesForKeys:[.isRegularFileKey],options:[.skipsHiddenFiles]) else { throw DiagramError.invalid("Unable to scan the requested ShapeSheet audit directory.") }
            files = enumerator.compactMap{$0 as? URL}
                .filter{supported.contains($0.pathExtension.lowercased())}
                .sorted{$0.path.localizedStandardCompare($1.path) == .orderedAscending}
        } else { files = [input] }

        var total = Totals(),packageInventory = PackageInventory(),perFile:[[String:Any]] = []
        for file in files {
            do {
                let result = try inspect(file)
                total.merge(result.totals);packageInventory.merge(result.packageInventory)
                perFile.append(["file":file.lastPathComponent,"formulaCells":result.totals.formulas,"evaluated":result.totals.evaluated,"failed":result.totals.failed,"parseFailures":result.totals.parseFailures])
            } catch {
                perFile.append(["file":file.lastPathComponent,"loadError":error.localizedDescription])
                total.failures["File load: \(error.localizedDescription)",default:0] += 1
            }
        }
        let report:[String:Any] = [
            "source":input.lastPathComponent,
            "filesScanned":files.count,
            "formulaCells":total.formulas,
            "evaluated":total.evaluated,
            "failed":total.failed,
            "parseFailures":total.parseFailures,
            "functions":total.functions,
            "formulaCellsBySection":total.sections,
            "failuresByMessage":total.failures,
            "packageFormulaInventory":packageInventory.report,
            "files":perFile,
            "scope":"Evaluates imported shape, geometry, connection, control, User, and Property formulas against cached page snapshots. A separate packageFormulaInventory counts and parses formulas in all package XML parts, including masters and styles, without claiming those formulas were evaluated. Neither scope proves Windows or full stencil behavior.",
            "windowsValidated":false,
            "fullBehavioralParity":false
        ]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.atomic)
    }

    private static func inspect(_ input:URL) throws -> FileAudit {
        let pages:[DiagramPage],bindings:[VisioPageBinding],paletteArchive:VisioDocumentArchive?
        let contextDocument: Diagram
        if ["vssx","vss"].contains(input.pathExtension.lowercased()) {
            let stencil = try VisioStencil.readForCalculationAudit(from:input)
            pages = stencil.items.map(\.fragment);bindings = [];paletteArchive = stencil.paletteArchive
            var drawing = Diagram(); drawing.pages = pages; drawing.visioArchive = paletteArchive
            contextDocument = try DefinitionRegistry.hydrate(drawing)
        } else {
            let doc = MacVisioDocument()
            try doc.read(from:input,ofType:input.pathExtension.lowercased() == "vsd" || input.pathExtension.lowercased() == "vst" ? MacVisioDocument.legacyType : MacVisioDocument.visioType)
            pages = doc.diagram.pages;bindings = doc.diagram.visioArchive?.pages ?? [];paletteArchive = doc.diagram.visioArchive
            contextDocument = doc.diagram
        }
        var total = Totals(),packageInventory = PackageInventory();packageInventory.inspect(paletteArchive?.parts ?? [:])
        let colorPalette = ShapeSheetColorPalette(documentArchive:paletteArchive)
        for page in pages {
            let context = ShapeSheetContext(page:page,binding:bindings.first{$0.pageID == page.id},colorPalette:colorPalette,document:contextDocument)
            for node in page.nodes {
                var cells:[String:ShapeSheetCell] = node.formatting.sheet
                for point in node.formatting.connectionPoints { cells[point.xCell] = point.x;cells[point.yCell] = point.y }
                for name in GeometrySheet.names(node.formatting.geometry ?? []) {
                    if let cell = GeometrySheet.cell(name,on:node) { cells[name] = cell }
                }
                for control in node.formatting.controls {
                    for (key,cell) in control.cells { cells["Controls.\(control.name).\(key)"] = cell }
                }
                let unique = Dictionary(cells.map{($0.key.lowercased(),($0.key,$0.value))},uniquingKeysWith:{first,_ in first})
                for (_,entry) in unique.sorted(by:{$0.key < $1.key}) {
                    let (name,cell) = entry
                    guard !cell.formula.isEmpty,!(["INH","NO FORMULA"].contains(cell.formula.trimmingCharacters(in:.whitespacesAndNewlines).uppercased())) else { continue }
                    total.formulas += 1
                    total.sections[section(for:name),default:0] += 1
                    do {
                        let expression = try ShapeSheet.parse(cell.formula)
                        collectFunctions(expression,into:&total.functions)
                        _ = try context.value(node.id,name)
                        total.evaluated += 1
                    } catch {
                        total.failed += 1
                        let message = error.localizedDescription
                        total.failures[message,default:0] += 1
                        if message.localizedCaseInsensitiveContains("unexpected ShapeSheet expression") || message.localizedCaseInsensitiveContains("unclosed ShapeSheet") || message.localizedCaseInsensitiveContains("invalid ShapeSheet") { total.parseFailures += 1 }
                    }
                }
            }
        }
        return FileAudit(totals:total,packageInventory:packageInventory)
    }

    private static func collectFunctions(_ expression:ShapeSheet.Expression,into counts:inout [String:Int]) {
        switch expression {
        case .call(let name,let arguments):
            counts[name.uppercased(),default:0] += 1
            for argument in arguments { collectFunctions(argument,into:&counts) }
        case .unary(_,let child):collectFunctions(child,into:&counts)
        case .binary(_,let lhs,let rhs):collectFunctions(lhs,into:&counts);collectFunctions(rhs,into:&counts)
        case .number,.measure,.string,.reference,.omitted:break
        }
    }

    private static func section(for name:String) -> String {
        let key = name.lowercased()
        if key.hasPrefix("geometry") { return "Geometry" }
        if key.hasPrefix("connections.") { return "Connection" }
        if key.hasPrefix("controls.") { return "Control" }
        if key.hasPrefix("user.") { return "User" }
        if key.hasPrefix("prop.") { return "Property" }
        return "Shape"
    }
}
