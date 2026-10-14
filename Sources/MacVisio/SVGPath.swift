import Foundation
import CoreGraphics

enum SVGPath {
    static func parse(_ text:String) throws -> [VectorCommand] {
        let regex = try NSRegularExpression(pattern:"[MmLlHhVvCcSsQqTtAaZz]|[-+]?(?:[0-9]*\\.[0-9]+|[0-9]+\\.?[0-9]*)(?:[eE][-+]?[0-9]+)?")
        let matches = regex.matches(in:text,range:NSRange(text.startIndex...,in:text))
        guard matches.count <= 500000 else { throw DiagramError.invalid("The SVG path has too many coordinates.") }
        var tokens:[String] = [],last = text.startIndex
        for match in matches {
            let range = Range(match.range,in:text)!
            guard text[last..<range.lowerBound].allSatisfy({$0.isWhitespace || $0 == ","}) else { throw DiagramError.invalid("Unsupported SVG path command.") }
            tokens.append(String(text[range])); last = range.upperBound
        }
        guard text[last...].allSatisfy({$0.isWhitespace || $0 == ","}) else { throw DiagramError.invalid("Invalid SVG path data.") }
        var i = 0,command = "",previous = "",current = CGPoint.zero,first = CGPoint.zero,control = CGPoint.zero
        var result:[VectorCommand] = []
        func read(_ count:Int) throws -> [Double] {
            guard i+count <= tokens.count else { throw DiagramError.invalid("Truncated SVG path.") }
            let values = tokens[i..<i+count].compactMap(Double.init)
            guard values.count == count,values.allSatisfy({$0.isFinite && abs($0)<1e8}) else { throw DiagramError.invalid("Invalid SVG coordinates.") }
            i += count; return values
        }
        while i < tokens.count {
            if tokens[i].count == 1,tokens[i].first!.isLetter { command = tokens[i]; i += 1 }
            guard !command.isEmpty else { throw DiagramError.invalid("The SVG path has no command.") }
            let type = command.uppercased(),relative = command != type
            if result.isEmpty && type != "M" { throw DiagramError.invalid("An SVG path must begin with a move command.") }
            func point(_ x:Double,_ y:Double) -> CGPoint { CGPoint(x:x+(relative ? current.x : 0),y:y+(relative ? current.y : 0)) }
            switch type {
            case "M","L","T":
                let v = try read(2),p = point(v[0],v[1])
                if type == "M" { result.append(VectorCommand("M",p.x,p.y)); first = p; command = relative ? "l" : "L" }
                else if type == "L" { result.append(VectorCommand("L",p.x,p.y)) }
                else { let c = ["Q","T"].contains(previous) ? CGPoint(x:2*current.x-control.x,y:2*current.y-control.y) : current; result.append(VectorCommand("Q",c.x,c.y,p.x,p.y)); control = c }
                current = p
            case "H": let v = try read(1); current.x = v[0]+(relative ? current.x : 0); result.append(VectorCommand("L",current.x,current.y))
            case "V": let v = try read(1); current.y = v[0]+(relative ? current.y : 0); result.append(VectorCommand("L",current.x,current.y))
            case "C":
                let v = try read(6),a = point(v[0],v[1]),b = point(v[2],v[3]),p = point(v[4],v[5])
                result.append(VectorCommand("C",a.x,a.y,b.x,b.y,p.x,p.y)); control = b; current = p
            case "S":
                let v = try read(4),a = ["C","S"].contains(previous) ? CGPoint(x:2*current.x-control.x,y:2*current.y-control.y) : current,b = point(v[0],v[1]),p = point(v[2],v[3])
                result.append(VectorCommand("C",a.x,a.y,b.x,b.y,p.x,p.y)); control = b; current = p
            case "Q": let v = try read(4),c = point(v[0],v[1]),p = point(v[2],v[3]); result.append(VectorCommand("Q",c.x,c.y,p.x,p.y)); control = c; current = p
            case "A":
                let v = try read(7),p = point(v[5],v[6])
                guard [0,1].contains(v[3]),[0,1].contains(v[4]) else { throw DiagramError.invalid("Invalid SVG arc flags.") }
                result += arc(from:current,to:p,rx:v[0],ry:v[1],rotation:v[2],large:v[3] == 1,sweep:v[4] == 1); current = p
            case "Z": result.append(VectorCommand("Z")); current = first; command = ""
            default: throw DiagramError.invalid("Unsupported SVG path command.")
            }
            previous = type
        }; return result
    }
    private static func arc(from start:CGPoint,to end:CGPoint,rx:Double,ry:Double,rotation:Double,large:Bool,sweep:Bool) -> [VectorCommand] {
        guard hypot(end.x-start.x,end.y-start.y)>1e-12 else { return [] }
        var rx = abs(rx),ry = abs(ry)
        guard rx > 1e-12,ry > 1e-12 else { return [VectorCommand("L",end.x,end.y)] }
        let phi = rotation * .pi/180,c = cos(phi),s = sin(phi),dx = (start.x-end.x)/2,dy = (start.y-end.y)/2
        let x = c*dx+s*dy,y = -s*dx+c*dy,lambda = x*x/(rx*rx)+y*y/(ry*ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let denominator = rx*rx*y*y+ry*ry*x*x
        let factor = (large == sweep ? -1.0 : 1.0)*sqrt(max(0,(rx*rx*ry*ry-denominator)/max(denominator,1e-100)))
        let cx = factor*rx*y/ry,cy = -factor*ry*x/rx
        let center = CGPoint(x:c*cx-s*cy+(start.x+end.x)/2,y:s*cx+c*cy+(start.y+end.y)/2)
        let a = atan2((y-cy)/ry,(x-cx)/rx)
        var delta = atan2((-y-cy)/ry,(-x-cx)/rx)-a
        if sweep && delta < 0 { delta += 2 * .pi }; if !sweep && delta > 0 { delta -= 2 * .pi }
        let count = max(1,Int(ceil(abs(delta)/(.pi/2))))
        func p(_ t:Double) -> CGPoint { CGPoint(x:center.x+c*rx*cos(t)-s*ry*sin(t),y:center.y+s*rx*cos(t)+c*ry*sin(t)) }
        func d(_ t:Double) -> CGPoint { CGPoint(x:-c*rx*sin(t)-s*ry*cos(t),y:-s*rx*sin(t)+c*ry*cos(t)) }
        return (0..<count).map { i in
            let t = a+delta*Double(i)/Double(count),u = a+delta*Double(i+1)/Double(count),k = 4.0/3*tan((u-t)/4),p0 = p(t),p1 = i == count-1 ? end : p(u),d0 = d(t),d1 = d(u)
            return VectorCommand("C",p0.x+k*d0.x,p0.y+k*d0.y,p1.x-k*d1.x,p1.y-k*d1.y,p1.x,p1.y)
        }
    }
}
