import Foundation
import CoreGraphics

/// Cached EllipticalArcTo geometry: transform the three points into a circle,
/// solve its center, then convert the arc through the middle point to cubics.
enum VisioEllipticalArc {
    static func cubics(from start:CGPoint,through control:CGPoint,to end:CGPoint,angle:Double,ratio:Double) -> [(CGPoint,CGPoint,CGPoint)]? {
        guard angle.isFinite,ratio.isFinite,ratio > 0,ratio <= 1000 else { return nil }
        let c = cos(angle),s = sin(angle)
        func circular(_ point:CGPoint) -> CGPoint { let x = point.x-start.x,y = point.y-start.y;return CGPoint(x:c*x+s*y,y:(-s*x+c*y)*ratio) }
        let mid = circular(control),last = circular(end)
        let determinant = 2*(mid.x*last.y-mid.y*last.x),scale = max(1,hypot(mid.x,mid.y)*hypot(last.x,last.y))
        guard determinant.isFinite,abs(determinant) > 1e-12*scale else { return nil }
        let m = mid.x*mid.x+mid.y*mid.y,e = last.x*last.x+last.y*last.y
        let center = CGPoint(x:(m*last.y-e*mid.y)/determinant,y:(mid.x*e-last.x*m)/determinant),radius = hypot(center.x,center.y)
        guard center.x.isFinite,center.y.isFinite,radius.isFinite,radius > 1e-12,radius < 1e8 else { return nil }
        let firstAngle = atan2(-center.y,-center.x)
        func positive(_ value:Double) -> Double { let remainder = value.truncatingRemainder(dividingBy:2 * .pi);return remainder < 0 ? remainder+2 * .pi : remainder }
        let toEnd = positive(atan2(last.y-center.y,last.x-center.x)-firstAngle),toMid = positive(atan2(mid.y-center.y,mid.x-center.x)-firstAngle)
        let sweep = toMid <= toEnd+1e-10 ? toEnd : toEnd-2 * .pi
        guard abs(sweep) > 1e-12 else { return nil }
        func world(_ point:CGPoint) -> CGPoint { CGPoint(x:start.x+c*point.x-s*point.y/ratio,y:start.y+s*point.x+c*point.y/ratio) }
        let count = max(1,Int(ceil(abs(sweep)/(.pi/2))))
        var result:[(CGPoint,CGPoint,CGPoint)] = []
        for i in 0..<count {
            let a = firstAngle+sweep*Double(i)/Double(count),b = firstAngle+sweep*Double(i+1)/Double(count),k = 4.0/3*tan((b-a)/4)
            let p = CGPoint(x:center.x+radius*cos(a),y:center.y+radius*sin(a)),q = CGPoint(x:center.x+radius*cos(b),y:center.y+radius*sin(b))
            let first = world(CGPoint(x:p.x-k*radius*sin(a),y:p.y+k*radius*cos(a))),second = world(CGPoint(x:q.x+k*radius*sin(b),y:q.y-k*radius*cos(b))),endpoint = i == count-1 ? end : world(q)
            guard [first.x,first.y,second.x,second.y,endpoint.x,endpoint.y].allSatisfy({$0.isFinite && abs($0) < 1e8}) else { return nil }
            result.append((first,second,endpoint))
        }
        return result
    }
}
