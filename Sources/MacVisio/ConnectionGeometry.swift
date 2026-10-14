import Foundation
import CoreGraphics

enum ConnectionGeometry {
    static func local(_ port:ShapeConnectionPoint,on node:DiagramNode) -> CGPoint {
        func value(_ cell:ShapeSheetCell) -> Double {
            let cached = Double(cell.value) ?? 0
            guard !cell.formula.isEmpty else { return cached }
            let result = (try? ShapeSheet.evaluate(cell.formula){name in
                if name.caseInsensitiveCompare("Width") == .orderedSame { return node.sheetWidth/72 }
                if name.caseInsensitiveCompare("Height") == .orderedSame { return node.sheetHeight/72 }
                if let value = node.formatting.sheet.first(where:{$0.key.caseInsensitiveCompare(name) == .orderedSame}).flatMap({Double($0.value.value)}),value.isFinite { return value }
                throw DiagramError.invalid("Unresolved connection-point formula.")
            }) ?? cached
            return result.isFinite && abs(result)<100000 ? result : cached
        }
        return CGPoint(x:value(port.x),y:value(port.y))
    }
    static func point(_ port:ShapeConnectionPoint,on node:DiagramNode) -> CGPoint {
        let p = local(port,on:node);return DiagramCoordinates.world(CGPoint(x:p.x*72-node.sheetOrigin.x,y:node.height-p.y*72+node.sheetOrigin.y),in:node)
    }
    static func cached(_ points:[ShapeConnectionPoint],on node:DiagramNode) -> [ShapeConnectionPoint] {
        points.map { port in var next = port;let p = local(port,on:node)
            if Double(port.x.value).map({abs($0-p.x)>1e-10}) ?? true { next.x.value = ShapeSheetEngine.format(p.x) }
            if Double(port.y.value).map({abs($0-p.y)>1e-10}) ?? true { next.y.value = ShapeSheetEngine.format(p.y) }
            return next
        }
    }
    static func port(_ key:String?,on node:DiagramNode?) -> ShapeConnectionPoint? { guard let key,let node else { return nil };return node.formatting.connectionPoints.first{$0.id == key} }
    static func fixed(_ key:String?,on node:DiagramNode?) -> CGPoint? { guard let node,let port = port(key,on:node) else { return nil };return point(port,on:node) }
    static func matching(cell:String,part:String?,on node:DiagramNode) -> ShapeConnectionPoint? {
        let name = cell.lowercased()
        if let found = node.formatting.connectionPoints.first(where:{$0.xCell.lowercased() == name || $0.yCell.lowercased() == name || "connections.x\(UInt64($0.index)+1)" == name || "connections.y\(UInt64($0.index)+1)" == name}) { return found }
        if let part = Int64(part ?? ""),part>=100 { return node.formatting.connectionPoints.first{UInt64($0.index) == UInt64(part-100)} }
        return nil
    }
    static func cell(_ key:String,on node:DiagramNode) -> ShapeSheetCell? {
        for port in node.formatting.connectionPoints {
            if port.xCell.caseInsensitiveCompare(key) == .orderedSame || "Connections.X\(UInt64(port.index)+1)".caseInsensitiveCompare(key) == .orderedSame { return port.x }
            if port.yCell.caseInsensitiveCompare(key) == .orderedSame || "Connections.Y\(UInt64(port.index)+1)".caseInsensitiveCompare(key) == .orderedSame { return port.y }
        };return nil
    }
    static func destination(_ key:String?,on node:DiagramNode?) -> (x:String,y:String,part:String) {
        if let port = port(key,on:node) { return (port.xCell,port.yCell,String(UInt64(port.index)+100)) }
        return ("PinX","PinY","3")
    }
}
