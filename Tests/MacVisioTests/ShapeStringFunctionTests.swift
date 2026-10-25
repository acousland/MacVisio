import XCTest
@testable import MacVisio

final class ShapeStringFunctionTests: XCTestCase {
    private func evaluate(_ formula: String) throws -> SheetValue {
        try TypedShapeSheet.evaluate(formula, resolve: { _ in .number(0) }, call: { name, _ in
            throw DiagramError.invalid("Unexpected external function: \(name)")
        })
    }

    func testVisioDocumentedStringFunctionExamplesAndOptionalArguments() throws {
        XCTAssertEqual(try evaluate("LEFT(\"January 1, 2004\",3)"), .string("Jan"))
        XCTAssertEqual(try evaluate("LEFT(\"January\")"), .string("J"))
        XCTAssertEqual(try evaluate("RIGHT(\"January 1, 2004\",4)"), .string("2004"))
        XCTAssertEqual(try evaluate("RIGHT(\"January\")"), .string("y"))
        XCTAssertEqual(try evaluate("MID(\"SSN 999-99-9999\",5,11)"), .string("999-99-9999"))
        XCTAssertEqual(try evaluate("REPLACE(\"01/03/2002\",9,2,\"03\")"), .string("01/03/2003"))
        XCTAssertEqual(try evaluate("FIND(\"2003\",\"January 1, 2003\")"), .number(12))
        XCTAssertEqual(try evaluate("FIND(\"wide\",\"A WIDE label\",1,TRUE)"), .number(3))
        XCTAssertEqual(try evaluate("SUBSTITUTE(\"1 January 2003\",\"January\",\"JAN\")"), .string("1 JAN 2003"))
        XCTAssertEqual(try evaluate("SUBSTITUTE(\"a A a\",\"a\",\"x\",2,TRUE)"), .string("a x a"))
        XCTAssertEqual(try evaluate("SUBSTITUTE(\"a a a\",\"a\",\"x\",2)"), .string("a x a"))
        XCTAssertEqual(try evaluate("SUBSTITUTE(\"a a a\",\"a\",\"x\",99)"), .string("a a a"))
        XCTAssertEqual(try evaluate("REPT(\"*\",4.9)"), .string("****"))
        XCTAssertEqual(try evaluate("REPT(\"\",1e100)"), .string(""))
        XCTAssertEqual(try evaluate("INDEX(3,\"cat;rat;;goat\")"), .string("goat"))
        XCTAssertEqual(try evaluate("INDEX(1,\";1;2;3;\")"), .string("1"))
        XCTAssertEqual(try evaluate("INDEX(2,\";1;2;3;\")"), .string("2"))
        XCTAssertEqual(try evaluate("INDEX(3,\";1;2;3;\")"), .string("3"))
        XCTAssertEqual(try evaluate("INDEX(0,\";1;2;3;\")"), .string(""))
        XCTAssertEqual(try evaluate("INDEX(4,\";1;2;3;\")"), .string(""))
        XCTAssertEqual(try evaluate("INDEX(0,\";1;2;3;\",,\"OUT\")"), .string(""))
        XCTAssertEqual(try evaluate("INDEX(4,\";1;2;3;\",,\"OUT\")"), .string(""))
        XCTAssertEqual(try evaluate("INDEX(5,\";1;2;3;\",,\"OUT\")"), .string("OUT"))
        XCTAssertEqual(try evaluate("INDEX(1,\"red|green||blue\",\"|\")"), .string("green"))
        XCTAssertEqual(try evaluate("INDEX(2,\"red|green||blue\",\"|\")"), .string(""))
        XCTAssertEqual(try evaluate("INDEX(2,\"red|green||blue\",\"|\",\"OUT\")"), .string(""))
        XCTAssertEqual(try evaluate("INDEX(-1,\"a;b\",\";\",\"OUT\")"), .string("OUT"))
        XCTAssertEqual(try evaluate("INDEX(1,\"alpha🧭::beta🧭::gamma\",\"🧭::\")"), .string("beta"))
        XCTAssertEqual(try evaluate("INDEX(54,\";1;2;3;\",,\"ERROR\")"), .string("ERROR"))
        XCTAssertEqual(try evaluate("INDEX(54,\"a;b\",\";\",99)"), .number(99))
        XCTAssertEqual(try evaluate("CHAR(9)"), .string("\t"))
        XCTAssertEqual(try evaluate("CHAR(65)"), .string("A"))
        XCTAssertEqual(try evaluate("UNICHAR(8364)"), .string("€"))
        XCTAssertEqual(try evaluate("LEN(\"A😀B\")"), .number(4))
        XCTAssertEqual(try evaluate("LEFT(\"\")"), .string(""))
        XCTAssertEqual(try evaluate("RIGHT(\"\")"), .string(""))
        XCTAssertEqual(try evaluate("MID(\"\",1,0)"), .string(""))
        XCTAssertEqual(try evaluate("REPLACE(\"\",1,0,\"x\")"), .string("x"))
        XCTAssertEqual(try evaluate("LEN(\"é\")"), .number(2))
        XCTAssertEqual(try evaluate("LEFT(\"é\",1)"), .string("e"))
        XCTAssertEqual(try evaluate("RIGHT(\"é\",1)"), .string("́"))
        XCTAssertEqual(try evaluate("MID(\"é\",2,1)"), .string("́"))
    }

    func testSTRSAMEEXInvariantASCIISubset() throws {
        XCTAssertEqual(try evaluate("STRSAMEEX(\"Valve A\",\"Valve A\",0,0)"), .boolean(true))
        XCTAssertEqual(try evaluate("STRSAMEEX(\"Valve A\",\"VALVE A\",0,1)"), .boolean(true))
        XCTAssertEqual(try evaluate("STRSAMEEX(\"Valve A\",\"VALVE A\",0,0)"), .boolean(false))
        XCTAssertEqual(try evaluate("STRSAMEEX(\"Valve A\",\"Valve B\",0,1)"), .boolean(false))
        XCTAssertEqual(try evaluate("STRSAMEEX(\"a\",\"a\",-1,0)"), .boolean(false))
        XCTAssertEqual(try evaluate("STRSAMEEX(\"a\",\"a\",0.5,0)"), .boolean(false))
        XCTAssertEqual(try evaluate("STRSAMEEX(\"a\",\"a\",0,8)"), .boolean(false))
        XCTAssertEqual(try evaluate("STRSAMEEX(\"a\",\"a\",0,0.5)"), .boolean(false))
        XCTAssertThrowsError(try evaluate("STRSAMEEX(\"café\",\"CAFÉ\",0,1)"))
        XCTAssertThrowsError(try evaluate("STRSAMEEX(\"a\",\"A\",1033,1)"))
        XCTAssertThrowsError(try evaluate("STRSAMEEX(\"a\",\"A\",0,2)"))
        XCTAssertThrowsError(try evaluate("STRSAMEEX(\"a\",\"a\",0)"))
    }

    func testInstallerShapeDataIndexFormula() throws {
        // Extracted from BLDCOR_M.VSSX's master10.xml SubType.Value formula:
        // INDEX(0,Prop.SubType.Format), with its public Format cell contents.
        let result = try TypedShapeSheet.evaluate("INDEX(0,Prop.SubType.Format)", resolve: { name in
            XCTAssertEqual(name, "Prop.SubType.Format")
            return .string("1:12;1:16;1:20")
        }, call: { name, _ in
            throw DiagramError.invalid("Unexpected external function: \(name)")
        })
        XCTAssertEqual(result, .string("1:12"))
    }

    func testUTF16PositionsAndSurrogateSafeResults() throws {
        XCTAssertEqual(try evaluate("MID(\"A😀B\",2,2)"), .string("😀"))
        XCTAssertEqual(try evaluate("LEFT(\"A😀B\",3)"), .string("A😀"))
        XCTAssertEqual(try evaluate("RIGHT(\"A😀B\",3)"), .string("😀B"))
        XCTAssertEqual(try evaluate("FIND(\"B\",\"A😀B\")"), .number(4))
        XCTAssertEqual(try evaluate("FIND(\"\",\"A😀B\",2)"), .number(2))
        XCTAssertThrowsError(try evaluate("LEFT(\"A😀B\",2)"))
        XCTAssertThrowsError(try evaluate("RIGHT(\"A😀B\",2)"))
        XCTAssertThrowsError(try evaluate("MID(\"A😀B\",2,1)"))
        XCTAssertThrowsError(try evaluate("FIND(\"\",\"A😀B\",3)"))
        XCTAssertThrowsError(try evaluate("FIND(\"\",\"\")"))
        XCTAssertThrowsError(try evaluate("FIND(\"\",\"\",1)"))
    }

    func testErrorsForInvalidArityPositionsAndUnsupportedNames() {
        for formula in [
            "MID(\"abc\",0,1)", "MID(\"abc\",1,-1)", "LEFT(\"abc\",1.5)",
            "FIND(\"x\",\"abc\")", "FIND(\"x\",\"abc\",0)", "FIND(\"x\",\"abc\",4)",
            "REPLACE(\"abc\",0,1,\"x\")",
            "SUBSTITUTE(\"aaa\",\"a\",\"b\",0)",
            "REPT(\"x\",-1)", "CHAR(0)", "CHAR(128)", "UNICHAR(65536)",
            "INDEX(\"1\",\"a;b\")", "INDEX(1.5,\"a;b\")", "INDEX(0,\"a;b\",\"\")",
            "SEARCH(\"x\",\"abc\")", "CODE(\"A\")", "MID(\"abc\",1)"
        ] {
            XCTAssertThrowsError(try evaluate(formula), formula)
        }
    }

    func testSubstituteSearchWithCombiningAndVariationCharactersTerminates() {
        for formula in [
            "SUBSTITUTE(\"á\",\"́\",\"x\",1,TRUE)",
            "SUBSTITUTE(\"❤️\",\"️\",\"x\",1,TRUE)",
            "SUBSTITUTE(\"👩‍👩\",\"‍\",\"x\",1,TRUE)"
        ] {
            do {
                let result = try evaluate(formula)
                if case .string = result { } else { XCTFail("Expected string or a diagnostic for \(formula)") }
            } catch {
                // These Unicode collation boundaries are host-library dependent.
            }
        }
    }

    func testGeneratedStringsStayWithinTheEvaluatorResultLimit() {
        XCTAssertThrowsError(try evaluate("REPT(\"0123456789\",100001)"))
        let source = String(repeating: "a", count: 12_000)
        let replacement = String(repeating: "x", count: 100)
        XCTAssertThrowsError(try evaluate("SUBSTITUTE(\"\(source)\",\"a\",\"\(replacement)\")"))

        let selectedOnly = String(repeating: "x", count: 600_000)
        let selected = try? TypedShapeSheet.evaluate("SUBSTITUTE(Source,\"a\",Replacement,2)", resolve: { name in
            name == "Source" ? .string("a a") : .string(selectedOnly)
        }, call: { _, _ in .number(0) })
        XCTAssertEqual(selected, .string("a \(selectedOnly)"))

        XCTAssertThrowsError(try TypedShapeSheet.evaluate("FIND(Needle,Source)", resolve: { name in
            name == "Source" ? .string(String(repeating: "a", count: 60_000)) : .string(String(repeating: "b", count: 60_000))
        }, call: { _, _ in .number(0) }))
    }

    func testStringPropertiesDriveGeometryAndRecalculateAfterTextChanges() throws {
        func cell(_ value: String, _ formula: String = "", _ unit: String = "") -> ShapeSheetCell {
            ShapeSheetCell(value: value, formula: formula, unit: unit)
        }
        var diagram = Diagram()
        var node = DiagramNode(x: 100, y: 100, text: "A wide label")
        node.width = 288
        node.height = 144
        node.formatting.sourceShapeID = "41"
        node.formatting.sheet = ShapeSheetEngine.defaults(node, page: diagram.page).mapValues {
            ShapeSheetCell(value: ShapeSheetEngine.format($0))
        }
        node.formatting.sheet["User.Slug"] = cell("", "SUBSTITUTE(LOWER(TheText),\" \",\"-\")", "STR")
        node.formatting.geometry = [ShapeGeometrySection(index: 0, cells: [:], rows: [
            ShapeGeometryRow(index: 1, type: "MoveTo", cells: ["X": cell("0"), "Y": cell("0")]),
            ShapeGeometryRow(index: 2, type: "LineTo", cells: ["X": cell("0", "IFERROR(FIND(\"wide\",TheText),Width/2)"), "Y": cell("0")])
        ])]
        diagram.page.nodes = [node]

        let initial = ShapeSheetEngine.recalculate(diagram)
        XCTAssertTrue(initial.issues.isEmpty, initial.issues.joined(separator: "\n"))
        XCTAssertEqual(initial.diagram.page.nodes[0].formatting.sheet["User.Slug"]?.value, "a-wide-label")
        XCTAssertEqual(initial.diagram.page.nodes[0].formatting.geometry?[0].rows[1].cells["X"]?.value, "3")

        var changed = initial.diagram
        changed.page.nodes[0].text = "Plain label"
        let updated = ShapeSheetEngine.recalculate(changed, previous: initial.diagram)
        XCTAssertTrue(updated.issues.isEmpty, updated.issues.joined(separator: "\n"))
        XCTAssertEqual(updated.diagram.page.nodes[0].formatting.sheet["User.Slug"]?.value, "plain-label")
        XCTAssertEqual(updated.diagram.page.nodes[0].formatting.geometry?[0].rows[1].cells["X"]?.value, "2")
    }
}
