import Foundation
import CoreGraphics

enum ControlEditing {
    static func expression(_ e:ShapeSheet.Expression) -> String {
        switch e { case .number(let n),.measure(let n,_):return CompositeGeometry.number(n)
        case .string(let s):return "\""+s.replacingOccurrences(of:"\"",with:"\"\"")+"\""
        case .reference(let s):return s
        case .omitted:return ""
        case .unary(let op,let e):return "("+op+expression(e)+")"
        case .binary(let op,let a,let b):return "("+expression(a)+op+expression(b)+")"
        case .call(let name,let args):return name+"("+args.map(expression).joined(separator:",")+")" }
    }
    static func moved(_ input:Diagram,node id:UUID,control name:String,to world:CGPoint) throws -> Diagram {
        var next = input
        guard let index = next.page.nodes.firstIndex(where:{$0.id == id}),!next.page.isLocked(next.page.nodes[index]),let control = next.page.nodes[index].formatting.controls.first(where:{$0.name == name}),control.visible else { return input }
        let node = next.page.nodes[index],p = DiagramCoordinates.local(world,in:node),values = ["X":(p.x+node.sheetOrigin.x)/72,"Y":(node.height-p.y+node.sheetOrigin.y)/72]
        guard values.values.allSatisfy({$0.isFinite && abs($0)<100000}) else { throw DiagramError.invalid("The control position is outside the supported range.") }
        let colorPalette = ShapeSheetColorPalette(documentArchive:next.visioArchive)
        func target(_ reference:String,from i:Int) throws -> (Int,String) {
            if let bang = reference.firstIndex(of:"!") {
                let sheet = String(reference[..<bang]),key = String(reference[reference.index(after:bang)...]),binding = next.visioArchive?.pages.first{$0.pageID == next.page.id}
                guard sheet.uppercased().hasPrefix("SHEET."),let other = next.page.nodes.enumerated().first(where:{(binding?.nodeIDs[$0.element.id] ?? $0.element.formatting.sourceShapeID ?? String($0.offset+1)) == String(sheet.dropFirst(6))})?.offset else { throw DiagramError.invalid("Unknown control target: \(reference)") };return (other,key)
            };return (i,reference)
        }
        func read(_ i:Int,_ key:String,_ depth:Int = 0) throws -> Double {
            try ShapeSheetContext(page:next.page,binding:next.visioArchive?.pages.first{$0.pageID == next.page.id},colorPalette:colorPalette).number(next.page.nodes[i].id,key)
        }
        func evaluate(_ expression:ShapeSheet.Expression,_ i:Int) throws -> Double {
            try ShapeSheetContext(page:next.page,binding:next.visioArchive?.pages.first{$0.pageID == next.page.id},colorPalette:colorPalette).evaluate(expression,on:next.page.nodes[i].id).numeric()
        }
        func contains(_ e:ShapeSheet.Expression,_ name:String) -> Bool {
            switch e { case .call(let f,let args):return f.uppercased() == name || args.contains{contains($0,name)};case .unary(_,let e):return contains(e,name);case .binary(_,let a,let b):return contains(a,name) || contains(b,name);default:return false }
        }
        func replacement(_ e:ShapeSheet.Expression,_ value:Double,_ i:Int,_ preserveStore:Bool = false) throws -> ShapeSheet.Expression {
            switch e {
            case .call(let name,let args):
                if name.uppercased() == "SETATREFEXPR" { return preserveStore ? .call(name,[.number(value)]) : .number(value) }
                let converted = try args.map{try replacement($0,value,i,preserveStore)}
                if name.uppercased() == "SETATREFEVAL",converted.count == 1 { return .number(try evaluate(converted[0],i)) }
                return .call(name,converted)
            case .unary(let op,let e):return .unary(op,try replacement(e,value,i,preserveStore))
            case .binary(let op,let a,let b):return .binary(op,try replacement(a,value,i,preserveStore),try replacement(b,value,i,preserveStore))
            default:return e }
        }
        var writing = Set<String>()
        func store(_ i:Int,_ key:String,_ cell:ShapeSheetCell) throws {
            if ControlGeometry.cell(key,on:next.page.nodes[i]) != nil { try ControlGeometry.set(key,cell,on:&next.page.nodes[i]) }
            else if GeometrySheet.cell(key,on:next.page.nodes[i]) != nil { try GeometrySheet.set(key,cell,on:&next.page.nodes[i]) }
            else {
                let name = next.page.nodes[i].formatting.sheet.keys.first{$0.caseInsensitiveCompare(key) == .orderedSame} ?? key
                guard next.page.nodes[i].formatting.sheet[name] != nil || ShapeSheetEngine.geometryKeys.contains(name) else { throw DiagramError.invalid("Unknown control update target: \(key)") };next.page.nodes[i].formatting.sheet[name] = cell
            }
        }
        func write(_ i:Int,_ key:String,_ value:Double,_ formula:String? = nil,_ depth:Int = 0) throws {
            guard !next.page.isLocked(next.page.nodes[i]),depth <= 10,writing.insert("\(i)!"+key.lowercased()).inserted else { throw DiagramError.invalid("Locked or circular control update target.") };defer { writing.remove("\(i)!"+key.lowercased()) }
            let n = next.page.nodes[i],old = ControlGeometry.cell(key,on:n) ?? GeometrySheet.cell(key,on:n) ?? n.formatting.sheet.first{$0.key.caseInsensitiveCompare(key) == .orderedSame}?.value ?? ShapeSheetCell(value:"")
            let ast = old.formula.isEmpty || ["Inh","No Formula"].contains(old.formula) ? nil : try ShapeSheet.parse(old.formula)
            func redirect(_ e:ShapeSheet.Expression) throws {
                switch e {
                case .call(let name,let args):
                    if name.uppercased() == "SETATREF",(1...3).contains(args.count) {
                        let reference:String;switch args[0] { case .reference(let r),.string(let r):reference = r;default:throw DiagramError.invalid("SETATREF requires a cell reference.") }
                        let (j,k) = try target(reference,from:i)
                        if args.count >= 2 { let assigned = try replacement(args[1],value,i),f = expression(assigned),number = try evaluate(assigned,i);try write(j,k,number,f,depth+1) }
                        else { try write(j,k,value,nil,depth+1) };return
                    }
                    if name.uppercased() == "IF",args.count == 3 { let condition = try evaluate(args[0],i);try redirect(condition != 0 ? args[1] : args[2]);return }
                    if name.uppercased() == "IFERROR",args.count == 2 {
                        let active:ShapeSheet.Expression
                        do { _ = try evaluate(args[0],i);active = args[0] } catch { active = args[1] }
                        try redirect(active);return
                    }
                    for e in args { try redirect(e) }
                case .unary(_,let e):try redirect(e)
                case .binary(_,let a,let b):try redirect(a);try redirect(b)
                default:break }
            }
            if let ast,contains(ast,"SETATREF") {
                try redirect(ast)
                // Only stored input markers outside SETATREF's assignment expression
                // belong to this cell; assignment markers remain reusable templates.
                func updateMarkers(_ e:ShapeSheet.Expression) throws -> ShapeSheet.Expression {
                    switch e {
                    case .call(let f,_) where f.uppercased() == "SETATREF":return e
                    case .call(let f,_) where f.uppercased() == "SETATREFEXPR":return .call(f,[.number(value)])
                    case .call(let f,let args) where f.uppercased() == "BOUND" && args.count >= 5:return .call(f,[.number(value)]+Array(args.dropFirst()))
                    case .call(let f,let args):return .call(f,try args.map(updateMarkers))
                    case .unary(let op,let e):return .unary(op,try updateMarkers(e))
                    case .binary(let op,let a,let b):return .binary(op,try updateMarkers(a),try updateMarkers(b))
                    default:return e }
                }
                let updated = expression(try updateMarkers(ast))
                if (contains(ast,"SETATREFEXPR") || contains(ast,"BOUND")),updated != expression(ast) { var cell = old;cell.formula = updated;try store(i,key,cell) }
                return
            }
            if let ast,contains(ast,"GUARD") { throw DiagramError.invalid("This control coordinate is guarded.") }
            let result:String
            if let ast,contains(ast,"BOUND") {
                let input:ShapeSheet.Expression
                if let (c,axis) = ControlGeometry.address(key,on:n),["X","Y"].contains(axis) {
                    let size = (axis == "X" ? n.sheetWidth : n.sheetHeight)/72,dimension = axis == "X" ? "Width" : "Height",behavior = n.formatting.controls[c].behavior(axis)%5
                    let formula = behavior == 0 && size != 0 ? dimension+"*"+CompositeGeometry.number(value/size) : behavior == 3 ? dimension+"/2+"+CompositeGeometry.number(value-size/2) : behavior == 4 ? dimension+"+"+CompositeGeometry.number(value-size) : CompositeGeometry.number(value)
                    input = try ShapeSheet.parse(formula)
                } else { input = .number(value) }
                func boundInput(_ e:ShapeSheet.Expression) -> ShapeSheet.Expression {
                    switch e {
                    case .call(let f,let args) where f.uppercased() == "BOUND" && args.count >= 5:return .call(f,[input]+Array(args.dropFirst()))
                    case .call(let f,let args):return .call(f,args.map(boundInput))
                    case .unary(let op,let e):return .unary(op,boundInput(e))
                    case .binary(let op,let a,let b):return .binary(op,boundInput(a),boundInput(b))
                    default:return e }
                };result = expression(boundInput(ast))
            }
            else if let ast,contains(ast,"SETATREFEXPR") { result = expression(try replacement(ast,value,i,true)) }
            else if let formula { result = formula }
            else if let (c,axis) = ControlGeometry.address(key,on:n),["X","Y"].contains(axis) {
                let size = (axis == "X" ? n.sheetWidth : n.sheetHeight)/72,dimension = axis == "X" ? "Width" : "Height",behavior = n.formatting.controls[c].behavior(axis)%5
                result = behavior == 0 && size != 0 ? dimension+"*"+CompositeGeometry.number(value/size) : behavior == 3 ? dimension+"/2+"+CompositeGeometry.number(value-size/2) : behavior == 4 ? dimension+"+"+CompositeGeometry.number(value-size) : ""
            } else { result = "" }
            try store(i,key,ShapeSheetCell(value:CompositeGeometry.number(value),formula:result,unit:old.unit))
        }
        for axis in ["X","Y"] where control.behavior(axis)%5 != 1 { try write(index,"Controls."+name+"."+axis,values[axis]!) }
        let before = Set(ShapeSheetEngine.recalculate(input).issues),calculated = ShapeSheetEngine.recalculate(next,previous:input),added = Set(calculated.issues).subtracting(before)
        guard added.isEmpty else { throw DiagramError.invalid(added.sorted().prefix(4).joined(separator:"\n")) };return try calculated.diagram.validated()
    }
}

extension EditorWindowController {
    func moveControl(_ name:String,on id:UUID,to point:CGPoint) throws {
        canvas.finishEditing(commit:true);diagramDocument.replace(with:try ControlEditing.moved(diagramDocument.diagram,node:id,control:name,to:point),action:"Adjust Control Handle")
    }
}
