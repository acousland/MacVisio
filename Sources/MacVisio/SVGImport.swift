import AppKit

enum SVGImport {
    struct Result { var page:DiagramPage; var warnings:[String] }
    static func numbers(_ string:String) -> [Double] {
        let regex = try! NSRegularExpression(pattern:"[-+]?(?:[0-9]*\\.[0-9]+|[0-9]+\\.?[0-9]*)(?:[eE][-+]?[0-9]+)?")
        return regex.matches(in:string,range:NSRange(string.startIndex...,in:string)).compactMap{Range($0.range,in:string).flatMap{Double(string[$0])}}
    }
    static func page(_ data:Data,name:String) throws -> Result {
        let xml = try VisioXML.document(data)
        guard let root = xml.rootElement(),root.localTag == "svg" else { throw DiagramError.invalid("The converter did not produce an SVG page.") }
        let box = numbers(root.attr("viewBox") ?? "")
        func dimension(_ name:String,_ fallback:Double) -> Double {
            guard let s = root.attr(name),let value = numbers(s).first else { return fallback }
            if s.hasSuffix("in") { return value*72 }; if s.hasSuffix("cm") { return value*72/2.54 }; if s.hasSuffix("mm") { return value*72/25.4 }; if s.hasSuffix("pt") { return value }; return value*0.75
        }
        let w = dimension("width",box.count == 4 ? box[2] : 1120),h = dimension("height",box.count == 4 ? box[3] : 840)
        guard w.isFinite,h.isFinite,(1...20000).contains(w),(1...20000).contains(h) else { throw DiagramError.invalid("The converted page dimensions are invalid.") }
        var page = DiagramPage(name:name,width:w,height:h)
        var warnings = Set<String>()
        let sx = box.count == 4 && box[2] > 0 ? w/box[2] : 0.75,sy = box.count == 4 && box[3] > 0 ? h/box[3] : 0.75
        let base = CGAffineTransform(a:sx,b:0,c:0,d:sy,tx:box.count == 4 ? -box[0]*sx : 0,ty:box.count == 4 ? -box[1]*sy : 0)
        func styles(_ element:XMLElement,_ inherited:[String:String]) -> [String:String] {
            var values = inherited
            for a in element.attributes ?? [] { if let key = a.name,let value = a.stringValue { values[key] = value } }
            for pair in (element.attr("style") ?? "").split(separator:";") {
                let pieces = pair.split(separator:":",maxSplits:1)
                if pieces.count == 2 { values[pieces[0].trimmingCharacters(in:.whitespacesAndNewlines)] = pieces[1].trimmingCharacters(in:.whitespacesAndNewlines) }
            }; return values
        }
        func color(_ value:String?,opacity:String?) -> String {
            let raw = (value ?? "black").trimmingCharacters(in:.whitespacesAndNewlines)
            if raw == "none" || raw == "transparent" { return "#FFFFFF00" }
            var c:String
            if raw.hasPrefix("#"),raw.count == 4 { c = "#"+raw.dropFirst().map{String(repeating:String($0),count:2)}.joined() }
            else if raw.hasPrefix("#"),raw.count == 7 || raw.count == 9 { c = raw.uppercased() }
            else if raw.hasPrefix("rgb"),numbers(raw).count >= 3 { let n = numbers(raw).prefix(3).map{Int(max(0,min(255,$0)))}; c = String(format:"#%02X%02X%02X",n[0],n[1],n[2]) }
            else { c = ["black":"#000000","white":"#FFFFFF","red":"#FF0000","blue":"#0000FF","green":"#008000","gray":"#808080","grey":"#808080"][raw] ?? "#000000" }
            if let opacity = opacity.flatMap(Double.init),opacity < 1 { c = String(c.prefix(7))+String(format:"%02X",Int(max(0,min(255,opacity*255)))) }; return c
        }
        func shape(_ commands:[VectorCommand],style:[String:String],transform:CGAffineTransform) -> DiagramNode? {
            guard !commands.isEmpty,commands.allSatisfy(\.isValid) else { return nil }
            let transformed = commands.map { command -> VectorCommand in
                var values:[Double] = []; for i in stride(from:0,to:command.values.count,by:2) { let p = CGPoint(x:command.values[i],y:command.values[i+1]).applying(transform); values += [p.x,p.y] }; return VectorCommand(kind:command.kind,values:values)
            }
            let path = DiagramDrawing.vectorPath(VectorPath(commands:transformed),in:CGRect(x:0,y:0,width:1,height:1)),bounds = path.bounds
            guard !bounds.isNull,[bounds.minX,bounds.minY,bounds.width,bounds.height].allSatisfy({$0.isFinite}),abs(bounds.minX)<100000,abs(bounds.minY)<100000 else { return nil }
            var node = DiagramNode(x:bounds.minX,y:bounds.minY,text:""); node.width = max(0.01,bounds.width); node.height = max(0.01,bounds.height)
            let normalized = transformed.map { command -> VectorCommand in var v = command.values; for i in stride(from:0,to:v.count,by:2) { v[i] = (v[i]-node.x)/node.width; v[i+1] = (v[i+1]-node.y)/node.height }; return VectorCommand(kind:command.kind,values:v) }
            node.fill = color(style["fill"],opacity:style["fill-opacity"] ?? style["opacity"])
            node.stroke = color(style["stroke"] ?? "none",opacity:style["stroke-opacity"] ?? style["opacity"])
            node.strokeWidth = max(0,min(100,(Double(style["stroke-width"] ?? "1") ?? 1)*sqrt(abs(transform.a*transform.d-transform.b*transform.c))))
            node.formatting.paths = [VectorPath(commands:normalized,fill:node.fill != "#FFFFFF00",stroke:node.stroke != "#FFFFFF00",evenOdd:style["fill-rule"] == "evenodd")]
            return node
        }
        func visit(_ element:XMLElement,style:[String:String],transform:CGAffineTransform,depth:Int) throws -> [DiagramNode] {
            guard depth < 64 else { throw DiagramError.invalid("The SVG hierarchy is too deeply nested.") }
            let style = styles(element,style)
            if style["display"] == "none" || style["visibility"] == "hidden" { return [] }
            let local = parseTransform(element.attr("transform") ?? "").concatenating(transform)
            func n(_ key:String,_ fallback:Double = 0) -> Double { numbers(element.attr(key) ?? "").first ?? fallback }
            switch element.localTag {
            case "defs","clipPath","mask","metadata","title","desc","style","script": return []
            case "path": return shape(try SVGPath.parse(element.attr("d") ?? ""),style:style,transform:local).map{[$0]} ?? []
            case "rect":
                let x = n("x"),y = n("y"),w = n("width"),h = n("height")
                return shape([VectorCommand("M",x,y),VectorCommand("L",x+w,y),VectorCommand("L",x+w,y+h),VectorCommand("L",x,y+h),VectorCommand("Z")],style:style,transform:local).map{[$0]} ?? []
            case "line": return shape([VectorCommand("M",n("x1"),n("y1")),VectorCommand("L",n("x2"),n("y2"))],style:style,transform:local).map{[$0]} ?? []
            case "polygon","polyline":
                let p = numbers(element.attr("points") ?? ""); var commands:[VectorCommand] = []
                for i in stride(from:0,to:p.count-1,by:2) { commands.append(VectorCommand(i == 0 ? "M" : "L",p[i],p[i+1])) }; if element.localTag == "polygon" { commands.append(VectorCommand("Z")) }
                return shape(commands,style:style,transform:local).map{[$0]} ?? []
            case "ellipse","circle":
                let cx = n("cx"),cy = n("cy"),rx = n("rx",n("r")),ry = n("ry",n("r")),k = 0.552284749831
                let c = [VectorCommand("M",cx+rx,cy),VectorCommand("C",cx+rx,cy+k*ry,cx+k*rx,cy+ry,cx,cy+ry),VectorCommand("C",cx-k*rx,cy+ry,cx-rx,cy+k*ry,cx-rx,cy),VectorCommand("C",cx-rx,cy-k*ry,cx-k*rx,cy-ry,cx,cy-ry),VectorCommand("C",cx+k*rx,cy-ry,cx+rx,cy-k*ry,cx+rx,cy),VectorCommand("Z")]
                return shape(c,style:style,transform:local).map{[$0]} ?? []
            case "image":
                let href = element.attr("xlink:href") ?? element.attr("href") ?? ""
                guard href.hasPrefix("data:"),let comma = href.firstIndex(of:","),let bytes = Data(base64Encoded:String(href[href.index(after:comma)...])),bytes.count <= VisioPackage.partLimit else { warnings.insert("An SVG image without supported embedded data was omitted."); return [] }
                let center = CGPoint(x:n("x")+n("width")/2,y:n("y")+n("height")/2).applying(local)
                var node = DiagramNode(x:0,y:0,text:""); node.width = max(0.01,n("width")*hypot(local.a,local.b)); node.height = max(0.01,n("height")*hypot(local.c,local.d)); node.x = center.x-node.width/2; node.y = center.y-node.height/2; node.rotation = atan2(local.b,local.a)*180 / .pi
                node.formatting.image = EmbeddedImage(data:bytes,mimeType:String(href.dropFirst(5).prefix(while:{$0 != ";" && $0 != ","}))); node.fill = "#FFFFFF00"; node.stroke = "#FFFFFF00"; return [node]
            case "text":
                let first = element.elementsLocal("tspan").first
                let textStyle = first.map{styles($0,style)} ?? style
                let size = max(1,min(500,numbers(textStyle["font-size"] ?? "12").first ?? 12)),scale = hypot(local.a,local.b)
                var node = DiagramNode(kind:.text,x:0,y:0,text:"");node.fontSize = max(1,min(500,size*scale));node.formatting.alignment = .left
                var runs:[ShapeTextRun] = []
                func collect(_ el:XMLElement,_ inherited:[String:String],_ depth:Int) {
                    guard depth < 64 else { return }
                    let style = styles(el,inherited)
                    var character = ShapeCharacterStyle(node:node)
                    character.fontName = style["font-family"]?.replacingOccurrences(of:"'",with:"") ?? "Arial"
                    character.size = max(1,min(500,(numbers(style["font-size"] ?? "12").first ?? 12)*scale))
                    character.bold = style["font-weight"] == "bold" || (Double(style["font-weight"] ?? "") ?? 0) >= 600;character.italic = style["font-style"] == "italic"
                    character.underline = style["text-decoration"]?.contains("underline") == true;character.strikethrough = style["text-decoration"]?.contains("line-through") == true
                    character.color = color(style["fill"],opacity:style["fill-opacity"])
                    let paragraph = ShapeParagraphStyle(alignment:style["text-anchor"] == "middle" ? .center : style["text-anchor"] == "end" ? .right : .left)
                    for child in el.children ?? [] {
                        if let child = child as? XMLElement { collect(child,style,depth+1) }
                        else if child.kind == .text {
                            var text = child.stringValue ?? ""
                            // librevenge's pretty SVG starts each tspan with a newline.
                            if el.localTag == "tspan",text.hasPrefix("\n"),style["space"] != "preserve",el.attr("xml:space") != "preserve" { text.removeFirst() }
                            if el.localTag == "text",text.contains("\n"),text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { continue }
                            guard !text.isEmpty else { continue }
                            if let last = runs.last,last.character == character,last.paragraph == paragraph { runs[runs.count-1].text += text } else { runs.append(ShapeTextRun(text:text,character:character,paragraph:paragraph)) }
                        }
                    }
                }
                collect(element,style,0);node.text = runs.map(\.text).joined();guard !node.text.isEmpty else { return [] }
                node.formatting.textRuns = runs
                if let first = runs.first { node.fontSize = first.character.size;node.formatting.fontName = first.character.fontName;node.bold = first.character.bold;node.textColor = first.character.color;node.formatting.italic = first.character.italic;node.formatting.underline = first.character.underline }
                // Parsing remains on the owned worker. FontManager/TextKit
                // measurement is one isolated main-thread operation per text
                // shape, so a converter cannot perform shared AppKit work on
                // its worker or monopolize the main loop for the whole file.
                let measure = { ShapeRichText.attributed(node).boundingRect(with:CGSize(width:10000,height:10000),options:[.usesLineFragmentOrigin]) }
                let bounds = Thread.isMainThread ? measure() : DispatchQueue.main.sync(execute:measure)
                node.width = max(1,bounds.width+4);node.height = max(1,bounds.height)
                let x = n("x",numbers(first?.attr("x") ?? "").first ?? 0),y = n("y",numbers(first?.attr("y") ?? "").first ?? 0)
                let point = CGPoint(x:x,y:y-size*0.8).applying(local); node.x = point.x; node.y = point.y
                if textStyle["text-anchor"] == "middle" { node.x -= node.width/2 }; if textStyle["text-anchor"] == "end" { node.x -= node.width }
                node.rotation = atan2(local.b,local.a)*180 / .pi;node.formatting.textBox = ShapeTextBox(verticalAlignment:0);return [node]
            default:
                var nodes:[DiagramNode] = []
                for child in (element.children ?? []).compactMap({$0 as? XMLElement}) { nodes += try visit(child,style:style,transform:local,depth:depth+1) }
                if element.localTag == "g",depth >= 2,nodes.count > 1 {
                    let roots = nodes.filter{$0.parentID == nil},bounds = roots.reduce(CGRect.null){$0.union($1.rect)}
                    if !bounds.isNull { var group = DiagramNode(x:bounds.minX,y:bounds.minY,text:""); group.width = max(0.01,bounds.width); group.height = max(0.01,bounds.height); group.formatting.isGroup = true; group.fill = "#FFFFFF00"; group.stroke = "#FFFFFF00"; for i in nodes.indices where nodes[i].parentID == nil { nodes[i].parentID = group.id }; nodes.insert(group,at:0) }
                }
                guard nodes.count <= 50000 else { throw DiagramError.invalid("The converted page has too many shapes.") }; return nodes
            }
        }
        page.nodes = try visit(root,style:[:],transform:base,depth:0)
        return Result(page:page,warnings:warnings.sorted())
    }
    static func parseTransform(_ text:String) -> CGAffineTransform {
        let regex = try! NSRegularExpression(pattern:"([A-Za-z]+)\\s*\\(([^)]*)\\)")
        var transform = CGAffineTransform.identity
        for match in regex.matches(in:text,range:NSRange(text.startIndex...,in:text)) {
            let name = String(text[Range(match.range(at:1),in:text)!]),v = numbers(String(text[Range(match.range(at:2),in:text)!]))
            var next = CGAffineTransform.identity
            switch name {
            case "matrix" where v.count == 6: next = CGAffineTransform(a:v[0],b:v[1],c:v[2],d:v[3],tx:v[4],ty:v[5])
            case "translate" where !v.isEmpty: next = CGAffineTransform(translationX:v[0],y:v.count > 1 ? v[1] : 0)
            case "scale" where !v.isEmpty: next = CGAffineTransform(scaleX:v[0],y:v.count > 1 ? v[1] : v[0])
            case "rotate" where !v.isEmpty:
                if v.count >= 3 { next = CGAffineTransform(translationX:-v[1],y:-v[2]).rotated(by:v[0] * .pi/180).translatedBy(x:v[1],y:v[2]) } else { next = CGAffineTransform(rotationAngle:v[0] * .pi/180) }
            case "skewX" where !v.isEmpty: next = CGAffineTransform(a:1,b:0,c:tan(v[0] * .pi/180),d:1,tx:0,ty:0)
            case "skewY" where !v.isEmpty: next = CGAffineTransform(a:1,b:tan(v[0] * .pi/180),c:0,d:1,tx:0,ty:0)
            default: break
            }; transform = next.concatenating(transform)
        }; return transform
    }
}
