import Foundation

enum LegacyVisioFormat {
    static var converterURL: URL? {
        helperURL("vsd2xhtml")
    }
    static var stencilConverterURL: URL? { helperURL("vss2xhtml") }
    private static func helperURL(_ name:String) -> URL? {
        let paths = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/"+name).path,"/opt/homebrew/bin/"+name,"/usr/local/bin/"+name]
        return paths.first(where:{FileManager.default.isExecutableFile(atPath:$0)}).map{URL(fileURLWithPath:$0)}
    }
    static func read(from url:URL) throws -> VisioImportResult {
        let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size <= 100*1024*1024 else { throw DiagramError.invalid("This legacy drawing exceeds the 100 MB import limit.") }
        let handle = try FileHandle(forReadingFrom:url); let signature = try handle.read(upToCount:8); try handle.close()
        guard signature == Data([0xD0,0xCF,0x11,0xE0,0xA1,0xB1,0x1A,0xE1]) else { throw DiagramError.invalid("This is not a supported binary Visio compound document.") }
        let sourceData = try Data(contentsOf:url)
        let compound = try? CompoundFile.read(sourceData)
        if let file = compound,let native = VSDBinaryFormat.nativeModel(in:file) {
            return VisioImportResult(diagram:native,warnings:["Binary VSD export is experimental and has not been validated in Microsoft Visio. Cached drawing graphics are public; advanced native features use integrity-checked MacVisio metadata."],legacyNative:true)
        }
        let converted = try graphicPages(from:url,stencils:false)
        var diagram = Diagram();diagram.title = url.deletingPathExtension().lastPathComponent;diagram.pages = converted.pages
        diagram.activePageID = diagram.pages[0].id
        diagram.legacySource = LegacyVisioSource(data:sourceData,title:diagram.title,pages:diagram.pages)
        var warnings = Set(converted.warnings)
        if compound?.streams[VSDBinaryFormat.nativeStream] != nil { warnings.insert("The binary drawing changed outside MacVisio; its public content was imported instead of stale native metadata.") }
        warnings.insert("Legacy VSD was converted to editable vector shapes, text and images. ShapeSheet formulas, shape data and connector glue are not retained by this conversion.")
        warnings.insert("Binary VSD writing is experimental. Unedited source files retain their original bytes; edits regenerate cached graphics and text, without full original formula, data and glue semantics. Microsoft Visio compatibility is unverified.")
        return VisioImportResult(diagram:try diagram.validated(),warnings:warnings.sorted())
    }
    static func graphicPages(from url:URL,stencils:Bool) throws -> (pages:[DiagramPage],warnings:[String]) {
        let size = try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
        guard size <= 100*1024*1024 else { throw DiagramError.invalid("This legacy file exceeds the 100 MB import limit.") }
        let handle = try FileHandle(forReadingFrom:url);let signature = try handle.read(upToCount:8);try handle.close()
        guard signature == CompoundFile.signature else { throw DiagramError.invalid("This is not a binary Visio compound document.") }
        guard let converter = stencils ? stencilConverterURL : converterURL else { throw DiagramError.invalid("The bundled legacy Visio reader is missing. Rebuild the app with libvisio installed.") }
        let process = Process(),pipe = Pipe()
        process.executableURL = converter; process.arguments = [url.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline:.now()+30,execute:timeout)
        defer { timeout.cancel(); try? pipe.fileHandleForReading.close() }
        var data = Data()
        while let chunk = try pipe.fileHandleForReading.read(upToCount:65536),!chunk.isEmpty {
            guard data.count+chunk.count <= 64*1024*1024 else { process.terminate(); process.waitUntilExit(); throw DiagramError.invalid("The converted drawing exceeds the supported size.") }
            data.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0,let html = String(data:data,encoding:.utf8) else { throw DiagramError.invalid("The binary Visio drawing could not be decoded by libvisio.") }
        let pattern = "<((?:[A-Za-z_][A-Za-z0-9_.-]*:)?svg)(?=\\s|>)[\\s\\S]*?</\\1\\s*>"
        let regex = try NSRegularExpression(pattern:pattern)
        let matches = regex.matches(in:html,range:NSRange(html.startIndex...,in:html))
        guard !matches.isEmpty,matches.count <= 1000 else { throw DiagramError.invalid("The legacy drawing contains no supported drawing pages.") }
        var pages:[DiagramPage] = []
        var warnings = Set<String>()
        for (index,match) in matches.enumerated() {
            guard let range = Range(match.range,in:html) else { continue }
            let result = try SVGImport.page(Data(html[range].utf8),name:stencils ? "Master \(index+1)" : "Page \(index+1)")
            pages.append(result.page); warnings.formUnion(result.warnings)
        }
        guard !pages.isEmpty else { throw DiagramError.invalid("The legacy file contains no supported graphics.") }
        return (pages,warnings.sorted())
    }
}
