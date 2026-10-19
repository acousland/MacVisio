import AppKit
#if canImport(FoundationXML)
import FoundationXML
#endif

struct ShapeCharacterStyle: Codable, Equatable {
    var fontName = "Arial"
    var size: Double = 14
    var color = "#20334F"
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    var sourceIndex: Int?
    var cells: [String:ShapeSheetCell] = [:]
    init(node: DiagramNode) {
        fontName = node.formatting.fontName;size = node.fontSize;color = node.textColor
        bold = node.bold;italic = node.formatting.italic;underline = node.formatting.underline
    }
    var font: NSFont {
        NativeFontRendering.font(requested: fontName, size: size, bold: bold, italic: italic)
    }
    var valid: Bool { size.isFinite && (1...500).contains(size) && fontName.utf8.count <= 1024 && cells.count <= 256 && cells.values.allSatisfy{$0.formula.utf8.count <= 16384} && (sourceIndex.map{$0 >= 0 && $0 <= Int32.max} ?? true) }
}
struct ShapeParagraphStyle: Codable, Equatable {
    static let editableLengthCells = ["SpBefore", "SpAfter", "SpLine", "IndLeft", "IndFirst", "IndRight"]
    var alignment: TextAlignment = .center
    var sourceIndex: Int?
    var cells: [String:ShapeSheetCell] = [:]
    var native: NSParagraphStyle {
        native(fontSize:14)
    }
    func native(fontSize:Double,scale:Double = 1) -> NSParagraphStyle {
        let result = NSMutableParagraphStyle();result.alignment = alignment == .left ? .left : alignment == .right ? .right : .center
        func number(_ key:String) -> Double? { cells.first{$0.key.caseInsensitiveCompare(key) == .orderedSame}.flatMap{Double($0.value.value)}.flatMap{$0.isFinite && abs($0)<100000 ? $0 : nil} }
        if let value = number("SpBefore") { result.paragraphSpacingBefore = max(0,value*72*scale) }
        if let value = number("SpAfter") { result.paragraphSpacing = max(0,value*72*scale) }
        if let value = number("SpLine") { let height = (value > 0 ? value*72 : value == 0 ? fontSize : -value*fontSize)*scale;result.minimumLineHeight = height;result.maximumLineHeight = height }
        if let value = number("IndLeft") { result.headIndent = value*72*scale;result.firstLineHeadIndent = result.headIndent }
        if let value = number("IndFirst") { result.firstLineHeadIndent = result.headIndent + value*72*scale }
        if let value = number("IndRight") { result.tailIndent = -value*72*scale }
        result.lineBreakMode = .byWordWrapping;return result
    }
    /// Extract only properties represented by the native renderer. Compare with
    /// the original rendered style so an unrelated edit keeps source formulas,
    /// units and absent defaults rather than materializing every native value.
    func applying(_ style: NSParagraphStyle, fontSize: Double, scale: Double = 1) -> ShapeParagraphStyle {
        guard scale.isFinite, scale > 0 else { return self }
        let original = native(fontSize: fontSize, scale: scale)
        var result = self
        result.alignment = style.alignment == .left ? .left : style.alignment == .right ? .right : .center
        func differs(_ value: CGFloat, from previous: CGFloat) -> Bool {
            value.isFinite && abs(value - previous) > max(1e-9, abs(previous) * 1e-12)
        }
        func setLength(_ name: String, points: CGFloat) {
            let value = Double(points) / (72 * scale)
            guard value.isFinite, abs(value) < 100000 else { return }
            guard !["SpBefore", "SpAfter", "SpLine"].contains(name) || value >= 0 else { return }
            let key = result.cells.keys.first { $0.caseInsensitiveCompare(name) == .orderedSame } ?? name
            result.cells[key] = ShapeSheetCell(value: CompositeGeometry.number(value), unit: result.cells[key]?.unit ?? "")
        }
        for (name, value, previous) in [
            ("SpBefore", style.paragraphSpacingBefore, original.paragraphSpacingBefore),
            ("SpAfter", style.paragraphSpacing, original.paragraphSpacing),
            ("IndLeft", style.headIndent, original.headIndent),
            ("IndFirst", style.firstLineHeadIndent - style.headIndent, original.firstLineHeadIndent - original.headIndent),
            ("IndRight", -style.tailIndent, -original.tailIndent),
        ] where differs(value, from: previous) {
            setLength(name, points: value)
        }
        // A fixed native line height has an exact existing SpLine mapping.
        // Natural/minimum-only heights, additive line spacing, tabs and bullets
        // need separate semantics; preserve their source cells in this slice.
        if style.minimumLineHeight > 0,
           style.minimumLineHeight == style.maximumLineHeight,
           differs(style.minimumLineHeight, from: original.minimumLineHeight)
            || differs(style.maximumLineHeight, from: original.maximumLineHeight) {
            setLength("SpLine", points: style.minimumLineHeight)
        }
        return result
    }
    var valid: Bool { cells.count <= 256 && cells.values.allSatisfy{$0.formula.utf8.count <= 16384} && (sourceIndex.map{$0 >= 0 && $0 <= Int32.max} ?? true) }
}
struct ShapeTextRun: Codable, Equatable {
    var text: String
    var character: ShapeCharacterStyle
    var paragraph: ShapeParagraphStyle
    var fieldIndex:Int?
    var fieldToken:UUID?
}

enum ShapeRichText {
    private static let characterKey = NSAttributedString.Key("MacVisioCharacterRun")
    private static let paragraphKey = NSAttributedString.Key("MacVisioParagraphRun")
    private static let fieldKey = NSAttributedString.Key("MacVisioTextField")
    private static let emptyFieldKey = NSAttributedString.Key("MacVisioEmptyField")

    /// The previous diagram is immutable for the duration of synchronization.
    /// Index it once so each current node can find its baseline without
    /// rescanning (and copying) every preceding page and node.
    private struct PreviousNodeLookup {
        var pageIndex: Int
        var nodeIndices: [UUID:Int]
    }

    private static func previousNodeLookup(_ diagram:Diagram) -> [UUID:PreviousNodeLookup] {
        var result:[UUID:PreviousNodeLookup] = [:]
        for pageIndex in diagram.pages.indices {
            let page = diagram.pages[pageIndex]
            // Keep the same first-match behavior as `first(where:)` if an
            // invalid intermediate model contains duplicate page IDs.
            guard result[page.id] == nil else { continue }
            var nodeIndices:[UUID:Int] = [:]
            for nodeIndex in page.nodes.indices {
                let id = page.nodes[nodeIndex].id
                if nodeIndices[id] == nil { nodeIndices[id] = nodeIndex }
            }
            result[page.id] = PreviousNodeLookup(pageIndex:pageIndex,nodeIndices:nodeIndices)
        }
        return result
    }
    static func logicalSelection(_ selection:NSRange,in text:NSAttributedString) -> NSRange {
        func offset(_ limit:Int) -> Int {
            var removed = 0
            text.enumerateAttribute(emptyFieldKey,in:NSRange(location:0,length:text.length)) { value,range,_ in if value as? Bool == true,range.location < limit { removed += min(range.length,limit-range.location) } }
            return max(0,limit-removed)
        }
        let start = offset(selection.location),end = offset(NSMaxRange(selection));return NSRange(location:start,length:max(0,end-start))
    }
    static func runs(for node:DiagramNode) -> [ShapeTextRun] {
        if let runs = node.formatting.textRuns,runs.map(\.text).joined() == node.text { return runs }
        return node.text.isEmpty ? [] : [ShapeTextRun(text:node.text,character:ShapeCharacterStyle(node:node),paragraph:ShapeParagraphStyle(alignment:node.formatting.alignment))]
    }
    static func attributed(_ node:DiagramNode,scale:Double = 1,editing:Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString(string:"")
        for (index,run) in runs(for:node).enumerated() {
            let font = NSFontManager.shared.convert(run.character.font,toSize:run.character.size*scale)
            var attributes:[NSAttributedString.Key:Any] = [.font:font,.foregroundColor:NSColor(hex:run.character.color),.paragraphStyle:run.paragraph.native(fontSize:run.character.size,scale:scale),characterKey:index,paragraphKey:index]
            if run.character.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.character.strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let field = run.fieldIndex { attributes[fieldKey] = field;if editing { attributes[.backgroundColor] = NSColor.quaternaryLabelColor };if editing && run.text.isEmpty { attributes[emptyFieldKey] = true } }
            result.append(NSAttributedString(string:editing && run.fieldIndex != nil && run.text.isEmpty ? "‹field›" : run.text,attributes:attributes))
        }
        return result
    }
    static func applying(_ attributed:NSAttributedString,to node:DiagramNode,scale:Double = 1) -> DiagramNode {
        var result = node;result.text = attributed.string
        let previous = runs(for:node);var output:[ShapeTextRun] = [],origins:[UUID:Int] = [:],tokens:[Int:UUID] = [:]
        attributed.enumerateAttributes(in:NSRange(location:0,length:attributed.length)) { attributes,range,_ in
            let index = (attributes[characterKey] as? Int) ?? 0
            var character = previous.indices.contains(index) ? previous[index].character : ShapeCharacterStyle(node:node)
            if let font = attributes[.font] as? NSFont {
                let oldFont = NSFontManager.shared.convert(character.font,toSize:character.size*scale)
                if font.fontName != oldFont.fontName { character.fontName = font.familyName ?? font.fontName }
                character.size = min(500,max(1,font.pointSize/scale))
                let traits = NSFontManager.shared.traits(of:font);character.bold = traits.contains(.boldFontMask);character.italic = traits.contains(.italicFontMask)
            }
            if let color = attributes[.foregroundColor] as? NSColor { character.color = color.hexString }
            character.underline = (attributes[.underlineStyle] as? Int ?? 0) != 0
            character.strikethrough = (attributes[.strikethroughStyle] as? Int ?? 0) != 0
            let pIndex = (attributes[paragraphKey] as? Int) ?? index
            var paragraph = previous.indices.contains(pIndex) ? previous[pIndex].paragraph : ShapeParagraphStyle(alignment:node.formatting.alignment)
            if let style = attributes[.paragraphStyle] as? NSParagraphStyle {
                let originalSize = previous.indices.contains(index) ? previous[index].character.size : node.fontSize
                paragraph = paragraph.applying(style, fontSize: originalSize, scale: scale)
            }
            var run = ShapeTextRun(text:(attributed.string as NSString).substring(with:range),character:character,paragraph:paragraph)
            if let field = attributes[fieldKey] as? Int,previous.indices.contains(index),previous[index].fieldIndex == field,node.formatting.textFields?.contains(where:{$0.index == field}) == true {
                let token = tokens[index] ?? previous[index].fieldToken ?? UUID();tokens[index] = token;origins[token] = index;run.fieldIndex = field;run.fieldToken = token
                if attributes[emptyFieldKey] as? Bool == true,run.text == "‹field›" { run.text = "" }
            }
            if let last = output.last,last.character == character,last.paragraph == paragraph,last.fieldIndex == run.fieldIndex,last.fieldToken == run.fieldToken { output[output.count-1].text += run.text } else { output.append(run) }
        }
        var handled = Set<UUID>(),normalized:[ShapeTextRun] = []
        for var run in output {
            if let token = run.fieldToken,let origin = origins[token] {
                let pieces = output.filter{$0.fieldToken == token},text = pieces.map(\.text).joined()
                if text == previous[origin].text {
                    guard handled.insert(token).inserted else { continue }
                    if let changed = pieces.first(where:{$0.character != previous[origin].character}) { run.character = changed.character };run.text = text
                } else { run.fieldIndex = nil;run.fieldToken = nil }
            }
            normalized.append(run)
        }
        result.text = normalized.map(\.text).joined();result.formatting.textRuns = normalized
        return result
    }
    static func replacingText(_ old:String,with text:String,runs:[ShapeTextRun]) -> [ShapeTextRun] {
        guard !text.isEmpty else { return [] };guard !runs.isEmpty else { return [] }
        var a = old.startIndex,b = text.startIndex
        while a < old.endIndex,b < text.endIndex,old[a].description.utf8.elementsEqual(text[b].description.utf8) { a = old.index(after:a);b = text.index(after:b) }
        var c = old.endIndex,d = text.endIndex
        while c > a,d > b {
            let x = old.index(before:c),y = text.index(before:d)
            guard old[x].description.utf8.elementsEqual(text[y].description.utf8) else { break };c = x;d = y
        }
        let prefix = old[..<a].utf16.count,suffix = old[..<c].utf16.count
        var output:[ShapeTextRun] = [],offset = 0,inherit = runs[0],changed = Set<UUID>(),changedIndexes = Set<Int>()
        for run in runs { let end = offset+run.text.utf16.count
            if let field = run.fieldIndex,(prefix < end && suffix > offset) || (prefix == suffix && prefix > offset && prefix < end) { if let token = run.fieldToken { changed.insert(token) } else { changedIndexes.insert(field) } };offset = end
        };offset = 0
        func append(_ input:ShapeTextRun) { var input = input
            if input.fieldToken.map({changed.contains($0)}) ?? input.fieldIndex.map({changedIndexes.contains($0)}) ?? false { input.fieldIndex = nil;input.fieldToken = nil }
            guard !input.text.isEmpty || input.fieldIndex != nil else { return }
            if let last = output.last,last.fieldIndex == nil,input.fieldIndex == nil,last.character == input.character,last.paragraph == input.paragraph { output[output.count-1].text += input.text } else { output.append(input) }
        }
        for run in runs {
            let length = run.text.utf16.count
            if prefix > offset { var part = run;part.text = (run.text as NSString).substring(to:min(length,prefix-offset));append(part);inherit = run }
            offset += length
        }
        inherit.text = String(text[b..<d]);inherit.fieldIndex = nil;inherit.fieldToken = nil;append(inherit);offset = 0
        for run in runs {
            let length = run.text.utf16.count
            if offset+length > suffix { var part = run;part.text = (run.text as NSString).substring(from:max(0,suffix-offset));append(part) }
            offset += length
        }
        return output
    }
    /// Inspector changes apply to all runs; text-view edits supply their own runs.
    static func synchronize(_ input:Diagram,previous:Diagram,changes:DocumentChangeSet? = nil,session:CalculationSession? = nil,onNodeVisits:((Int)->Void)? = nil) -> Diagram {
        let previousIndices = changes == nil ? previousNodeLookup(previous) : [:]
        if changes == nil { onNodeVisits?(previous.pages.reduce(0) { $0 + $1.nodes.count }) }
        let priorPages = Dictionary(uniqueKeysWithValues: previous.pages.enumerated().map { ($0.element.id, $0.offset) })
        var result = input
        for p in result.pages.indices {
            let pageID = result.pages[p].id
            guard let previousPage = priorPages[pageID] else { continue }
            let oldIndices: [UUID:Int]
            let selected: [Int]
            if let changes {
                guard let pageChanges = changes.pages[pageID], !pageChanges.changedNodeIDs.isEmpty else { continue }
                if !pageChanges.nodeOrderChanged, pageChanges.insertedNodeIDs.isEmpty, pageChanges.deletedNodeIDs.isEmpty,
                   let retained = session?.retainedNodeIndices(pageID: pageID) {
                    oldIndices = retained
                    selected = pageChanges.changedNodeIDs.compactMap { retained[$0] }.sorted()
                } else {
                    oldIndices = Dictionary(uniqueKeysWithValues: previous.pages[previousPage].nodes.enumerated().map { ($0.element.id, $0.offset) })
                    let currentIndices = Dictionary(uniqueKeysWithValues: result.pages[p].nodes.enumerated().map { ($0.element.id, $0.offset) })
                    onNodeVisits?(previous.pages[previousPage].nodes.count + result.pages[p].nodes.count)
                    selected = pageChanges.changedNodeIDs.compactMap { currentIndices[$0] }.sorted()
                }
            } else {
                guard let pageLookup = previousIndices[pageID] else { continue }
                oldIndices = pageLookup.nodeIndices
                selected = Array(result.pages[p].nodes.indices)
            }
            onNodeVisits?(selected.count)
            for n in selected {
            var node = result.pages[p].nodes[n]
            guard let oldIndex = oldIndices[node.id],let runs = node.formatting.textRuns else { continue }
            let old = previous.pages[previousPage].nodes[oldIndex]
            let sizeChanged = node.fontSize != old.fontSize
            let colorChanged = node.textColor != old.textColor
            let boldChanged = node.bold != old.bold
            let fontChanged = node.formatting.fontName != old.formatting.fontName
            let italicChanged = node.formatting.italic != old.formatting.italic
            let underlineChanged = node.formatting.underline != old.formatting.underline
            let alignmentChanged = node.formatting.alignment != old.formatting.alignment

            // Text or geometry edits do not need a rich-text rewrite. Besides
            // avoiding an allocation, this preserves the exact run array (and
            // its source indices) for ordinary text replacement.
            guard sizeChanged || colorChanged || boldChanged || fontChanged || italicChanged || underlineChanged || alignmentChanged else { continue }
            let expected = old.formatting.textRuns.map{old.text == node.text ? $0 : replacingText(old.text,with:node.text,runs:$0)}
            guard node.formatting.textRuns == expected else { continue }
            node.formatting.textRuns = runs.map { run in
                var run = run
                if sizeChanged { run.character.size = node.fontSize }
                if colorChanged { run.character.color = node.textColor }
                if boldChanged { run.character.bold = node.bold }
                if fontChanged { run.character.fontName = node.formatting.fontName }
                if italicChanged { run.character.italic = node.formatting.italic }
                if underlineChanged { run.character.underline = node.formatting.underline }
                if alignmentChanged { run.paragraph.alignment = node.formatting.alignment }
                return run
            }
            result.pages[p].nodes[n] = node
            }
        }
        return result
    }
    static func withoutSourceIndices(_ input:[DiagramPage]) -> [DiagramPage] {
        input.map { page in var page = page;for i in page.nodes.indices { if let runs = page.nodes[i].formatting.textRuns { page.nodes[i].formatting.textRuns = runs.map{run in var run = run;run.character.sourceIndex = nil;run.paragraph.sourceIndex = nil;return run} } };return page }
    }
    static func synchronizeCalculation(_ input:Diagram,previous:Diagram,affectedNodeIDsByPage:[UUID:Set<UUID>]? = nil,nodeIndicesByPage:[UUID:[UUID:Int]] = [:]) -> Diagram {
        var result = input
        let priorPages = Dictionary(uniqueKeysWithValues: previous.pages.enumerated().map { ($0.element.id, $0.offset) })
        let fullLookup = affectedNodeIDsByPage == nil ? previousNodeLookup(previous) : [:]
        for p in result.pages.indices {
            let pageID = result.pages[p].id
            guard let previousPage = priorPages[pageID] else { continue }
            let selected: [Int]
            let oldIndices: [UUID:Int]
            if let affectedNodeIDsByPage {
                guard let ids = affectedNodeIDsByPage[pageID], !ids.isEmpty else { continue }
                // Calculation does not insert/remove/reorder nodes. Its supplied
                // index addresses both snapshots and avoids rebuilding lookups.
                oldIndices = nodeIndicesByPage[pageID] ?? Dictionary(uniqueKeysWithValues: previous.pages[previousPage].nodes.enumerated().map { ($0.element.id, $0.offset) })
                selected = ids.compactMap { oldIndices[$0] }.sorted()
            } else {
                guard let lookup = fullLookup[pageID] else { continue }
                oldIndices = lookup.nodeIndices
                selected = Array(result.pages[p].nodes.indices)
            }
            for i in selected {
                var node = result.pages[p].nodes[i]
                guard let oldIndex = oldIndices[node.id], node.formatting.textRuns != nil else { continue }
                let old = previous.pages[previousPage].nodes[oldIndex]
                guard node.fontSize != old.fontSize, node.formatting.textRuns == old.formatting.textRuns,
                      let runs = node.formatting.textRuns, let first = runs.first else { continue }
                node.formatting.textRuns = runs.enumerated().map { index, run in
                    var run = run
                    if first.character.sourceIndex.map({ $0 == run.character.sourceIndex }) ?? (index == 0) { run.character.size = node.fontSize }
                    return run
                }
                result.pages[p].nodes[i] = node
            }
        }
        return result
    }
    private static func indices<S:Equatable>(_ styles:[S],source:(S)->Int?,preferred:(S)->Bool = {_ in false},reserved:Set<Int> = []) -> ([S],[Int],[Int]) {
        var unique:[S] = [],positions:[Int] = []
        for style in styles { if let i = unique.firstIndex(of:style) { positions.append(i) } else { positions.append(unique.count);unique.append(style) } }
        var used = Set<Int>(),assigned = Array(repeating:0,count:unique.count);var next = max(unique.compactMap(source).max() ?? -1,reserved.max() ?? -1)+1
        let order = unique.indices.sorted{preferred(unique[$0]) != preferred(unique[$1]) ? preferred(unique[$0]) : $0 < $1}
        for i in order {
            let style = unique[i]
            if let index = source(style),!used.contains(index) { assigned[i] = index;used.insert(index) }
            else { while used.contains(next) || reserved.contains(next) { next += 1 };assigned[i] = next;used.insert(next);next += 1 }
        }
        return (unique,positions,assigned)
    }
    static func fontRows(_ node:DiagramNode) -> [(index:Int,name:String)] {
        guard node.formatting.textRuns != nil else { return [(0,node.formatting.fontName)] }
        let (styles,_,assigned) = indices(runs(for:node).map(\.character),source:{$0.sourceIndex})
        return styles.enumerated().map{(assigned[$0.offset],$0.element.fontName)}
    }
    static func svg(_ node:DiagramNode,rect:CGRect,clipRect:CGRect? = nil) -> String {
        guard !node.text.isEmpty else { return "" }
        let storage = NSTextStorage(attributedString:attributed(node)),manager = NSLayoutManager(),container = NSTextContainer(containerSize:CGSize(width:max(1,rect.width),height:100000))
        container.lineFragmentPadding = 0;manager.addTextContainer(container);storage.addLayoutManager(manager);manager.ensureLayout(for:container)
        let height = manager.usedRect(for:container).height,vertical = node.formatting.textBox?.verticalAlignment ?? 1
        let dy = rect.minY+max(0,(rect.height-height)*(vertical == 0 ? 0 : vertical == 2 ? 1 : 0.5))
        func xml(_ value:String) -> String { value.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;") }
        var spans = ""
        manager.enumerateLineFragments(forGlyphRange:manager.glyphRange(for:container)) { line,_,_,glyphs,_ in
            let characters = manager.characterRange(forGlyphRange:glyphs,actualGlyphRange:nil)
            storage.enumerateAttributes(in:characters) { attributes,range,_ in
                let text = (storage.string as NSString).substring(with:range).replacingOccurrences(of:"\n",with:"").replacingOccurrences(of:"\r",with:"")
                guard !text.isEmpty else { return }
                let glyph = manager.glyphRange(forCharacterRange:range,actualCharacterRange:nil).location,position = manager.location(forGlyphAt:glyph)
                let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize:node.fontSize),color = (attributes[.foregroundColor] as? NSColor ?? NSColor(hex:node.textColor)).usingColorSpace(.sRGB)!
                let traits = NSFontManager.shared.traits(of:font)
                var decoration:[String] = [];if (attributes[.underlineStyle] as? Int ?? 0) != 0 { decoration.append("underline") };if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { decoration.append("line-through") }
                spans += "<tspan x=\"\(rect.minX+line.minX+position.x)\" y=\"\(dy+line.minY+position.y)\" font-family=\"\(xml(font.familyName ?? font.fontName))\" font-size=\"\(font.pointSize)\" font-weight=\"\(traits.contains(.boldFontMask) ? 700 : 400)\" font-style=\"\(traits.contains(.italicFontMask) ? "italic" : "normal")\" fill=\"\(String(color.hexString.prefix(7)))\" fill-opacity=\"\(color.alphaComponent)\" text-decoration=\"\(decoration.isEmpty ? "none" : decoration.joined(separator:" "))\">\(xml(text))</tspan>"
            }
        }
        let clip = "text-"+node.id.uuidString,clipBounds = clipRect ?? rect
        return "<defs><clipPath id=\"\(clip)\"><rect x=\"\(clipBounds.minX)\" y=\"\(clipBounds.minY)\" width=\"\(clipBounds.width)\" height=\"\(clipBounds.height)\"/></clipPath></defs><text xml:space=\"preserve\" clip-path=\"url(#\(clip))\">\(spans)</text>"
    }
    static func patch(_ node:DiagramNode,element:XMLElement,previous:DiagramNode? = nil,fresh:Bool = false) {
        let runs = runs(for:node)
        let old = previous.map{self.runs(for:$0)} ?? []
        if fresh { for section in element.elementsLocal("Section") where ["Character","Paragraph"].contains(section.attr("N") ?? "") { section.detach() } }
        func reserved(_ name:String) -> Set<Int> { Set(element.elementsLocal("Section").filter{$0.attr("N") == name}.flatMap{$0.elementsLocal("Row")}.compactMap{Int($0.attr("IX") ?? "")}) }
        let sequential = Array(runs.indices)
        let (characters,cp,ci) = fresh ? (runs.map(\.character),sequential,sequential) : indices(runs.map(\.character),source:{$0.sourceIndex},preferred:{style in old.contains{$0.character == style}},reserved:reserved("Character"))
        let (paragraphs,pp,pi) = fresh ? (runs.map(\.paragraph),sequential,sequential) : indices(runs.map(\.paragraph),source:{$0.sourceIndex},preferred:{style in old.contains{$0.paragraph == style}},reserved:reserved("Paragraph"))
        func row(_ sectionName:String,_ index:Int,_ origin:Int?,_ cells:[String:ShapeSheetCell]) -> XMLElement {
            let section = VisioXML.section(element,sectionName)
            let row = section.elementsLocal("Row").first{$0.attr("IX") == String(index)} ?? XMLElement(name:"Row")
            if row.parent == nil {
                if let origin,let original = section.elementsLocal("Row").first(where:{$0.attr("IX") == String(origin)}) { for child in original.children ?? [] { row.addChild(child.copy() as! XMLNode) } }
                row.setAttr("IX",String(index));section.addChild(row)
            }
            row.setAttr("Del",nil)
            for (name,cell) in cells where !row.elementsLocal("Cell").contains(where:{$0.attr("N") == name}) {
                let value = VisioXML.set(row,name,cell.value,formula:cell.formula.isEmpty ? nil : cell.formula);if !cell.unit.isEmpty { value.setAttr("U",cell.unit) }
            }
            return row
        }
        func cached(_ row:XMLElement,_ name:String,_ value:Double) {
            if abs(VisioXML.number(row,name,.infinity)-value)>1e-10 { VisioXML.set(row,name,value) }
        }
        for (i,style) in characters.enumerated() {
            let row = row("Character",ci[i],style.sourceIndex,style.cells)
            cached(row,"Size",style.size/72)
            let bits = ((Int(exactly:VisioXML.number(row,"Style")) ?? 0) & ~7) | (style.bold ? 1 : 0) | (style.italic ? 2 : 0) | (style.underline ? 4 : 0)
            cached(row,"Style",Double(bits));cached(row,"Strikethru",style.strikethrough ? 1 : 0)
            if VisioXML.value(row,"Color") != String(style.color.prefix(7)) { VisioXML.set(row,"Color",String(style.color.prefix(7))) }
            cached(row,"ColorTrans",style.color.count == 9 ? 1-Double(UInt8(style.color.suffix(2),radix:16) ?? 255)/255 : 0)
            let font = style.fontName == "System" ? "Arial" : style.fontName
            VisioXML.set(row,"Font",font,formula:"FONT(\"\(font)\")")
        }
        for (i,style) in paragraphs.enumerated() {
            let target = row("Paragraph",pi[i],style.sourceIndex,style.cells)
            for (name,cell) in style.cells where ShapeParagraphStyle.editableLengthCells.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                let existing = target.elementsLocal("Cell").first { $0.attr("N")?.caseInsensitiveCompare(name) == .orderedSame }
                guard existing?.attr("V") != cell.value || (existing?.attr("F") ?? "") != cell.formula || (existing?.attr("U") ?? "") != cell.unit else { continue }
                let entry = existing ?? VisioXML.set(target,name,cell.value)
                entry.setAttr("V",cell.value)
                entry.setAttr("F",cell.formula.isEmpty ? nil : cell.formula)
                entry.setAttr("U",cell.unit.isEmpty ? nil : cell.unit)
            }
            cached(target,"HorzAlign",style.alignment == .left ? 0 : style.alignment == .right ? 2 : 1)
        }
        for text in element.elementsLocal("Text") { text.detach() }
        let text = XMLElement(name:"Text");element.addChild(text)
        for (i,run) in runs.enumerated() {
            if i == 0 || cp[i] != cp[i-1] { let marker = XMLElement(name:"cp");marker.setAttr("IX",String(ci[cp[i]]));text.addChild(marker) }
            if i == 0 || pp[i] != pp[i-1] { let marker = XMLElement(name:"pp");marker.setAttr("IX",String(pi[pp[i]]));text.addChild(marker) }
            if let index = run.fieldIndex { let field = XMLElement(name:"fld");field.setAttr("IX",String(index));field.addChild(XMLNode.text(withStringValue:run.text) as! XMLNode);text.addChild(field) }
            else { text.addChild(XMLNode.text(withStringValue:run.text) as! XMLNode) }
        }
    }
    static func synchronizeSources(_ runs:[ShapeTextRun],text:XMLElement) -> [ShapeTextRun] {
        var markers:[(offset:Int,character:Int,paragraph:Int)] = [(0,0,0)],offset = 0,character = 0,paragraph = 0
        for child in text.children ?? [] {
            if let el = child as? XMLElement,el.localTag == "cp" || el.localTag == "pp" {
                if el.localTag == "cp" { character = Int(el.attr("IX") ?? "0") ?? 0 } else { paragraph = Int(el.attr("IX") ?? "0") ?? 0 }
                markers.append((offset,character,paragraph))
            } else { offset += (child.stringValue ?? "").utf16.count }
        }
        var position = 0
        return runs.map { input in var run = input
            if let marker = markers.last(where:{$0.offset <= position}) { run.character.sourceIndex = marker.character;run.paragraph.sourceIndex = marker.paragraph }
            position += run.text.utf16.count;return run
        }
    }
}
