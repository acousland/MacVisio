import Foundation
import CoreGraphics

struct DiagramPoint: Codable, Equatable {
    var x: Double
    var y: Double
    init(_ point: CGPoint) { x = point.x; y = point.y }
    init(x: Double, y: Double) { self.x = x; self.y = y }
    var cgPoint: CGPoint { CGPoint(x:x,y:y) }
}

struct VectorCommand: Codable, Equatable {
    var kind: String
    var values: [Double]
    init(_ kind: String, _ values: Double...) { self.kind = kind; self.values = values }
    init(kind: String, values: [Double]) { self.kind = kind; self.values = values }
    var isValid: Bool {
        isValid(xScale:1,yScale:1)
    }
    func isValid(xScale:Double,yScale:Double) -> Bool {
        guard values.enumerated().allSatisfy({ let physical = $0.element*($0.offset.isMultiple(of:2) ? xScale : yScale);return physical.isFinite && abs(physical) < 100000 }) else { return false }
        switch kind { case "M", "L": return values.count == 2; case "C": return values.count == 6; case "Q": return values.count == 4; case "Z": return values.isEmpty; default: return false }
    }
}
struct VectorPath: Codable, Equatable {
    var commands: [VectorCommand]
    var fill = true
    var stroke = true
    var evenOdd: Bool?
}
struct EmbeddedImage: Codable, Equatable {
    var data: Data
    var mimeType: String
}
struct ShapeDataProperty: Codable, Equatable, Identifiable {
    var key: String
    var label: String
    var value: String
    var type: Int = 0
    var format: String = ""
    var prompt: String = ""
    var id: String { key }
}
struct ShapeHyperlink: Codable, Equatable {
    var address: String
    var subAddress: String = ""
    var description: String = ""
    var sourceRowName: String? = nil
}
enum TextAlignment: String, Codable, CaseIterable { case left, center, right }
struct ShapeConnectionPoint:Codable,Equatable,Identifiable {
    var index:UInt32
    var name:String?
    var x:ShapeSheetCell
    var y:ShapeSheetCell
    var directionX:Double = 0
    var directionY:Double = 0
    var type:Int = 0
    var id:String { name.map{"N:"+$0} ?? "IX:\(index)" }
    var xCell:String { name.map{"Connections.\($0).X"} ?? "Connections.X\(UInt64(index)+1)" }
    var yCell:String { name.map{"Connections.\($0).Y"} ?? "Connections.Y\(UInt64(index)+1)" }
}
struct ShapeDetails: Codable, Equatable {
    var fontName: String = "System"
    var italic = false
    var underline = false
    var alignment: TextAlignment = .center
    var linePattern: Int = 1
    var paths: [VectorPath] = []
    var image: EmbeddedImage?
    var data: [ShapeDataProperty] = []
    var hyperlinks: [ShapeHyperlink] = []
    var layerNames: [String] = []
    var isGroup = false
    var flipX = false
    var flipY = false
    var sheet: [String:ShapeSheetCell] = [:]
    var sourceShapeID: String?
    var textBox: ShapeTextBox?
    var connectionPoints:[ShapeConnectionPoint] = []
    var negativeWidth:Bool?
    var negativeHeight:Bool?
    var textRuns:[ShapeTextRun]?
    var textFields:[ShapeTextField]?
    var geometry:[ShapeGeometrySection]?
    var controls:[ShapeControl] = []
    enum CodingKeys: String,CodingKey { case fontName,italic,underline,alignment,linePattern,paths,image,data,hyperlinks,layerNames,isGroup,flipX,flipY,sheet,sourceShapeID,textBox,connectionPoints,negativeWidth,negativeHeight,textRuns,textFields,geometry,controls }
}
extension ShapeDetails {
    init(from decoder:Decoder) throws {
        self.init();let c = try decoder.container(keyedBy:CodingKeys.self)
        fontName = try c.decodeIfPresent(String.self,forKey:.fontName) ?? "System"
        italic = try c.decodeIfPresent(Bool.self,forKey:.italic) ?? false;underline = try c.decodeIfPresent(Bool.self,forKey:.underline) ?? false
        alignment = try c.decodeIfPresent(TextAlignment.self,forKey:.alignment) ?? .center;linePattern = try c.decodeIfPresent(Int.self,forKey:.linePattern) ?? 1
        paths = try c.decodeIfPresent([VectorPath].self,forKey:.paths) ?? [];image = try c.decodeIfPresent(EmbeddedImage.self,forKey:.image)
        data = try c.decodeIfPresent([ShapeDataProperty].self,forKey:.data) ?? [];hyperlinks = try c.decodeIfPresent([ShapeHyperlink].self,forKey:.hyperlinks) ?? [];layerNames = try c.decodeIfPresent([String].self,forKey:.layerNames) ?? []
        isGroup = try c.decodeIfPresent(Bool.self,forKey:.isGroup) ?? false;flipX = try c.decodeIfPresent(Bool.self,forKey:.flipX) ?? false;flipY = try c.decodeIfPresent(Bool.self,forKey:.flipY) ?? false
        sheet = try c.decodeIfPresent([String:ShapeSheetCell].self,forKey:.sheet) ?? [:];sourceShapeID = try c.decodeIfPresent(String.self,forKey:.sourceShapeID)
        textBox = try c.decodeIfPresent(ShapeTextBox.self,forKey:.textBox)
        connectionPoints = try c.decodeIfPresent([ShapeConnectionPoint].self,forKey:.connectionPoints) ?? []
        negativeWidth = try c.decodeIfPresent(Bool.self,forKey:.negativeWidth);negativeHeight = try c.decodeIfPresent(Bool.self,forKey:.negativeHeight)
        textRuns = try c.decodeIfPresent([ShapeTextRun].self,forKey:.textRuns)
        textFields = try c.decodeIfPresent([ShapeTextField].self,forKey:.textFields)
        geometry = try c.decodeIfPresent([ShapeGeometrySection].self,forKey:.geometry)
        controls = try c.decodeIfPresent([ShapeControl].self,forKey:.controls) ?? []
    }
}
struct ShapeTextBox: Codable, Equatable {
    var centerX:Double = 0.5
    var centerY:Double = 0.5
    var width:Double = 1
    var height:Double = 1
    var rotation:Double = 0
    var left:Double = 0
    var right:Double = 0
    var top:Double = 0
    var bottom:Double = 0
    var verticalAlignment:Int = 1
    func rect(in node:DiagramNode) -> CGRect { CGRect(x:node.x+(centerX-width/2)*node.width+left,y:node.y+(centerY-height/2)*node.height+top,width:max(1,width*node.width-left-right),height:max(1,height*node.height-top-bottom)) }
}
struct ShapeSheetCell: Codable, Equatable {
    var value: String
    var formula: String = ""
    var unit: String = ""
}
struct DiagramLayer: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var visible = true
    var locked = false
    var printable = true
}
