import MacVisioInfrastructure
import AppKit

enum ShapeTextFunctions {
    static func text(_ node:DiagramNode,flags:Int = 0) throws -> String {
        guard (0...127).contains(flags) else { throw DiagramError.invalid("Unsupported SHAPETEXT flags.") }
        var text = flags & 2 != 0 ? ShapeRichText.runs(for:node).filter{$0.fieldIndex == nil}.map(\.text).joined() : node.text
        if flags & 1 == 0 { text = text.replacingOccurrences(of:"\u{00ad}",with:"") }
        if flags & 8 != 0 {
            var column = 0,result = ""
            for c in text { if c == "\t" { let count = 8-column%8;result += String(repeating:" ",count:count);column += count } else { result.append(c);column = c.isNewline ? 0 : column+1 } };text = result
        } else if flags & 4 != 0 { text = text.replacingOccurrences(of:"\t",with:" ") }
        if flags & 16 != 0 { text = text.replacingOccurrences(of:"\r\n",with:" ").replacingOccurrences(of:"\r",with:" ").replacingOccurrences(of:"\n",with:" ") }
        // Visio reports paragraph breaks as CR LF (ARIAL-7/8).
        else { text = text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\n",with:"\r\n") }
        if flags & 32 != 0 { for (from,to) in [("‘","'"),("’","'"),("“","\""),("”","\"")] { text = text.replacingOccurrences(of:from,with:to) } }
        if flags & 64 != 0 {
            var result = "",space = false
            for c in text { if c.isWhitespace { if !space { result.append(" ") };space = true } else { result.append(c);space = false } };text = result
        };return text
    }
    struct Metrics { var width:Double;var height:Double }
    static func metrics(_ node:DiagramNode,page:DiagramPage,maximumWidth:Double? = nil,cancellation:LifecycleJobCancellation? = nil) throws -> Metrics {
        try ShapeTextMeasurementService.perform(cancellation: cancellation) {
            try metricsOnMain(node, page: page, maximumWidth: maximumWidth)
        }
    }
    private static func metricsOnMain(_ node:DiagramNode,page:DiagramPage,maximumWidth:Double?) throws -> Metrics {
        precondition(Thread.isMainThread, "AppKit text measurement requires the main thread.")
        if let width = maximumWidth { guard width.isFinite,width > 0,width*72*page.paperScale < 1e7 else { throw DiagramError.invalid("Invalid text measurement width.") } }
        let evidence = PerformanceEvidence.begin(.textLayout);defer { PerformanceEvidence.end(evidence) }
        PerformanceEvidence.count(.textMeasurements)
        let scale = page.paperScale,box = node.formatting.textBox
        let left = (box?.left ?? 0)*scale,right = (box?.right ?? 0)*scale,top = (box?.top ?? 0)*scale,bottom = (box?.bottom ?? 0)*scale
        let width = maximumWidth.map{$0*72*scale} ?? 1e7,inner = max(0.001,width-left-right)
        let storage = NSTextStorage(attributedString:ShapeRichText.attributed(node)),layout = NSLayoutManager(),container = NSTextContainer(containerSize:CGSize(width:inner,height:1e7))
        container.lineFragmentPadding = 0;container.lineBreakMode = .byWordWrapping;layout.usesFontLeading = false;storage.addLayoutManager(layout);layout.addTextContainer(container);layout.ensureLayout(for:container)
        // Visio measures each line with its trailing spaces and counts the paragraph mark that ends a
        // paragraph as one space of the line's last font (METRIC reference cases).
        let range = layout.glyphRange(for:container);var longest = 0.0
        let text = storage.string as NSString
        layout.enumerateLineFragments(forGlyphRange:range){_,_,_,glyphs,_ in
            let characters = layout.characterRange(forGlyphRange:glyphs,actualGlyphRange:nil)
            var line = storage.attributedSubstring(from:characters).string
            let endsParagraph = NSMaxRange(characters) >= text.length || line.hasSuffix("\n") || line.hasSuffix("\r")
            while line.hasSuffix("\n") || line.hasSuffix("\r") { line.removeLast() }
            let content = storage.attributedSubstring(from:NSRange(location:characters.location,length:(line as NSString).length))
            var width = content.length == 0 ? 0 : Double(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(content),nil,nil,nil))
            if endsParagraph {
                let index = max(0,min(text.length-1,characters.location+max(0,content.length-1)))
                let font = (text.length > 0 ? storage.attribute(.font,at:index,effectiveRange:nil) as? NSFont : nil) ?? ShapeCharacterStyle(node:node).font
                width += (" " as NSString).size(withAttributes:[.font:font]).width
            }
            longest = max(longest,width)
        }
        var height = layout.usedRect(for:container).height
        if storage.length == 0 { height = layout.defaultLineHeight(for:ShapeCharacterStyle(node:node).font) }
        else if node.text.hasSuffix("\n") || node.text.hasSuffix("\r") { height = max(height,layout.extraLineFragmentUsedRect.maxY) }
        guard longest.isFinite,height.isFinite,height < 1e7 else { throw DiagramError.invalid("Text measurement exceeded the layout limit.") }
        return Metrics(width:(longest+left+right)/(72*scale),height:(height+top+bottom)/(72*scale))
    }
}
