import AppKit

extension NSColor {
    convenience init(hex: String) {
        let raw = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let n = UInt64(raw, radix: 16) ?? 0x4375BC
        if raw.count == 8 {
            self.init(srgbRed: Double((n >> 24) & 255)/255, green: Double((n >> 16) & 255)/255,
                      blue: Double((n >> 8) & 255)/255, alpha: Double(n & 255)/255)
        } else {
            self.init(srgbRed: Double((n >> 16) & 255)/255, green: Double((n >> 8) & 255)/255, blue: Double(n & 255)/255, alpha: 1)
        }
    }
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#4375BC" }
        if c.alphaComponent < 0.01 { return "#FFFFFF00" }
        let rgb = String(format: "#%02X%02X%02X", Int((c.redComponent*255).rounded()), Int((c.greenComponent*255).rounded()), Int((c.blueComponent*255).rounded()))
        return c.alphaComponent < 0.999 ? rgb + String(format:"%02X",Int((c.alphaComponent*255).rounded())) : rgb
    }
}

enum DiagramDrawing {
    private static let imageCache = NSCache<NSData,NSImage>()
    private static func layerColor(_ color:String,transparency:Double) -> String {
        NSColor(hex:color).withAlphaComponent(1-max(0,min(100,transparency))/100).hexString
    }
    private static func layerColored(_ node:DiagramNode,in page:DiagramPage) -> DiagramNode {
        let names = Set(node.formatting.layerNames+[node.layer])
        guard names.count == 1,let name = names.first,let layer = page.layers?.first(where:{$0.name == name}),let color = layer.color else { return node }
        var result = node;let displayColor = layerColor(color,transparency:layer.colorTransparency)
        result.fill = displayColor;result.stroke = displayColor;result.textColor = displayColor
        var details = result.formatting
        if var runs = details.textRuns {
            for index in runs.indices { runs[index].character.color = displayColor }
            details.textRuns = runs;result.formatting = details
        }
        return result
    }
    private static func layerColored(_ edge:DiagramEdge,in page:DiagramPage) -> DiagramEdge {
        guard let name = edge.layer,let layer = page.layers?.first(where:{$0.name == name}),let color = layer.color else { return edge }
        var result = edge;result.color = layerColor(color,transparency:layer.colorTransparency);return result
    }
    static func vectorPath(_ vector:VectorPath,in r:CGRect) -> NSBezierPath {
        let path = NSBezierPath()
        path.windingRule = vector.evenOdd == true ? .evenOdd : .nonZero
        func p(_ x:Double,_ y:Double) -> CGPoint { CGPoint(x:r.minX+x*r.width,y:r.minY+y*r.height) }
        for command in vector.commands {
            let v = command.values
            switch command.kind {
            case "M": path.move(to:p(v[0],v[1]))
            case "L": path.line(to:p(v[0],v[1]))
            case "C": path.curve(to:p(v[4],v[5]),controlPoint1:p(v[0],v[1]),controlPoint2:p(v[2],v[3]))
            case "Q":
                let a = path.currentPoint,c = p(v[0],v[1]),end = p(v[2],v[3])
                path.curve(to:end,controlPoint1:CGPoint(x:a.x+2*(c.x-a.x)/3,y:a.y+2*(c.y-a.y)/3),controlPoint2:CGPoint(x:end.x+2*(c.x-end.x)/3,y:end.y+2*(c.y-end.y)/3))
            case "Z": path.close()
            default: break
            }
        }; return path
    }
    static func outline(for n:DiagramNode) -> NSBezierPath {
        guard !n.formatting.paths.isEmpty else { return n.formatting.geometry == nil ? path(for:n.kind,in:n.rect) : NSBezierPath() }
        let combined = NSBezierPath(); for vector in n.formatting.paths { combined.append(vectorPath(vector,in:n.rect)) }; return combined
    }
    static func font(for n:DiagramNode) -> NSFont {
        var font = n.formatting.fontName == "System" ? NSFont.systemFont(ofSize:n.fontSize) : NSFont(name:n.formatting.fontName,size:n.fontSize) ?? NSFont.systemFont(ofSize:n.fontSize)
        if n.bold { font = NSFontManager.shared.convert(font,toHaveTrait:.boldFontMask) }
        if n.formatting.italic { font = NSFontManager.shared.convert(font,toHaveTrait:.italicFontMask) }; return font
    }
    static func dash(_ pattern:Int) -> [CGFloat] { switch pattern { case 2:return [6,4]; case 3:return [1,3]; case 4:return [7,3,1,3]; case 5:return [7,3,1,3,1,3]; default:return [] } }
    static func textRect(for n:DiagramNode) -> CGRect {
        if let box = n.formatting.textBox { return box.rect(in:n) }
        var rect = n.rect.insetBy(dx:10,dy:8)
        if n.kind == .diamond { rect = n.rect.insetBy(dx:n.width*0.22,dy:n.height*0.22) }
        if n.kind == .triangle { rect.origin.y += n.height*0.3;rect.size.height -= n.height*0.3 }
        if n.kind == .person { rect = CGRect(x:n.x-30,y:n.y+n.height+5,width:n.width+60,height:40) }
        if n.kind == .swimlane { rect = CGRect(x:n.x+8,y:n.y+10,width:max(1,min(110,n.width*0.25)-16),height:n.height-20) }
        return rect
    }
    static func path(for kind: ShapeKind, in r: CGRect) -> NSBezierPath {
        let p = NSBezierPath()
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x:r.minX+x*r.width,y:r.minY+y*r.height) }
        func polygon(_ points: [(Double, Double)]) {
            guard let first = points.first else { return }
            p.move(to:point(first.0,first.1)); for v in points.dropFirst() { p.line(to:point(v.0,v.1)) }; p.close()
        }
        switch kind {
        case .rectangle, .text, .swimlane: return NSBezierPath(rect:r)
        case .roundedRectangle: return NSBezierPath(roundedRect:r,xRadius:min(r.height/2,22),yRadius:min(r.height/2,22))
        case .ellipse: return NSBezierPath(ovalIn:r)
        case .diamond: polygon([(0.5,0),(1,0.5),(0.5,1),(0,0.5)])
        case .parallelogram: polygon([(0.16,0),(1,0),(0.84,1),(0,1)])
        case .hexagon: polygon([(0.17,0),(0.83,0),(1,0.5),(0.83,1),(0.17,1),(0,0.5)])
        case .triangle: polygon([(0.5,0),(1,1),(0,1)])
        case .document:
            p.move(to:point(0,0)); p.line(to:point(1,0)); p.line(to:point(1,0.84))
            p.curve(to:point(0,0.9),controlPoint1:point(0.7,0.65),controlPoint2:point(0.3,1.14)); p.close()
        case .cylinder:
            p.move(to:point(0,0.13)); p.curve(to:point(1,0.13),controlPoint1:point(0,-0.045),controlPoint2:point(1,-0.045))
            p.line(to:point(1,0.87)); p.curve(to:point(0,0.87),controlPoint1:point(1,1.045),controlPoint2:point(0,1.045)); p.close()
        case .cloud:
            p.move(to:point(0.18,0.8))
            p.curve(to:point(0.1,0.34),controlPoint1:point(-0.07,0.8),controlPoint2:point(-0.02,0.35))
            p.curve(to:point(0.43,0.18),controlPoint1:point(0.06,0.03),controlPoint2:point(0.3,-0.04))
            p.curve(to:point(0.82,0.25),controlPoint1:point(0.6,-0.06),controlPoint2:point(0.85,0.03))
            p.curve(to:point(0.84,0.83),controlPoint1:point(1.1,0.2),controlPoint2:point(1.1,0.88))
            p.curve(to:point(0.18,0.8),controlPoint1:point(0.62,1.05),controlPoint2:point(0.35,0.98)); p.close()
        case .person:
            p.appendOval(in:CGRect(x:r.minX+r.width*0.32,y:r.minY,width:r.width*0.36,height:r.height*0.25))
            p.move(to:point(0.5,0.27)); p.line(to:point(0.5,0.65)); p.move(to:point(0.12,0.46)); p.line(to:point(0.88,0.46))
            p.move(to:point(0.5,0.65)); p.line(to:point(0.15,1)); p.move(to:point(0.5,0.65)); p.line(to:point(0.85,1))
        }
        return p
    }
    static func drawNode(_ input: DiagramNode, shadow: Bool = true,paperScale:Double = 1) {
        var n = input;n.fontSize /= paperScale;n.strokeWidth /= paperScale
        NSGraphicsContext.saveGraphicsState()
        let transform = AffineTransform(translationByX:n.center.x,byY:n.center.y)
        let t = NSAffineTransform(transform:transform)
        t.rotate(byDegrees:CGFloat(n.rotation)); t.scaleX(by:n.formatting.flipX ? -1 : 1,yBy:n.formatting.flipY ? -1 : 1); t.translateX(by:-n.center.x,yBy:-n.center.y); t.concat()
        let p = outline(for:n)
        NSColor(hex:n.fill).setFill()
        if let image = n.formatting.image {
            let key = image.data as NSData
            let bitmap = imageCache.object(forKey:key) ?? NSImage(data:image.data)
            if let bitmap = bitmap { imageCache.setObject(bitmap,forKey:key,cost:image.data.count); bitmap.draw(in:n.rect,from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil) }
        } else if !n.formatting.paths.isEmpty {
            for vector in n.formatting.paths {
                let path = vectorPath(vector,in:n.rect)
                if vector.fill { NSColor(hex:n.fill).setFill(); path.fill() }
                if vector.stroke { NSColor(hex:n.stroke).setStroke(); path.lineWidth = n.strokeWidth; path.lineJoinStyle = .round; let d = dash(n.formatting.linePattern); if !d.isEmpty { path.setLineDash(d,count:d.count,phase:0) }; path.stroke() }
            }
        } else if shadow && n.kind != .text && n.kind != .swimlane && !n.formatting.isGroup {
            NSGraphicsContext.saveGraphicsState()
            let s = NSShadow(); s.shadowColor = NSColor.black.withAlphaComponent(0.055); s.shadowOffset = NSSize(width:0,height:2/paperScale); s.shadowBlurRadius = 5/paperScale; s.set(); p.fill()
            NSGraphicsContext.restoreGraphicsState()
        } else if !n.formatting.isGroup { p.fill() }
        if n.formatting.paths.isEmpty && n.formatting.image == nil && !n.formatting.isGroup { NSColor(hex:n.stroke).setStroke(); p.lineWidth = n.strokeWidth; p.lineJoinStyle = .round; let d = dash(n.formatting.linePattern); if !d.isEmpty { p.setLineDash(d,count:d.count,phase:0) }; p.stroke() }
        if n.kind == .cylinder && n.formatting.paths.isEmpty && n.formatting.geometry == nil {
            let cap = NSBezierPath(ovalIn:CGRect(x:n.x,y:n.y,width:n.width,height:n.height*0.26)); cap.lineWidth = n.strokeWidth; cap.stroke()
        }
        if n.kind == .swimlane && n.formatting.geometry == nil {
            let header = min(110,n.width*0.25)
            let separator = NSBezierPath(); separator.move(to:CGPoint(x:n.x+header,y:n.y)); separator.line(to:CGPoint(x:n.x+header,y:n.y+n.height)); separator.lineWidth = n.strokeWidth; separator.stroke()
        }
        // Keep text glyphs readable while reflecting their block's placement.
        NSGraphicsContext.restoreGraphicsState();NSGraphicsContext.saveGraphicsState()
        let textFrame = NSAffineTransform();textFrame.translateX(by:n.center.x,yBy:n.center.y);textFrame.rotate(byDegrees:n.rotation);textFrame.translateX(by:-n.center.x,yBy:-n.center.y);textFrame.concat()
        let paper = NSAffineTransform();paper.scale(by:1/paperScale);paper.concat();n = DrawingScale.paperNode(input,factor:paperScale)
        let layout = textLayout(for:n);var textRect = layout.rect
        if layout.rotation != 0 { let t = NSAffineTransform();t.translateX(by:layout.center.x,yBy:layout.center.y);t.rotate(byDegrees:layout.rotation);t.translateX(by:-layout.center.x,yBy:-layout.center.y);t.concat() }
        let string = ShapeRichText.attributed(n)
        let measured = string.boundingRect(with:CGSize(width:max(1,textRect.width),height:10000),options:[.usesLineFragmentOrigin,.usesFontLeading])
        let h = min(textRect.height,ceil(measured.height))
        let vertical = n.formatting.textBox?.verticalAlignment ?? 1
        textRect.origin.y += max(0,(textRect.height-h)*(vertical == 0 ? 0 : vertical == 2 ? 1 : 0.5)); textRect.size.height = h
        string.draw(with:textRect,options:[.usesLineFragmentOrigin,.usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }
    static func textLayout(for node:DiagramNode) -> (rect:CGRect,center:CGPoint,rotation:Double) {
        func reflect(_ point:CGPoint) -> CGPoint { CGPoint(x:node.formatting.flipX ? 2*node.center.x-point.x : point.x,y:node.formatting.flipY ? 2*node.center.y-point.y : point.y) }
        if let box = node.formatting.textBox {
            let center = reflect(CGPoint(x:node.x+box.centerX*node.width,y:node.y+box.centerY*node.height))
            let rect = CGRect(x:center.x-box.width*node.width/2+box.left,y:center.y-box.height*node.height/2+box.top,width:max(1,box.width*node.width-box.left-box.right),height:max(1,box.height*node.height-box.top-box.bottom))
            return (rect,center,box.rotation*(node.formatting.flipX != node.formatting.flipY ? -1 : 1))
        }
        let rect = textRect(for:node),center = reflect(CGPoint(x:rect.midX,y:rect.midY))
        return (CGRect(x:center.x-rect.width/2,y:center.y-rect.height/2,width:rect.width,height:rect.height),center,0)
    }
    static func drawEdge(_ edge: DiagramEdge, in page: DiagramPage, selected: Bool = false) {
        let unit = 1/page.paperScale;var edge = edge;edge.width *= unit
        let points = DiagramGeometry.route(edge,in:page)
        guard let first = points.first, let last = points.last else { return }
        let path = NSBezierPath(); path.move(to:first); for p in points.dropFirst() { path.line(to:p) }
        path.lineJoinStyle = .round; path.lineCapStyle = .round
        let dash = self.dash(edge.dash ?? 1).map{$0*CGFloat(unit)}; if !dash.isEmpty { path.setLineDash(dash,count:dash.count,phase:0) }
        if selected { NSColor(hex:"#8BB5FF").withAlphaComponent(0.35).setStroke(); path.lineWidth = edge.width+7*unit; path.stroke() }
        NSColor(hex:edge.color).setStroke(); path.lineWidth = edge.width; path.stroke()
        if edge.arrow, let previous = points.dropLast().last(where: { hypot($0.x-last.x,$0.y-last.y)>0.5 }) {
            let angle = atan2(last.y-previous.y,last.x-previous.x), size = 8*unit+edge.width
            let arrow = NSBezierPath(); arrow.move(to:last)
            arrow.line(to:CGPoint(x:last.x-size*cos(angle-0.4),y:last.y-size*sin(angle-0.4)))
            arrow.line(to:CGPoint(x:last.x-size*cos(angle+0.4),y:last.y-size*sin(angle+0.4))); arrow.close()
            NSColor(hex:edge.color).setFill(); arrow.fill()
        }
        if edge.startArrow == true,let next = points.dropFirst().first(where:{hypot($0.x-first.x,$0.y-first.y)>0.5}) {
            let angle = atan2(first.y-next.y,first.x-next.x),size = 8*unit+edge.width
            let arrow = NSBezierPath();arrow.move(to:first);arrow.line(to:CGPoint(x:first.x-size*cos(angle-0.4),y:first.y-size*sin(angle-0.4)));arrow.line(to:CGPoint(x:first.x-size*cos(angle+0.4),y:first.y-size*sin(angle+0.4)));arrow.close();NSColor(hex:edge.color).setFill();arrow.fill()
        }
        if !edge.label.isEmpty {
            NSGraphicsContext.saveGraphicsState();let paper = NSAffineTransform();paper.scale(by:unit);paper.concat()
            let mid = points.count > 2 ? CGPoint(x:(points[1].x+points[2].x)/2,y:(points[1].y+points[2].y)/2) : CGPoint(x:(first.x+last.x)/2,y:(first.y+last.y)/2),middle = CGPoint(x:mid.x*page.paperScale,y:mid.y*page.paperScale)
            let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:12,weight:.medium),.foregroundColor:NSColor(hex:edge.color)]
            let size = (edge.label as NSString).size(withAttributes:attrs)
            let box = CGRect(x:middle.x-size.width/2-5,y:middle.y-size.height/2-3,width:size.width+10,height:size.height+6)
            NSColor.white.setFill(); NSBezierPath(roundedRect:box,xRadius:4,yRadius:4).fill()
            (edge.label as NSString).draw(at:CGPoint(x:box.minX+5,y:box.minY+3),withAttributes:attrs);NSGraphicsContext.restoreGraphicsState()
        }
    }
    static func drawContents(_ page:DiagramPage,printing:Bool = true,shadow:Bool = false) {
        for n in page.nodes where n.kind == .swimlane && page.isVisible(n,printing:printing) { drawNode(layerColored(n,in:page),shadow:false,paperScale:page.paperScale) }
        for e in page.edges where page.isVisible(e,printing:printing) { drawEdge(layerColored(e,in:page),in:page) }
        for n in page.nodes where n.kind != .swimlane && page.isVisible(n,printing:printing) { drawNode(layerColored(n,in:page),shadow:shadow,paperScale:page.paperScale) }
    }
    static func drawPage(_ page:DiagramPage) { drawPage(DiagramScene(page:page)) }
    static func drawPage(_ scene:DiagramScene) {
        let rect = CGRect(x:0,y:0,width:scene.page.paperWidth,height:scene.page.paperHeight)
        NSGraphicsContext.saveGraphicsState();NSBezierPath(rect:rect).addClip();NSColor.white.setFill();rect.fill()
        for page in scene.layers {
            NSGraphicsContext.saveGraphicsState();let t = NSAffineTransform(),offset = scene.offset(for:page);t.translateX(by:offset.x,yBy:offset.y);t.scale(by:page.paperScale);t.concat();drawContents(page);NSGraphicsContext.restoreGraphicsState()
        };NSGraphicsContext.restoreGraphicsState()
    }
    static func svg(_ page:DiagramPage) -> String { svg(DiagramScene(page:page)) }
    static func svg(_ scene:DiagramScene) -> String {
        let page = scene.page
        let body = scene.layers.map { layer in
            let offset = scene.offset(for:layer)
            return "<g transform=\"translate(\(offset.x) \(offset.y)) scale(\(layer.paperScale))\">\(svgContents(layer))</g>"
        }.joined(separator:"\n")
        let title = page.name.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;")
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?><svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(page.paperWidth)\" height=\"\(page.paperHeight)\" viewBox=\"0 0 \(page.paperWidth) \(page.paperHeight)\"><title>\(title)</title><defs><clipPath id=\"paperClip\"><rect width=\"\(page.paperWidth)\" height=\"\(page.paperHeight)\"/></clipPath></defs><rect width=\"100%\" height=\"100%\" fill=\"white\"/><g clip-path=\"url(#paperClip)\">\(body)</g></svg>"
    }
    private static func svgContents(_ page: DiagramPage) -> String {
        // SVG carries a vector drawing, not a screenshot, and is independently editable.
        func xml(_ s: String) -> String { s.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;") }
        func color(_ s: String) -> String { s.count == 9 && s.hasSuffix("00") ? "none" : xml(s) }
        func pathData(_ path:NSBezierPath) -> String {
            var d = ""
            for i in 0..<path.elementCount {
                var points = [NSPoint](repeating:.zero,count:3)
                let type = path.element(at:i,associatedPoints:&points)
                switch type {
                case .moveTo: d += "M \(points[0].x) \(points[0].y) "
                case .lineTo: d += "L \(points[0].x) \(points[0].y) "
                case .curveTo: d += "C \(points[0].x) \(points[0].y) \(points[1].x) \(points[1].y) \(points[2].x) \(points[2].y) "
                case .closePath: d += "Z "
                default: break
                }
            }; return d
        }
        let unit = 1/page.paperScale
        func shape(_ original: DiagramNode) -> String {
            var n = layerColored(original,in:page);n.fontSize *= unit;n.strokeWidth *= unit
            var geometry = ""
            let dash = self.dash(n.formatting.linePattern).map{String(Double($0)*unit)}.joined(separator:",")
            let dashAttribute = dash.isEmpty ? "" : " stroke-dasharray=\"\(dash)\""
            if let image = n.formatting.image {
                geometry = "<image x=\"\(n.x)\" y=\"\(n.y)\" width=\"\(n.width)\" height=\"\(n.height)\" preserveAspectRatio=\"none\" href=\"data:\(xml(image.mimeType));base64,\(image.data.base64EncodedString())\"/>"
            } else if !n.formatting.paths.isEmpty {
                geometry = n.formatting.paths.map { vector in
                    "<path d=\"\(pathData(vectorPath(vector,in:n.rect)))\" fill=\"\(vector.fill ? color(n.fill) : "none")\" stroke=\"\(vector.stroke ? color(n.stroke) : "none")\" stroke-width=\"\(n.strokeWidth)\" stroke-linejoin=\"round\"\(dashAttribute)/>"
                }.joined()
            } else if !n.formatting.isGroup && n.formatting.geometry == nil {
                geometry = "<path d=\"\(pathData(path(for:n.kind,in:n.rect)))\" fill=\"\(color(n.fill))\" stroke=\"\(color(n.stroke))\" stroke-width=\"\(n.strokeWidth)\" stroke-linejoin=\"round\"\(dashAttribute)/>"
            }
            var extra = ""
            if n.kind == .cylinder && n.formatting.paths.isEmpty && n.formatting.image == nil && n.formatting.geometry == nil { extra = "<ellipse cx=\"\(n.center.x)\" cy=\"\(n.y+n.height*0.13)\" rx=\"\(n.width/2)\" ry=\"\(n.height*0.13)\" fill=\"none\" stroke=\"\(color(n.stroke))\" stroke-width=\"\(n.strokeWidth)\"/>" }
            if n.kind == .swimlane && n.formatting.geometry == nil { extra = "<path d=\"M \(n.x+min(110,n.width*0.25)) \(n.y) V \(n.y+n.height)\" stroke=\"\(color(n.stroke))\" fill=\"none\"/>" }
            let transform = "translate(\(n.center.x) \(n.center.y)) rotate(\(n.rotation)) scale(\(n.formatting.flipX ? -1 : 1) \(n.formatting.flipY ? -1 : 1)) translate(\(-n.center.x) \(-n.center.y))"
            let textNode = DrawingScale.paperNode(original,factor:page.paperScale)
            if textNode.formatting.textRuns != nil {
                let layout = textLayout(for:textNode),text = ShapeRichText.svg(textNode,rect:layout.rect)
                let paperTransform = unit == 1 ? "" : "scale(\(unit)) "
                let block = layout.rotation == 0 ? "" : "rotate(\(layout.rotation) \(layout.center.x) \(layout.center.y))"
                return "<g transform=\"\(transform)\">\(geometry)\(extra)</g><g transform=\"\(paperTransform)rotate(\(textNode.rotation) \(textNode.center.x) \(textNode.center.y))\"><g transform=\"\(block)\">\(text)</g></g>"
            }
            let lines = textNode.text.components(separatedBy:"\n")
            let font = self.font(for:textNode)
            let layout = textLayout(for:textNode),textBounds = layout.rect,maxTextWidth = max(1,textBounds.width)
            var wrapped: [String] = []
            for line in lines {
                var current = ""
                for word in line.components(separatedBy:" ") {
                    let next = current.isEmpty ? word : current+" "+word
                    if !current.isEmpty && (next as NSString).size(withAttributes:[.font:font]).width > maxTextWidth { wrapped.append(current); current = word } else { current = next }
                }
                wrapped.append(current)
            }
            let maxLines = max(1,Int(textBounds.height/(textNode.fontSize*1.2)))
            wrapped = Array(wrapped.prefix(maxLines))
            let vertical = n.formatting.textBox?.verticalAlignment ?? 1,lineHeight = textNode.fontSize*1.2
            let cy = vertical == 0 ? textBounds.minY+Double(wrapped.count)*lineHeight/2 : vertical == 2 ? textBounds.maxY-Double(wrapped.count)*lineHeight/2 : textBounds.midY
            let cx = n.formatting.alignment == .left ? textBounds.minX : n.formatting.alignment == .right ? textBounds.maxX : textBounds.midX
            let text = wrapped.enumerated().map { i,line in "<tspan x=\"\(cx)\" y=\"\(cy + (Double(i)-Double(wrapped.count-1)/2)*textNode.fontSize*1.2 + textNode.fontSize*0.33)\">\(xml(line))</tspan>" }.joined()
            let style = (n.formatting.italic ? " font-style=\"italic\"" : "") + (n.formatting.underline ? " text-decoration=\"underline\"" : "")
            let family = n.formatting.fontName == "System" ? "-apple-system,Helvetica,Arial,sans-serif" : xml(n.formatting.fontName)
            let anchor = n.formatting.alignment == .left ? "start" : n.formatting.alignment == .right ? "end" : "middle"
            let textTransform = layout.rotation == 0 ? "" : " transform=\"rotate(\(layout.rotation) \(layout.center.x) \(layout.center.y))\""
            let paperTransform = unit == 1 ? "" : "scale(\(unit)) "
            return "<g transform=\"\(transform)\">\(geometry)\(extra)</g><g transform=\"\(paperTransform)rotate(\(textNode.rotation) \(textNode.center.x) \(textNode.center.y))\"><text text-anchor=\"\(anchor)\" font-family=\"\(family)\" font-size=\"\(textNode.fontSize)\" font-weight=\"\(n.bold ? 600 : 400)\" fill=\"\(color(n.textColor))\"\(style)\(textTransform)>\(text)</text></g>"
        }
        var body = page.nodes.filter { $0.kind == .swimlane && page.isVisible($0,printing:true) }.map(shape).joined(separator:"\n")
        for original in page.edges where page.isVisible(original,printing:true) {
            var e = layerColored(original,in:page);e.width *= unit
            let points = DiagramGeometry.route(e,in:page); guard let first = points.first,let last = points.last else { continue }
            let d = points.enumerated().map { "\($0.offset == 0 ? "M" : "L") \($0.element.x) \($0.element.y)" }.joined(separator:" ")
            let pattern = dash(e.dash ?? 1).map{String(Double($0)*unit)}.joined(separator:",")
            body += "<path d=\"\(d)\" fill=\"none\" stroke=\"\(color(e.color))\" stroke-width=\"\(e.width)\" stroke-dasharray=\"\(pattern.isEmpty ? "none" : pattern)\" stroke-linejoin=\"round\" stroke-linecap=\"round\"/>"
            if e.arrow,let prev = points.dropLast().last(where:{ hypot($0.x-last.x,$0.y-last.y)>0.5 }) {
                let a = atan2(last.y-prev.y,last.x-prev.x),s = 8*unit+e.width
                body += "<path d=\"M \(last.x) \(last.y) L \(last.x-s*cos(a-0.4)) \(last.y-s*sin(a-0.4)) L \(last.x-s*cos(a+0.4)) \(last.y-s*sin(a+0.4)) Z\" fill=\"\(color(e.color))\"/>"
            }
            if e.startArrow == true,let next = points.dropFirst().first(where:{hypot($0.x-first.x,$0.y-first.y)>0.5}) {
                let a = atan2(first.y-next.y,first.x-next.x),s = 8*unit+e.width
                body += "<path d=\"M \(first.x) \(first.y) L \(first.x-s*cos(a-0.4)) \(first.y-s*sin(a-0.4)) L \(first.x-s*cos(a+0.4)) \(first.y-s*sin(a+0.4)) Z\" fill=\"\(color(e.color))\"/>"
            }
            if !e.label.isEmpty {
                let mid = points.count > 2 ? CGPoint(x:(points[1].x+points[2].x)/2,y:(points[1].y+points[2].y)/2) : CGPoint(x:(first.x+last.x)/2,y:(first.y+last.y)/2)
                body += "<text x=\"\(mid.x)\" y=\"\(mid.y-5*unit)\" text-anchor=\"middle\" font-family=\"Helvetica,Arial,sans-serif\" font-size=\"\(12*unit)\" fill=\"\(color(e.color))\" stroke=\"white\" stroke-width=\"\(5*unit)\" paint-order=\"stroke\">\(xml(e.label))</text>"
            }
        }
        body += page.nodes.filter { $0.kind != .swimlane && page.isVisible($0,printing:true) }.map(shape).joined(separator:"\n")
        return body
    }
}

final class ExportPageView: NSView {
    let scene:DiagramScene
    var page:DiagramPage { scene.page }
    init(scene:DiagramScene) { self.scene = scene;super.init(frame:CGRect(x:0,y:0,width:scene.page.paperWidth,height:scene.page.paperHeight)) }
    convenience init(page:DiagramPage) { self.init(scene:DiagramScene(page:page)) }
    required init?(coder:NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect:NSRect) { DiagramDrawing.drawPage(scene) }
}

enum DiagramExport {
    static func pdf(_ page:DiagramPage) -> Data { pdf(DiagramScene(page:page)) }
    static func pdf(_ scene:DiagramScene) -> Data { let view = ExportPageView(scene:scene);return view.dataWithPDF(inside:view.bounds) }
    static func pdf(_ diagram:Diagram,includeBackgroundPages:Bool = false) throws -> Data {
        let diagram = try diagram.validated(),pages = diagram.orderedPages.filter{includeBackgroundPages || $0.isBackground != true}
        guard !pages.isEmpty else { throw DiagramError.invalid("There are no foreground pages to export.") }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data:data),let context = CGContext(consumer:consumer,mediaBox:nil,nil) else { throw DiagramError.invalid("Could not create the PDF document.") }
        for page in pages {
            var box = CGRect(x:0,y:0,width:page.paperWidth,height:page.paperHeight)
            let media = Data(bytes:&box,count:MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String:media] as CFDictionary);context.saveGState();context.translateBy(x:0,y:page.paperHeight);context.scaleBy(x:1,y:-1)
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:true);DiagramDrawing.drawPage(diagram.scene(for:page.id));NSGraphicsContext.restoreGraphicsState()
            context.restoreGState();context.endPDFPage()
        };context.closePDF();return data as Data
    }
    static func png(_ page:DiagramPage,scale:Double = 2) throws -> Data { try png(DiagramScene(page:page),scale:scale) }
    static func png(_ scene:DiagramScene,scale:Double = 2) throws -> Data {
        let page = scene.page
        guard scale.isFinite,scale>0,scale<=16,page.paperWidth.isFinite,page.paperHeight.isFinite,page.paperWidth>0,page.paperHeight>0,page.paperWidth*scale<=100000,page.paperHeight*scale<=100000 else { throw DiagramError.invalid("Invalid PNG dimensions or scale.") }
        let width = max(1,Int(page.paperWidth*scale)),height = max(1,Int(page.paperHeight*scale))
        guard width*height <= 100_000_000, let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0), let context = NSGraphicsContext(bitmapImageRep:bitmap) else { throw DiagramError.invalid("Page is too large to export as PNG.") }
        NSGraphicsContext.saveGraphicsState();context.cgContext.translateBy(x:0,y:CGFloat(height));context.cgContext.scaleBy(x:scale,y:-scale)
        NSGraphicsContext.current = NSGraphicsContext(cgContext:context.cgContext,flipped:true)
        DiagramDrawing.drawPage(scene);context.flushGraphics();NSGraphicsContext.restoreGraphicsState()
        guard let data = bitmap.representation(using:.png,properties:[:]) else { throw DiagramError.invalid("Could not encode the PNG image.") };return data
    }
}
