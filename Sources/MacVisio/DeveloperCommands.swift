import AppKit
import MacVisioInfrastructure

/// Tooling dispatch extracted from the existing CLI blocks in main.swift.
/// Call once after NSApplication/appearance setup and before AppDelegate setup.
/// Existing commands retain their explicit process-exit and error behavior.
enum DeveloperCommands {
    static func dispatch(arguments: [String] = CommandLine.arguments) throws {
        if let error = usageError(arguments: arguments) {
            fputs("\(error)\n", stderr)
            exit(2)
        }
        if let index = arguments.firstIndex(of: "--prepare-interchange-fixtures"),
            arguments.indices.contains(index + 1)
        {
            do {
                try InterchangeFixtures.generate(in: URL(fileURLWithPath: arguments[index + 1]))
                print("Generated synthetic public-content interchange fixtures")
                exit(0)
            } catch {
                fputs("Interchange fixture generation failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if let index = arguments.firstIndex(of: "--inspect-calculation"),
            arguments.indices.contains(index + 2)
        {
            do {
                try CalculationAudit.inspect(
                    URL(fileURLWithPath: arguments[index + 1]), to: URL(fileURLWithPath: arguments[index + 2])
                )
                exit(0)
            } catch {
                fputs("Calculation inspection failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if let index = arguments.firstIndex(of: "--inspect-geometry"), arguments.indices.contains(index + 2) {
            do {
                try GeometryAudit.inspect(
                    URL(fileURLWithPath: arguments[index + 1]), to: URL(fileURLWithPath: arguments[index + 2])
                )
                exit(0)
            } catch {
                fputs("Geometry inspection failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if let index = arguments.firstIndex(of: "--generate-curve-example"),
            arguments.indices.contains(index + 1)
        {
            do {
                try CurveExample.generate(in: URL(fileURLWithPath: arguments[index + 1]))
                print("Generated curve example")
                exit(0)
            } catch {
                fputs("Curve example failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if let index = arguments.firstIndex(of: "--generate-curve-library-example"),
            arguments.indices.contains(index + 2)
        {
            do {
                try CurveExample.generateLibrary(
                    from: URL(fileURLWithPath: arguments[index + 1]),
                    in: URL(fileURLWithPath: arguments[index + 2]))
                print("Generated installer curve example")
                exit(0)
            } catch {
                fputs("Installer curve example failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if let index = arguments.firstIndex(of: "--generate-text-context-example"),
            arguments.indices.contains(index + 1)
        {
            do {
                try TextContextExample.generate(in: URL(fileURLWithPath: arguments[index + 1]))
                print("Generated text-context example")
                exit(0)
            } catch {
                fputs("Text-context example failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if let index = arguments.firstIndex(of: "--generate-control-example"),
            arguments.indices.contains(index + 1)
        {
            do {
                try ControlExample.generate(in: URL(fileURLWithPath: arguments[index + 1]))
                print("Generated control-handle example")
                exit(0)
            } catch {
                fputs("Control example failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if let index = arguments.firstIndex(of: "--generate-geometry-example"),
            arguments.indices.contains(index + 1)
        {
            do {
                try GeometryExample.generate(in: URL(fileURLWithPath: arguments[index + 1]))
                print("Generated geometry example")
                exit(0)
            } catch {
                fputs("Geometry example failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if let index = arguments.firstIndex(of: "--generate-field-example"),
            arguments.indices.contains(index + 1)
        {
            do {
                try FieldExample.generate(in: URL(fileURLWithPath: arguments[index + 1]))
                print("Generated field example")
                exit(0)
            } catch {
                fputs("Field example failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if let index = arguments.firstIndex(of: "--generate-rich-text-example"),
            arguments.indices.contains(index + 1)
        {
            do {
                try RichTextExample.generate(in: URL(fileURLWithPath: arguments[index + 1]))
                print("Generated rich text example")
                exit(0)
            } catch {
                fputs("Rich text example failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if let index = arguments.firstIndex(of: "--generate-engineering-example"),
            arguments.indices.contains(index + 2)
        {
            do {
                try EngineeringExample.generate(
                    library: URL(fileURLWithPath: arguments[index + 1]),
                    in: URL(fileURLWithPath: arguments[index + 2]))
                print("Generated engineering example")
                exit(0)
            } catch {
                fputs("Engineering example failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if let index = arguments.firstIndex(of: "--generate-library-example"),
            arguments.indices.contains(index + 2)
        {
            do {
                try LibraryExample.generate(
                    from: URL(fileURLWithPath: arguments[index + 1]),
                    in: URL(fileURLWithPath: arguments[index + 2]))
                print("Generated installer library example")
                exit(0)
            } catch {
                fputs("Library example failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if let index = arguments.firstIndex(of: "--inspect-libraries"), arguments.indices.contains(index + 2)
        {
            do {
                let entries = try VisioLibrary.entries(in: URL(fileURLWithPath: arguments[index + 1]))
                var results: [[String: Any]] = []
                for entry in entries {
                    autoreleasepool {
                        do {
                            if entry.isStencil {
                                let imported = try VisioStencil.read(from: entry.url)
                                results.append([
                                    "file": entry.url.lastPathComponent, "masters": imported.items.count,
                                    "shapes": imported.items.reduce(0) { $0 + $1.fragment.nodes.count },
                                    "controls": imported.items.reduce(0) {
                                        $0 + $1.fragment.nodes.reduce(0) { $0 + $1.formatting.controls.count }
                                    }, "warnings": imported.warnings, "imported": true,
                                ])
                            } else {
                                let doc = MacVisioDocument()
                                try doc.read(
                                    from: entry.url,
                                    ofType: ["vst"].contains(entry.url.pathExtension.lowercased())
                                        ? MacVisioDocument.legacyType : MacVisioDocument.visioType)
                                results.append([
                                    "file": entry.url.lastPathComponent, "pages": doc.diagram.pages.count,
                                    "shapes": doc.diagram.pages.reduce(0) { $0 + $1.nodes.count },
                                    "controls": doc.diagram.pages.reduce(0) {
                                        $0 + $1.nodes.reduce(0) { $0 + $1.formatting.controls.count }
                                    }, "warnings": doc.importWarnings, "imported": true,
                                ])
                            }
                        } catch {
                            results.append([
                                "file": entry.url.lastPathComponent, "imported": false,
                                "error": error.localizedDescription,
                            ])
                        }
                    }
                }
                let failed = results.filter { $0["imported"] as? Bool != true }.count
                let report: [String: Any] = [
                    "files": results, "count": results.count, "failed": failed, "windowsValidated": false,
                    "fullBehavioralParity": false,
                ]
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: URL(fileURLWithPath: arguments[index + 2]), options: .atomic)
                print("Imported \(results.count-failed)/\(results.count) libraries; \(failed) failed.")
                exit(failed == 0 ? 0 : 1)
            } catch {
                fputs("Library inspection failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if let index = arguments.firstIndex(of: "--benchmark-sample"), arguments.indices.contains(index + 2) {
            do {
                exit(
                    try BenchmarkProfile.sample(
                        URL(fileURLWithPath: arguments[index + 1]),
                        to: URL(fileURLWithPath: arguments[index + 2])) ? 0 : 1)
            } catch {
                fputs("Benchmark failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if let index = arguments.firstIndex(of: "--profile-interactions"),
            arguments.indices.contains(index + 2)
        {
            do {
                try InteractionPerformance.profile(
                    URL(fileURLWithPath: arguments[index + 1]), to: URL(fileURLWithPath: arguments[index + 2])
                )
                exit(0)
            } catch {
                fputs("Interaction profiling failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if let index = arguments.firstIndex(of: "--profile-open"), arguments.indices.contains(index + 2) {
            do {
                try OpenPerformance.profile(
                    URL(fileURLWithPath: arguments[index + 1]), to: URL(fileURLWithPath: arguments[index + 2])
                )
                exit(0)
            } catch {
                fputs("Open profiling failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if let index = arguments.firstIndex(where: {
            $0 == "--convert" || $0 == "--render-document" || $0 == "--export-all-pdf"
        }), arguments.indices.contains(index + 2) {
            do {
                let input = URL(fileURLWithPath: arguments[index + 1])
                let output = URL(fileURLWithPath: arguments[index + 2])
                let operation = HeadlessOperation(rawValue: arguments[index])!
                let warnings = try processDocument(operation, input: input, output: output)
                for warning in warnings { fputs("\(warning)\n", stderr) }
                print("Wrote \(output.path)")
                exit(0)
            } catch {
                fputs("Document processing failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if let index = arguments.firstIndex(of: "--render-welcome"), arguments.indices.contains(index + 1) {
            do {
                let section: WelcomeSection =
                    arguments.contains("--welcome-new")
                    ? .new : arguments.contains("--welcome-open") ? .open : .home
                try WelcomePreview.render(
                    to: URL(fileURLWithPath: arguments[index + 1]), section: section,
                    compact: arguments.contains("--compact-ui"), empty: arguments.contains("--empty-recents"))
                exit(0)
            } catch {
                fputs("Start screen preview failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if let index = arguments.firstIndex(of: "--render-ui"), arguments.indices.contains(index + 1) {
            let doc = MacVisioDocument()
            doc.diagram =
                arguments.contains("--page-example")
                ? PageExample.make() : DiagramTemplate.flowchart.makeDiagram()
            doc.makeWindowControllers()
            if let controller = doc.windowControllers.first as? EditorWindowController,
                let view = controller.window?.contentView
            {
                if arguments.contains("--compact-ui") {
                    controller.window?.setContentSize(CGSize(width: 1000, height: 680))
                }
                if let tab = arguments.firstIndex(of: "--ribbon-tab"), arguments.indices.contains(tab + 1) {
                    controller.root.ribbon.selectTab(arguments[tab + 1])
                }
                view.layoutSubtreeIfNeeded()
                controller.canvas.fitPage()
                view.layoutSubtreeIfNeeded()
                if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try bitmap.representation(using: .png, properties: [:])!.write(
                        to: URL(fileURLWithPath: arguments[index + 1]))
                    print("Rendered native editor to \(arguments[index+1])")
                    exit(0)
                }
            }
            fputs("Could not render native editor\n", stderr)
            exit(1)
        }
        if let index = arguments.firstIndex(of: "--generate-page-example"),
            arguments.indices.contains(index + 1)
        {
            do {
                let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let diagram = try PageExample.make().validated()
                try JSONEncoder().encode(diagram).write(
                    to: directory.appendingPathComponent("shared-pages.macvisio"), options: .atomic)
                try VisioFormat.write(diagram, to: directory.appendingPathComponent("shared-pages.vsdx"))
                try VSDBinaryFormat.write(diagram, to: directory.appendingPathComponent("shared-pages.vsd"))
                try DiagramExport.pdf(diagram).write(
                    to: directory.appendingPathComponent("shared-pages.pdf"), options: .atomic)
                for page in diagram.pages where page.isBackground != true {
                    let stem = page.name.replacingOccurrences(of: " ", with: "-").lowercased()
                    try DiagramExport.png(diagram.scene(for: page.id), scale: 1).write(
                        to: directory.appendingPathComponent(stem + ".png"), options: .atomic)
                    try DiagramDrawing.svg(diagram.scene(for: page.id)).write(
                        to: directory.appendingPathComponent(stem + ".svg"), atomically: true, encoding: .utf8
                    )
                }
                print("Generated shared-background example in \(directory.path)")
                exit(0)
            } catch {
                fputs("Page example generation failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        if let index = arguments.firstIndex(of: "--generate-examples"), arguments.indices.contains(index + 1)
        {
            do {
                let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                for template in DiagramTemplate.allCases {
                    let diagram = template.makeDiagram()
                    try encoder.encode(diagram.validated()).write(
                        to: directory.appendingPathComponent(template.rawValue + ".macvisio"),
                        options: .atomic)
                    try VisioFormat.write(
                        diagram, to: directory.appendingPathComponent(template.rawValue + ".vsdx"))
                    try VSDBinaryFormat.write(
                        diagram, to: directory.appendingPathComponent(template.rawValue + ".vsd"))
                    try DiagramExport.pdf(diagram.page).write(
                        to: directory.appendingPathComponent(template.rawValue + ".pdf"), options: .atomic)
                    try DiagramDrawing.svg(diagram.page).write(
                        to: directory.appendingPathComponent(template.rawValue + ".svg"), atomically: true,
                        encoding: .utf8)
                    try DiagramExport.png(diagram.page).write(
                        to: directory.appendingPathComponent(template.rawValue + ".png"), options: .atomic)
                }
                print("Generated five examples in \(directory.path)")
                exit(0)
            } catch {
                fputs("Example generation failed: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
    }

    enum HeadlessOperation: String {
        case convert = "--convert"
        case render = "--render-document"
        case exportAllPDF = "--export-all-pdf"
    }

    /// Retains the CLI's synchronous reader/export behavior while preventing
    /// partial output or an accidental overwrite of the command's own input.
    static func processDocument(
        _ operation: HeadlessOperation, input: URL, output: URL,
        cancellation: LifecycleJobCancellation = LifecycleJobCancellation()
    ) throws -> [String] {
        try cancellation.check()
        let document = MacVisioDocument()
        try document.read(
            from: input,
            ofType: ["vsd", "vst"].contains(input.pathExtension.lowercased())
                ? MacVisioDocument.legacyType
                : input.pathExtension.lowercased() == "macvisio"
                    ? MacVisioDocument.nativeType : MacVisioDocument.visioType)
        try AtomicJobOutput.write(to: output, input: input, cancellation: cancellation) { staging in
            switch operation {
            case .exportAllPDF:
                guard output.pathExtension.lowercased() == "pdf" else {
                    throw DiagramError.invalid("All-page export must produce a PDF file.")
                }
                try DiagramExport.pdf(document.diagram).write(to: staging, options: .atomic)
            case .convert:
                switch output.pathExtension.lowercased() {
                case "vsdx": try VisioFormat.write(document.diagram, to: staging)
                case "vsd": try VSDBinaryFormat.write(document.diagram, to: staging)
                case "vstx": try VisioReusableFormat.writeTemplate(document.diagram, to: staging)
                default:
                    throw DiagramError.invalid(
                        "Conversion output must be a .vsdx drawing, .vsd drawing or .vstx template.")
                }
            case .render:
                switch output.pathExtension.lowercased() {
                case "png":
                    try DiagramExport.png(document.diagram.scene(), scale: 1).write(
                        to: staging, options: .atomic)
                case "pdf":
                    try DiagramExport.pdf(document.diagram.scene()).write(to: staging, options: .atomic)
                case "svg":
                    try DiagramDrawing.svg(document.diagram.scene()).write(
                        to: staging, atomically: true, encoding: .utf8)
                default: throw DiagramError.invalid("Rendering output must be PNG, PDF or SVG.")
                }
            }
        }
        return document.importWarnings
    }

    /// Validate recognized options before a malformed tooling request can fall
    /// through into normal GUI launch. Unknown application/system flags remain
    /// available to the normal bootstrap.
    static func usageError(arguments: [String]) -> String? {
        let operands: [String: Int] = [
            "--prepare-interchange-fixtures": 1, "--inspect-calculation": 2, "--inspect-geometry": 2,
            "--generate-curve-example": 1, "--generate-curve-library-example": 2,
            "--generate-text-context-example": 1, "--generate-control-example": 1,
            "--generate-geometry-example": 1, "--generate-field-example": 1,
            "--generate-rich-text-example": 1, "--generate-engineering-example": 2,
            "--generate-library-example": 2, "--inspect-libraries": 2,
            "--profile-interactions": 2, "--profile-open": 2, "--measure-drag-pan": 2, "--benchmark-sample": 2,
            "--convert": 2, "--render-document": 2, "--export-all-pdf": 2,
            "--render-welcome": 1, "--render-ui": 1, "--generate-page-example": 1,
            "--generate-examples": 1, "--ribbon-tab": 1, "--appearance": 1,
        ]
        for (index, argument) in arguments.enumerated().dropFirst() {
            guard let count = operands[argument] else { continue }
            guard arguments.count > index + count,
                (1...count).allSatisfy({ !arguments[index + $0].hasPrefix("--") })
            else {
                return "Usage: \(argument) requires \(count) operand\(count == 1 ? "" : "s")."
            }
        }
        return nil
    }

}
