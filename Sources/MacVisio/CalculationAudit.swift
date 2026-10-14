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

    static func inspect(_ input:URL,to output:URL) throws {
        let files:[URL]
        if (try? input.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true {
            let supported:Set<String> = ["vsdx","vsd","vssx","vss","vstx","vst"]
            guard let enumerator = FileManager.default.enumerator(at:input,includingPropertiesForKeys:[.isRegularFileKey],options:[.skipsHiddenFiles]) else { throw DiagramError.invalid("Unable to scan the requested ShapeSheet audit directory.") }
            files = enumerator.compactMap{$0 as? URL}
                .filter{supported.contains($0.pathExtension.lowercased())}
                .sorted{$0.path.localizedStandardCompare($1.path) == .orderedAscending}
        } else { files = [input] }

        var total = Totals(),perFile:[[String:Any]] = []
        for file in files {
            do {
                let result = try inspect(file)
                total.merge(result)
                perFile.append(["file":file.lastPathComponent,"formulaCells":result.formulas,"evaluated":result.evaluated,"failed":result.failed,"parseFailures":result.parseFailures])
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
            "files":perFile,
            "scope":"Evaluates imported shape, geometry, connection, control, User, and Property formulas against cached page snapshots; it does not prove Windows or full stencil behavior.",
            "windowsValidated":false,
            "fullBehavioralParity":false
        ]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.atomic)
    }

    private static func inspect(_ input:URL) throws -> Totals {
        let pages:[DiagramPage],bindings:[VisioPageBinding],paletteArchive:VisioDocumentArchive?
        if ["vssx","vss"].contains(input.pathExtension.lowercased()) {
            let stencil = try VisioStencil.readForCalculationAudit(from:input)
            pages = stencil.items.map(\.fragment);bindings = [];paletteArchive = stencil.paletteArchive
        } else {
            let doc = MacVisioDocument()
            try doc.read(from:input,ofType:input.pathExtension.lowercased() == "vsd" || input.pathExtension.lowercased() == "vst" ? MacVisioDocument.legacyType : MacVisioDocument.visioType)
            pages = doc.diagram.pages;bindings = doc.diagram.visioArchive?.pages ?? [];paletteArchive = doc.diagram.visioArchive
        }
        var total = Totals();let colorPalette = ShapeSheetColorPalette(documentArchive:paletteArchive)
        for page in pages {
            let context = ShapeSheetContext(page:page,binding:bindings.first{$0.pageID == page.id},colorPalette:colorPalette)
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
        return total
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
