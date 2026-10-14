import Foundation

/// Saved Visio geometry data. Coordinates are kept in their declared local or
/// width/height-relative space; knots and weights are dimensionless.
struct CompositeGeometry:Equatable {
    var name:String
    var values:[Double]
    static func number(_ value:Double) -> String { let text = String(value);return text.hasSuffix(".0") ? String(text.dropLast(2)) : text }
    var formula:String { name+"("+values.map(Self.number).joined(separator:",")+")" }
    static func evaluate(_ source:String,numeric:(String)throws->Double,data:(String)throws->CompositeGeometry = {_ in throw DiagramError.invalid("Unknown composite geometry reference.")},cached:Bool = false) throws -> CompositeGeometry {
        func value(_ expression:ShapeSheet.Expression) throws -> Double {
            if case .string(let text) = expression { return try ShapeSheet.evaluate(text,resolve:numeric) }
            return try ShapeSheet.evaluate(expression,resolve:numeric)
        }
        func resolve(_ expression:ShapeSheet.Expression,_ depth:Int = 0) throws -> CompositeGeometry {
            guard depth < 64 else { throw DiagramError.invalid("Composite geometry expression limit exceeded.") }
            switch expression {
            case .reference(let key):return try data(key)
            case .call(let name,let args):
                let name = name.uppercased()
                if ["GUARD","SETATREFEXPR"].contains(name),args.count == 1 { return try resolve(args[0],depth+1) }
                if name == "IF",args.count == 3 { return try resolve(value(args[0]) != 0 ? args[1] : args[2],depth+1) }
                if name == "IFERROR",args.count == 2 { do { return try resolve(args[0],depth+1) } catch { return try resolve(args[1],depth+1) } }
                guard ["NURBS","POLYLINE"].contains(name),args.count <= 4096 else { throw DiagramError.invalid("Unsupported composite geometry expression.") }
                let result = CompositeGeometry(name:name,values:try args.map(value));try result.validate();return result
            default:throw DiagramError.invalid("A NURBS or POLYLINE expression was required.")
            }
        }
        return try resolve(ShapeSheet.parse(source,characterLimit:cached ? 128*1024 : 16384))
    }
    func validate() throws {
        guard values.allSatisfy(\.isFinite) else { throw DiagramError.invalid("Non-finite composite geometry data.") }
        let offset = name == "NURBS" ? 4 : 2,stride = name == "NURBS" ? 4 : 2
        guard ["NURBS","POLYLINE"].contains(name),values.count >= offset+stride,(values.count-offset)%stride == 0 else { throw DiagramError.invalid("Incomplete composite geometry coordinate data.") }
        let flag = name == "NURBS" ? 2 : 0
        guard values[flag] >= 0,UInt32(exactly:values[flag]) != nil,values[flag+1] >= 0,UInt32(exactly:values[flag+1]) != nil else { throw DiagramError.invalid("Invalid composite geometry coordinate type.") }
        if name == "NURBS" { guard let degree = Int(exactly:values[1]),(1...25).contains(degree) else { throw DiagramError.invalid("Invalid NURBS degree.") } }
    }
    func coordinates(width:Double,height:Double) -> [CGPoint] {
        let offset = name == "NURBS" ? 4 : 2,step = name == "NURBS" ? 4 : 2,flag = name == "NURBS" ? 2 : 0
        return stride(from:offset,to:values.count,by:step).map { CGPoint(x:values[$0]*(values[flag] == 0 ? width : 1),y:values[$0+1]*(values[flag+1] == 0 ? height : 1)) }
    }
    func scaled(by ratio:Double) -> CompositeGeometry {
        var result = self;let offset = name == "NURBS" ? 4 : 2,step = name == "NURBS" ? 4 : 2,flag = name == "NURBS" ? 2 : 0
        for i in stride(from:offset,to:values.count,by:step) { if values[flag] != 0 { result.values[i] *= ratio };if values[flag+1] != 0 { result.values[i+1] *= ratio } };return result
    }
}

enum VisioNURBS {
    struct Cubic { var start:CGPoint;var a:CGPoint;var b:CGPoint;var end:CGPoint }
    private struct Homogeneous {
        var x:Double;var y:Double;var w:Double
        static func +(a:Self,b:Self) -> Self { Self(x:a.x+b.x,y:a.y+b.y,w:a.w+b.w) }
        static func -(a:Self,b:Self) -> Self { Self(x:a.x-b.x,y:a.y-b.y,w:a.w-b.w) }
        static func *(a:Self,b:Double) -> Self { Self(x:a.x*b,y:a.y*b,w:a.w*b) }
    }
    static func cubics(_ data:CompositeGeometry,from start:CGPoint,to end:CGPoint,firstKnot:Double,penultimateKnot:Double,firstWeight:Double,lastWeight:Double,width:Double,height:Double,tolerance:Double = 0.00001) throws -> [Cubic] {
        try data.validate();guard data.name == "NURBS" else { throw DiagramError.invalid("Expected NURBS data.") }
        let degree = Int(data.values[1]),points = [start]+data.coordinates(width:width,height:height)+[end]
        let weights = [firstWeight]+stride(from:7,to:data.values.count,by:4).map{data.values[$0]}+[lastWeight]
        var knots = [firstKnot]+stride(from:6,to:data.values.count,by:4).map{data.values[$0]}+[penultimateKnot,data.values[0]]
        guard points.count > degree,weights.allSatisfy({$0.isFinite && $0 > 0}),knots.allSatisfy(\.isFinite),tolerance.isFinite,tolerance > 0 else { throw DiagramError.invalid("Invalid NURBS knots, weights or control count.") }
        for i in 1..<knots.count where knots[i] < knots[i-1] {
            // Visio's compound strings and separate knot cells can retain
            // different decimal precision. Correct only negligible descents.
            let allowed = max(max(abs(knots[i]),abs(knots[i-1]))*1e-11,max(knots[i].ulp,knots[i-1].ulp)*16)
            guard knots[i-1]-knots[i] <= allowed else { throw DiagramError.invalid("NURBS knots decrease beyond serialization precision.") };knots[i] = knots[i-1]
        }
        knots += Array(repeating:knots.last!,count:degree)
        guard knots[degree] < knots[points.count] else { throw DiagramError.invalid("NURBS parameter interval is empty.") }
        let controls = zip(points,weights).map{Homogeneous(x:$0.x*$1,y:$0.y*$1,w:$1)}
        let derivativeKnots = Array(knots.dropFirst().dropLast())
        struct Span { var index:Int;var base:Double;var delta:Double;var controls:[Homogeneous];var derivative:[Homogeneous] }
        func deBoor(_ input:[Homogeneous],_ degree:Int,_ knots:[Double],_ u:Double,_ span:Int,_ base:Double,_ delta:Double) -> Homogeneous {
            var values = input;if degree == 0 { return values[0] }
            for r in 1...degree { for j in stride(from:degree,through:r,by:-1) { let i = span-degree+j,d = knots[i+degree-r+1]-knots[i],alpha = d == 0 ? 0 : ((base-knots[i])+delta*u)/d;values[j] = values[j-1]*(1-alpha)+values[j]*alpha } };return values[degree]
        }
        func sample(_ u:Double,_ span:Span) throws -> (CGPoint,CGPoint) {
            let h = deBoor(span.controls,degree,knots,u,span.index,span.base,span.delta),d = deBoor(span.derivative,degree-1,derivativeKnots,u,span.index-1,span.base,span.delta)
            guard h.w.isFinite,h.w > 0 else { throw DiagramError.invalid("NURBS has a singular rational denominator.") }
            let p = CGPoint(x:h.x/h.w,y:h.y/h.w),v = CGPoint(x:(d.x-p.x*d.w)/h.w,y:(d.y-p.y*d.w)/h.w)
            guard [p.x,p.y,v.x,v.y].allSatisfy(\.isFinite) else { throw DiagramError.invalid("Invalid NURBS point.") };return (p,v)
        }
        func bezier(_ curve:Cubic,_ t:Double) -> CGPoint { let u = 1-t;return CGPoint(x:u*u*u*curve.start.x+3*u*u*t*curve.a.x+3*u*t*t*curve.b.x+t*t*t*curve.end.x,y:u*u*u*curve.start.y+3*u*u*t*curve.a.y+3*u*t*t*curve.b.y+t*t*t*curve.end.y) }
        var output:[Cubic] = [],operations = 0
        func interval(_ low:Double,_ high:Double,_ span:Span,_ depth:Int) throws {
            operations += 1;guard operations <= 20000,output.count < 10000 else { throw DiagramError.invalid("NURBS tessellation limit exceeded.") }
            let (p,v) = try sample(low,span),(q,w) = try sample(high,span),h = (high-low)/3
            let curve = Cubic(start:p,a:CGPoint(x:p.x+h*v.x,y:p.y+h*v.y),b:CGPoint(x:q.x-h*w.x,y:q.y-h*w.y),end:q)
            var error = 0.0
            let checks = max(3,2*degree+1)
            for i in 1...checks { let t = Double(i)/Double(checks+1),actual = try sample(low+(high-low)*t,span).0,estimate = bezier(curve,t);error = max(error,hypot(actual.x-estimate.x,actual.y-estimate.y)) }
            if error <= tolerance { output.append(curve) }
            else { guard depth < 16 else { throw DiagramError.invalid("NURBS approximation tolerance could not be reached.") };let mid = low+(high-low)/2;try interval(low,mid,span,depth+1);try interval(mid,high,span,depth+1) }
        }
        for index in degree..<points.count where knots[index] < knots[index+1] {
            let delta = knots[index+1]-knots[index]
            guard delta.isFinite else { throw DiagramError.invalid("NURBS parameter span is outside the numeric range.") }
            let derivative = ((index-degree)..<index).map { i -> Homogeneous in let d = knots[i+degree+1]-knots[i+1];return d == 0 ? Homogeneous(x:0,y:0,w:0) : (controls[i+1]-controls[i])*(Double(degree)*(delta/d)) }
            let span = Span(index:index,base:knots[index],delta:delta,controls:Array(controls[(index-degree)...index]),derivative:derivative)
            try interval(0,1,span,0)
        }
        return output
    }
}
