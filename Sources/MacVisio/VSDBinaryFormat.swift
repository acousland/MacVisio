import Foundation

/// Visio 2003 (v11) saved-value encoder. Stream/chunk layouts are corroborated
/// against libvisio and real fixture bytes; Windows Visio validation is pending.
/// This is an actual binary VisioDocument inside MS-CFB, never renamed XML/ZIP.
enum VSDBinaryFormat {
    static let nativeStream = "MacVisioModel"
    private struct NativeEnvelope:Codable { var format = 1;var hashes:[String:String];var classID:Data;var diagram:Diagram;var geometryVersion:Int? = 4 }
    static func nativeModel(in file:CompoundFile) -> Diagram? {
        guard let document = file.streams["VisioDocument"],document.starts(with:Data("Visio (TM) Drawing\r\n\0".utf8)),(try? BinaryBytes(document).u8(26)) == 11 else { return nil }
        guard let data = file.streams[nativeStream],let envelope = try? JSONDecoder().decode(NativeEnvelope.self,from:data),envelope.format == 1,envelope.classID == file.rootClassID else { return nil }
        let names = Set(file.streams.keys.filter{$0 != nativeStream})
        guard names == Set(envelope.hashes.keys),names.allSatisfy({VisioFormat.hash(file.streams[$0]!) == envelope.hashes[$0]}) else { return nil }
        guard let diagram = try? envelope.diagram.validated() else { return nil };return envelope.geometryVersion == 4 ? diagram : GeometrySheet.refreshCompositeCaches(diagram)
    }
    private struct Pointer { var type:UInt32;var offset:UInt32;var length:UInt32;var format:UInt16 }
    private static let none:UInt32 = 0xFFFFFFFF
    private static func pointer(_ p:Pointer) -> Data { var d = Data();d.put(p.type);d.put(UInt32(0));d.put(p.offset);d.put(p.length);d.put(p.format);return d }
    private static func scalar(_ value:Double,unit:UInt8 = 0x40) -> Data { var d = Data([unit]);d.putDouble(value);return d }
    private static func utf16(_ text:String) -> Data { var d = Data();for c in text.utf16 { d.put(c) };return d }
    private static func trailer(type:UInt32,list:UInt32,level:UInt16,unknown:UInt8) -> Int {
        if [0x1F,0xC9,0x2D,0xD1].contains(type) { return 0 }
        var size = list != 0 || [0x71,0x70,0x6B,0x6A,0x69,0x66,0x65,0x2C].contains(type) ? 8 : 0
        if list != 0 || level == 2 && unknown == 0x55 || level == 2 && unknown == 0x54 && type == 0xAA || level == 3 && unknown != 0x50 && unknown != 0x54 { size += 4 }
        if [0x64,0x65,0x66,0x69,0x6A,0x6B,0x6F,0x71,0x92,0xA9,0xB4,0xB6,0xB9,0xC7].contains(type) && size != 12 && size != 4 { size += 4 };return size
    }
    private static func chunk(_ type:UInt32,id:UInt32 = 0,list:UInt32 = 0,level:UInt16,unknown:UInt8 = 0x55,payload:Data,includesTrailer:Bool = false) -> Data {
        let tail = trailer(type:type,list:list,level:level,unknown:unknown)
        var d = Data();d.put(type);d.put(id);d.put(list);d.put(UInt32(payload.count-(includesTrailer ? tail : 0)));d.put(level);d.put(unknown);d.append(payload)
        if !includesTrailer { d.append(Data(repeating:0,count:tail)) };return d
    }
    private static func listChunk(_ type:UInt32,id:UInt32,children:[UInt32]) -> Data {
        var d = Data();d.put(UInt32(24));d.put(UInt32(children.count*4));d.put(UInt32(0));d.put(UInt32(0));d.put(UInt32(0));d.put(UInt32(children.count));d.put(UInt32(children.count));d.put(UInt32(0));for c in children { d.put(c) };d.put(UInt32(0))
        return chunk(type,id:id,list:UInt32(max(1,children.count)),level:2,unknown:0x54,payload:d,includesTrailer:true)
    }
    private static func sectionHeader(_ type:UInt32,id:UInt32,listCount:UInt32,subheader:Int,children:[UInt32] = [],parent:UInt32 = 0,connector:Bool = false,background:UInt32 = none) -> Data {
        var d = Data(repeating:0,count:8+subheader);d.set(UInt32(subheader),at:0);d.set(UInt32(children.count*4),at:4)
        if type == 0x15 { d.set(background,at:8) }
        else if type == 0x48 || type == 0x47 || type == 0x4E {
            d.set(parent,at:10);d.set(id,at:14);for at in [18,22,26,30,34,38,42,46,50] { d.set(none,at:at) }
            d.set(UInt16(connector ? 0x10 : 0),at:54);d.set(UInt32(type == 0x47 ? 0 : 1),at:64)
        }
        d.set(listCount,at:subheader);for c in children { d.put(c) };d.put(UInt32(0))
        return chunk(type,id:id,list:listCount,level:type == 0x15 ? 0 : 1,unknown:type == 0x15 ? 0 : 0x54,payload:d,includesTrailer:true)
    }
    private static func rgb(_ text:String) -> [UInt8] {
        let raw = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard raw.count == 6 || raw.count == 8,let bits = UInt32(raw,radix:16) else { return [0,0,0,0] }
        if raw.count == 8 { return [UInt8((bits>>24)&255),UInt8((bits>>16)&255),UInt8((bits>>8)&255),255-UInt8(bits&255)] }
        return [UInt8((bits>>16)&255),UInt8((bits>>8)&255),UInt8(bits&255),0]
    }
    private static func line(_ color:String,width:Double,pattern:Int,start:Bool = false,end:Bool = false) -> Data {
        var d = scalar(width/72);d.put(UInt8(0xFF));d.append(contentsOf:rgb(color));d.put(UInt8(clamping:pattern));d.append(scalar(0));d.put(UInt8(0));d.put(UInt8(start ? 4 : 0));d.put(UInt8(end ? 4 : 0));d.put(UInt8(1))
        return chunk(0x85,id:1,level:3,payload:d)
    }
    private static func fill(_ color:String) -> Data {
        let c = rgb(color);var d = Data([0xFF]);d.append(contentsOf:c);d.put(UInt8(0xFF));d.append(contentsOf:c);d.put(UInt8(c[3] == 255 ? 0 : 1));d.append(Data(repeating:0,count:11));d.put(UInt8(0));d.append(scalar(0));d.append(scalar(0))
        return chunk(0x86,id:2,level:3,payload:d)
    }
    private static func textChunks(_ node:DiagramNode,fonts:[String:UInt16]) -> Data {
        let runs = ShapeRichText.runs(for:node),ids = runs.indices.map{UInt32($0)}
        let fields = runs.filter{$0.fieldIndex != nil}
        if node.text.isEmpty && fields.isEmpty { return Data() }
        var out = Data()
        if !fields.isEmpty {
            let fieldIDs = fields.indices.map{UInt32($0)}
            out.append(listChunk(0x2C,id:5,children:fieldIDs))
            for (i,run) in fields.enumerated() { out.append(chunk(0x2D,id:UInt32(i),level:3,payload:utf16(run.text))) }
            out.append(listChunk(0x66,id:6,children:fieldIDs))
            for i in fields.indices {
                var field = Data(repeating:0,count:7);field.put(UInt8(232));field.put(UInt32(i));field.append(Data(repeating:0,count:6));field.put(UInt32.max)
                out.append(chunk(0xA1,id:UInt32(i),level:3,unknown:0x50,payload:field))
            }
        }
        var text = Data(repeating:0,count:8);text.append(utf16(runs.map{$0.fieldIndex == nil ? $0.text : "\u{FFFC}"}.joined()));out.append(chunk(0x0E,level:2,unknown:0x50,payload:text))
        out.append(listChunk(0x69,id:2,children:ids))
        for (i,run) in runs.enumerated() {
            let style = run.character,font = fonts[style.fontName == "System" ? "Arial" : style.fontName] ?? 0
            var c = Data();c.put(UInt32(run.fieldIndex == nil ? run.text.utf16.count : 1));c.put(font);c.put(UInt8(0xFF));c.append(contentsOf:rgb(style.color));c.put(UInt8((style.bold ? 1 : 0)|(style.italic ? 2 : 0)|(style.underline ? 4 : 0)));c.put(UInt8(0));c.put(UInt8(0));c.put(UInt16(10000));c.put(UInt16(0));c.putDouble(style.size/72);c.put(UInt8(style.strikethrough ? 4 : 0));out.append(chunk(0x94,id:UInt32(i),level:3,payload:c))
        }
        out.append(listChunk(0x6A,id:3,children:ids))
        for (i,run) in runs.enumerated() {
            var p = Data();p.put(UInt32(run.fieldIndex == nil ? run.text.utf16.count : 1));for value in [0.0,0,0,-1.2,0,0] { p.append(scalar(value,unit:0x20)) };p.put(UInt8(run.paragraph.alignment == .left ? 0 : run.paragraph.alignment == .right ? 2 : 1));p.put(UInt8(0));p.append(Data(repeating:0,count:8));p.putDouble(0);p.append(scalar(0));p.put(UInt32(0));p.append(Data(repeating:0,count:34));out.append(chunk(0x95,id:UInt32(i),level:3,payload:p))
        };return out
    }
    private static func shape(_ node:DiagramNode,id:UInt32,parent:UInt32,pageHeight:Double,children:[(UInt32,UInt32)],fonts:[String:UInt16],oneDimensionalEndpoints:(CGPoint,CGPoint)? = nil) throws -> Data {
        var publicNode = node
        let supported = Set(["MoveTo","RelMoveTo","LineTo","RelLineTo","Ellipse","CubBezTo","RelCubBezTo","NURBSTo","PolylineTo","PolyLineTo","SplineStart","SplineKnot"])
        if node.formatting.geometry?.contains(where:{$0.rows.contains{ row in
            if !supported.contains(row.type) { return true }
            if row.type == "SplineStart",!(row.cells["D"].flatMap{Double($0.value)}.flatMap{UInt8(exactly:$0)}.map{(1...25).contains($0)} ?? false) { return true }
            let key = row.type == "NURBSTo" ? "E" : ["PolylineTo","PolyLineTo"].contains(row.type) ? "A" : ""
            return !key.isEmpty && (try? cachedComposite(row.cells[key]?.value ?? "")) == nil
        }}) == true { publicNode.formatting.geometry = nil }
        let xml = try VisioXML.element(VisioFormat.shapeXML(publicNode,id:Int(id),pageHeight:pageHeight))
        let group = node.formatting.isGroup,type:UInt32 = node.formatting.image != nil ? 0x4E : group ? 0x47 : 0x48
        let sectionIDs:[UInt32] = oneDimensionalEndpoints == nil ? [0,1,2,3,4] : [0,1,2,3,4,5]
        var out = sectionHeader(type,id:id,listCount:UInt32(sectionIDs.count),subheader:68,children:sectionIDs,parent:parent,connector:oneDimensionalEndpoints != nil)
        var propIDs:[UInt32] = node.formatting.textBox == nil ? [0,1,2,3] : [0,1,2,3,4]
        if oneDimensionalEndpoints != nil { propIDs.append(5) }
        out.append(listChunk(0x68,id:0,children:propIDs))
        var transform = Data();for key in ["PinX","PinY","Width","Height","LocPinX","LocPinY","Angle"] { transform.append(scalar(VisioXML.number(xml,key),unit:key == "Angle" ? 0x20 : 0x40)) };transform.put(UInt8(node.formatting.flipX ? 1 : 0));transform.put(UInt8(node.formatting.flipY ? 1 : 0));out.append(chunk(0x9B,level:3,payload:transform))
        if let (begin,end) = oneDimensionalEndpoints {
            // XForm1D uses inches in the containing page or group's coordinate space.
            var endpoints = Data()
            for point in [begin,end] { endpoints.append(scalar(point.x/72));endpoints.append(scalar((pageHeight-point.y)/72)) }
            endpoints.append(Data(repeating:0,count:2))
            out.append(chunk(0x9D,id:5,level:3,payload:endpoints))
        }
        out.append(line(node.stroke,width:node.strokeWidth,pattern:rgb(node.stroke)[3] == 255 ? 0 : node.formatting.linePattern));out.append(fill(node.fill))
        let box = node.formatting.textBox
        var block = Data();for v in [box?.left ?? 5,box?.right ?? 5,box?.top ?? 5,box?.bottom ?? 5] { block.append(scalar(v/72)) };block.put(UInt8(clamping:box?.verticalAlignment ?? 1));block.append(Data(repeating:0,count:5));block.append(scalar(0.5));block.append(Data(repeating:0,count:13));out.append(chunk(0x87,id:3,level:3,payload:block))
        if box != nil {
            var txt = Data();for key in ["TxtPinX","TxtPinY","TxtWidth","TxtHeight","TxtLocPinX","TxtLocPinY","TxtAngle"] { txt.append(scalar(VisioXML.number(xml,key),unit:key == "TxtAngle" ? 0x20 : 0x40)) };out.append(chunk(0x9C,id:4,level:3,payload:txt))
        }
        if !children.isEmpty { out.append(order(children,id:4)) }
        out.append(textChunks(node,fonts:fonts))
        if let image = node.formatting.image {
            var imageData = image.data
            let format:UInt32
            switch image.mimeType { case "image/png":format = 4;case "image/jpeg":format = 1;case "image/gif":format = 2;case "image/tiff":format = 3;case "image/bmp":format = 0;default:throw DiagramError.invalid("This image type cannot yet be encoded in binary VSD.") }
            if format == 0 {
                guard imageData.count>=14,imageData.starts(with:Data([0x42,0x4D])) else { throw DiagramError.invalid("Invalid BMP image data.") }
                // Binary Visio stores the DIB; its reader rebuilds the 14-byte BMP file header.
                imageData.removeFirst(14)
            }
            var foreign = Data();for v in [0.0,0,node.width/72,node.height/72] { foreign.append(scalar(v)) };foreign.put(UInt16(1));foreign.put(UInt16(0));foreign.append(Data(repeating:0,count:9));foreign.put(format);out.append(chunk(0x98,id:5,level:2,unknown:0x50,payload:foreign));out.append(chunk(0x0C,level:2,unknown:0x50,payload:imageData))
        }
        var dataID:UInt32 = 1
        for (i,geometry) in xml.elementsLocal("Section").filter({$0.attr("N") == "Geometry"}).enumerated() {
            if group && node.formatting.paths.isEmpty { continue }
            let rows = geometry.elementsLocal("Row");var rowChunks = Data(),dataChunks = Data(),ids:[UInt32] = [0]
            var flags:UInt8 = 0;if VisioXML.number(geometry,"NoFill") == 1 { flags |= 1 };if VisioXML.number(geometry,"NoLine") == 1 { flags |= 2 };if VisioXML.number(geometry,"NoShow") == 1 { flags |= 4 }
            rowChunks.append(chunk(0x89,level:3,payload:Data([flags])))
            for (j,row) in rows.enumerated() {
                let rowID = UInt32(j+1),type = row.attr("T") ?? "",relative = type.hasPrefix("Rel")
                func value(_ key:String) -> Double { VisioXML.number(row,key)*(relative ? (["Y","B","D"].contains(key) ? node.sheetHeight/72 : node.sheetWidth/72) : 1) }
                var payload = scalar(value("X"));payload.append(scalar(value("Y")))
                let chunkType:UInt32
                switch type {
                case "MoveTo","RelMoveTo":chunkType = 0x8A
                case "LineTo","RelLineTo":chunkType = 0x8B
                case "Ellipse":chunkType = 0x8F;for key in ["A","B","C","D"] { payload.append(scalar(value(key))) }
                case "SplineStart":chunkType = 0xA5;for key in ["A","B","C"] { payload.putDouble(value(key)) };payload.put(UInt8(value("D")))
                case "SplineKnot":chunkType = 0xA6;payload.putDouble(value("A"))
                case "NURBSTo","PolylineTo","PolyLineTo":
                    let nurbs = type == "NURBSTo",key = nurbs ? "E" : "A",element = row.elementsLocal("Cell").first{$0.attr("N") == key},cell = try cachedComposite(element?.attr("V") ?? element?.attr("F") ?? "")
                    guard cell.name == (nurbs ? "NURBS" : "POLYLINE") else { throw DiagramError.invalid("Wrong binary composite geometry type.") }
                    chunkType = nurbs ? 0xC3 : 0xC1
                    if nurbs { for key in ["A","B","C","D"] { payload.putDouble(VisioXML.number(row,key,["B","D"].contains(key) ? 1 : 0)) } }
                    payload.put(UInt8(0));payload.put(UInt8(nurbs ? 0x8A : 0x8B));payload.append(Data(repeating:0,count:3));payload.put(dataID)
                    var control = Data([nurbs ? 0x82 : 0x80]);control.append(Data(repeating:0,count:15))
                    if nurbs { control.putDouble(cell.values[0]);control.put(UInt16(cell.values[1])) }
                    let flag = nurbs ? 2 : 0,offset = nurbs ? 4 : 2,step = nurbs ? 4 : 2
                    control.put(UInt8(cell.values[flag] == 0 ? 0 : 1));control.put(UInt8(cell.values[flag+1] == 0 ? 0 : 1));control.put(UInt32((cell.values.count-offset)/step))
                    for v in cell.values.dropFirst(offset) { control.putDouble(v) }
                    dataChunks.append(chunk(0xD1,id:dataID,level:2,unknown:0x50,payload:control));dataID += 1
                case "RelCubBezTo","CubBezTo":
                    chunkType = 0xC3;payload.putDouble(0);payload.putDouble(1);payload.putDouble(0);payload.putDouble(1);payload.put(UInt8(0));payload.put(UInt8(0x8A));payload.append(Data(repeating:0,count:3));payload.put(dataID)
                    var control = Data([0x82]);control.append(Data(repeating:0,count:15));control.putDouble(1);control.put(UInt16(3));control.put(UInt8(1));control.put(UInt8(1));control.put(UInt32(2))
                    for pair in [("A","B"),("C","D")] { control.putDouble(value(pair.0));control.putDouble(value(pair.1));control.putDouble(0);control.putDouble(1) };dataChunks.append(chunk(0xD1,id:dataID,level:2,unknown:0x50,payload:control));dataID += 1
                default:throw DiagramError.invalid("A geometry row cannot yet be encoded in binary VSD: \(type)")
                }
                ids.append(rowID);rowChunks.append(chunk(chunkType,id:rowID,level:3,payload:payload))
            }
            out.append(dataChunks);out.append(listChunk(0x6C,id:UInt32(5+i),children:ids));out.append(rowChunks)
        };return out
    }
    private static func cachedComposite(_ source:String) throws -> CompositeGeometry {
        try CompositeGeometry.evaluate(source,numeric:{_ in throw DiagramError.invalid("Binary geometry requires saved coordinate data.")},cached:true)
    }
    private static func order(_ shapes:[(UInt32,UInt32)],id:UInt32) -> Data {
        var d = listChunk(0x65,id:id,children:shapes.indices.map{UInt32($0)})
        for (i,item) in shapes.enumerated() { var p = Data();p.put(item.0);p.put(item.1);p.put(UInt16(0));d.append(chunk(0x83,id:UInt32(i),level:3,payload:p)) };return d
    }
    private static func page(_ page:DiagramPage,fonts:[String:UInt16],background:UInt32) throws -> Data {
        var out = sectionHeader(0x15,id:none,listCount:UInt32(page.nodes.count+page.edges.count+1),subheader:96,background:background)
        out.append(sectionHeader(0x46,id:0,listCount:2,subheader:68,children:[0,1]))
        out.append(listChunk(0x68,id:0,children:[0]))
        var props = Data();for value in [page.width/72,page.height/72,0,0,page.drawingScale?.page ?? 1,page.drawingScale?.drawing ?? 1] { props.append(scalar(value)) };out.append(chunk(0x92,level:3,payload:props))
        let ids = Dictionary(uniqueKeysWithValues:page.nodes.enumerated().map{($0.element.id,UInt32($0.offset+1))})
        let edgeIDs = Dictionary(uniqueKeysWithValues:page.edges.enumerated().map{($0.element.id,UInt32(page.nodes.count+$0.offset+1))})
        let top = page.nodes.filter{$0.parentID == nil}.map{(ids[$0.id]!,UInt32($0.formatting.isGroup ? 0x47 : $0.formatting.image != nil ? 0x4E : 0x48))} + page.edges.filter{$0.parentID == nil}.map{(edgeIDs[$0.id]!,UInt32(0x48))}
        out.append(order(top,id:1))
        for node in page.nodes {
            let local = VisioPreservation.localNode(node,in:page)
            let height = node.parentID.flatMap{id in page.nodes.first{$0.id == id}?.height} ?? page.height
            let children = page.nodes.filter{$0.parentID == node.id}.map{(ids[$0.id]!,UInt32($0.formatting.isGroup ? 0x47 : $0.formatting.image != nil ? 0x4E : 0x48))} + page.edges.filter{$0.parentID == node.id}.map{(edgeIDs[$0.id]!,UInt32(0x48))}
            out.append(try shape(local,id:ids[node.id]!,parent:node.parentID.flatMap{ids[$0]} ?? 0,pageHeight:height,children:children,fonts:fonts))
            guard out.count<=100*1024*1024 else { throw DiagramError.invalid("The binary page exceeds the supported size.") }
        }
        for (i,edge) in page.edges.enumerated() {
            let coordinates = DiagramCoordinates.connector(edge,in:page)
            let points = DiagramGeometry.route(coordinates.edge,in:coordinates.page);guard !points.isEmpty else { continue }
            let minX = points.map(\.x).min()!,maxX = points.map(\.x).max()!,minY = points.map(\.y).min()!,maxY = points.map(\.y).max()!
            var n = DiagramNode(x:minX,y:minY,text:edge.label);n.width = max(0.072,maxX-minX);n.height = max(0.072,maxY-minY);n.fill = "#FFFFFF00";n.stroke = edge.color;n.strokeWidth = edge.width;n.fontSize = 12;n.textColor = edge.color
            n.formatting.linePattern = edge.dash ?? 1;n.formatting.paths = [VectorPath(commands:points.enumerated().map{VectorCommand($0.offset == 0 ? "M" : "L",($0.element.x-minX)/n.width,($0.element.y-minY)/n.height)},fill:false)]
            var data = try shape(n,id:UInt32(page.nodes.count+i+1),parent:edge.parentID.flatMap{ids[$0]} ?? 0,pageHeight:coordinates.page.height,children:[],fonts:fonts,oneDimensionalEndpoints:(points[0],points[points.count-1]))
            // Line properties are independent of the cached path; add the markers in a
            // fresh property section after the existing geometry, before the next shape.
            data.append(listChunk(0x68,id:6,children:[0]));data.append(line(edge.color,width:edge.width,pattern:edge.dash ?? 1,start:edge.startArrow == true,end:edge.arrow));out.append(data)
            guard out.count<=100*1024*1024 else { throw DiagramError.invalid("The binary page exceeds the supported size.") }
        }
        return out
    }
    static func encoded(_ diagram:Diagram,includeMetadata:Bool = true) throws -> Data {
        let diagram = try diagram.validated()
        if includeMetadata,let source = diagram.legacySource,ShapeRichText.withoutSourceIndices(source.pages) == ShapeRichText.withoutSourceIndices(diagram.pages),source.title == diagram.title { return source.data }
        let sourceFile = try diagram.legacySource.map{try CompoundFile.read($0.data)}
        var stream = Data(repeating:0,count:128);stream.replaceSubrange(0..<21,with:Data("Visio (TM) Drawing\r\n\0".utf8));stream[26] = 11;stream.set(UInt32(0x00018400),at:32)
        func append(_ data:Data,type:UInt32,format:UInt16) throws -> Pointer {
            guard stream.count<=100*1024*1024-data.count else { throw DiagramError.invalid("The binary drawing exceeds the supported size.") }
            let result = Pointer(type:type,offset:UInt32(stream.count),length:UInt32(data.count),format:format);stream.append(data);return result
        }
        func container(_ pointers:[Pointer]) -> Data {
            var d = Data();d.put(UInt32(20));d.append(Data(repeating:0,count:12));d.put(UInt32(1));d.put(UInt32(pointers.count));d.put(UInt32(0));for p in pointers { d.append(pointer(p)) };d.put(UInt32(0));d.set(UInt32(d.count-12),at:4);return d
        }
        var fontNames = ["Arial"]
        for n in diagram.pages.flatMap(\.nodes) { for style in ShapeRichText.runs(for:n).map(\.character)+[ShapeCharacterStyle(node:n)] { let name = style.fontName == "System" ? "Arial" : style.fontName;if !fontNames.contains(name) { fontNames.append(name) } } }
        guard fontNames.count<=UInt16.max else { throw DiagramError.invalid("Too many fonts for binary VSD.") }
        let fonts = Dictionary(uniqueKeysWithValues:fontNames.enumerated().map{($0.element,UInt16($0.offset))})
        var fontPointers:[Pointer] = []
        for name in fontNames {
            guard name.utf16.count<=31 else { throw DiagramError.invalid("A font name is too long for the binary VSD font table.") }
            var d = Data();d.put(UInt32(0x145));d.append(utf16(name));d.put(UInt16(0));d.append(Data(repeating:0,count:max(0,106-d.count)));fontPointers.append(try append(d,type:0xD7,format:0x40))
        }
        let fontIndex = try append(container(fontPointers),type:0xD8,format:0x54)
        var pages:[Pointer] = []
        let pageIDs = Dictionary(uniqueKeysWithValues:diagram.pages.enumerated().map{($0.element.id,UInt32($0.offset))})
        for page in diagram.pages { pages.append(try append(try self.page(page,fonts:fonts,background:page.backgroundPageID.flatMap{pageIDs[$0]} ?? none),type:0x15,format:page.isBackground == true ? 0xD4 : 0xD5)) }
        var names:[Pointer] = [],nameIndex = Data();nameIndex.put(UInt32(diagram.pages.count))
        for (i,page) in diagram.pages.enumerated() {
            var text = Data();text.put(UInt32(1));text.append(utf16(page.name));text.put(UInt16(0));names.append(try append(text,type:0x33,format:0x40))
            nameIndex.put(UInt32(i));nameIndex.put(UInt32(i));nameIndex.put(UInt32(i));nameIndex.put(UInt8(0))
        }
        pages.append(try append(container(names),type:0x32,format:0x54));pages.append(try append(nameIndex,type:0xC9,format:0x40))
        let pageIndex = try append(container(pages),type:0x27,format:0x54)
        let root = try append(container([fontIndex,pageIndex]),type:0x14,format:0x54);stream.replaceSubrange(36..<54,with:pointer(root));stream.set(UInt32(stream.count),at:28)
        let classID = sourceFile?.rootClassID ?? Data([0x14,0x1A,0x02,0,0,0,0,0,0xC0,0,0,0,0,0,0,0x46])
        var info = Data([0xFE,0xFF,0,0,4,0,2,0]);info.append(Data(repeating:0,count:20))
        var streams = ["VisioDocument":stream,"VisioInformation":info]
        if let sourceFile {
            // A regenerated public document cannot retain pointers into its old
            // streams. Preserve only opaque, root-level streams whose contents do
            // not need to be rewritten; nested storage paths are not writable yet.
            let generated = Set(["VisioDocument","VisioInformation",nativeStream].map{$0.uppercased()})
            for (name,data) in sourceFile.streams where !name.contains("/") && !generated.contains(name.uppercased()) { streams[name] = data }
        }
        if includeMetadata {
            let hashes = streams.mapValues{VisioFormat.hash($0)}
            streams[nativeStream] = try JSONEncoder().encode(NativeEnvelope(hashes:hashes,classID:classID,diagram:diagram))
        }
        let result = try CompoundFile(streams:streams,rootClassID:classID).encoded()
        guard result.count<=100*1024*1024 else { throw DiagramError.invalid("The binary drawing and its metadata exceed the 100 MB limit.") };return result
    }
    static func write(_ diagram:Diagram,to url:URL) throws { try encoded(diagram).write(to:url,options:.atomic) }
}

struct LegacyVisioSource:Codable,Equatable {
    var data:Data
    var title:String
    var pages:[DiagramPage]
}
