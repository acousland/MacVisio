import Foundation

enum GeometryAudit {
    struct Record:Codable { var page:String;var shape:String?;var width:Double;var height:Double;var issue:VisioFormat.GeometryIssue }
    struct Report:Codable { var file:String;var shapes:Int;var issues:[Record];var scope = "Cached NURBS, spline and polyline rendering" }
    static func inspect(_ input:URL,to output:URL) throws {
        let pages:[DiagramPage]
        if input.pathExtension.lowercased() == "vssx" { pages = try VisioStencil.read(from:input).items.map(\.fragment) }
        else { let doc = MacVisioDocument();try doc.read(from:input,ofType:MacVisioDocument.visioType);pages = doc.diagram.pages }
        var records:[Record] = []
        for page in pages { for node in page.nodes {
            guard let geometry = node.formatting.geometry else { continue }
            _ = VisioFormat.geometryPaths(geometry,width:node.sheetWidth/72,height:node.sheetHeight/72,onIssue:{records.append(Record(page:page.name,shape:node.formatting.sourceShapeID,width:node.sheetWidth/72,height:node.sheetHeight/72,issue:$0))})
        } }
        let report = Report(file:input.lastPathComponent,shapes:pages.reduce(0){$0+$1.nodes.count},issues:records),encoder = JSONEncoder();encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
        try encoder.encode(report).write(to:output,options:.atomic);print("\(report.file): \(records.count) effective geometry issues")
    }
}
