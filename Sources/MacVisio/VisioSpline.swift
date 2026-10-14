import Foundation

enum VisioSpline {
    struct Definition { var data:CompositeGeometry;var firstKnot:Double;var penultimateKnot:Double;var end:CGPoint }
    static func definition(_ rows:[ShapeGeometryRow]) throws -> Definition {
        guard rows.count >= 2,rows.first?.type == "SplineStart",rows.dropFirst().allSatisfy({$0.type == "SplineKnot"}) else { throw DiagramError.invalid("SplineStart requires following SplineKnot rows.") }
        func number(_ row:ShapeGeometryRow,_ key:String) throws -> Double {
            guard let value = row.cells[key].flatMap({Double($0.value)}),value.isFinite else { throw DiagramError.invalid("Missing or invalid spline cell: \(key).") };return value
        }
        let first = rows[0],last = rows.last!,degree = try number(first,"D")
        guard let integer = Int(exactly:degree),(1...25).contains(integer) else { throw DiagramError.invalid("Invalid spline degree.") }
        var values = [try number(first,"C"),degree,1,1]
        for row in rows.dropLast() { values += [try number(row,"X"),try number(row,"Y"),try number(row,"A"),1] }
        let data = CompositeGeometry(name:"NURBS",values:values);try data.validate()
        return Definition(data:data,firstKnot:try number(first,"B"),penultimateKnot:try number(last,"A"),end:CGPoint(x:try number(last,"X"),y:try number(last,"Y")))
    }
}
