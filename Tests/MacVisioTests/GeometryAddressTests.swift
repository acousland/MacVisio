import XCTest
@testable import MacVisio

final class GeometryAddressTests:XCTestCase {
    func testAddressAcceptsMixedCaseAndCellWithoutRow() {
        let address = GeometrySheet.address("gEoMeTrY12.NoShow")
        XCTAssertEqual(address?.section,11)
        XCTAssertNil(address?.row)
        XCTAssertEqual(address?.cell,"NoShow")
    }

    func testAddressPreservesZeroRowAndMaximumSupportedIndices() {
        XCTAssertEqual(GeometrySheet.address("Geometry1.X0")?.row,0)

        let maximum = GeometrySheet.address("Geometry4294967296.ABC4294967295")
        XCTAssertEqual(maximum?.section,Int(UInt32.max))
        XCTAssertEqual(maximum?.row,Int(UInt32.max))
    }

    func testAddressRejectsZeroAndOverflowingSectionsAndRows() {
        XCTAssertNil(GeometrySheet.address("Geometry0.X"))
        XCTAssertNil(GeometrySheet.address("Geometry01.X"))
        XCTAssertNil(GeometrySheet.address("Geometry4294967297.X"))
        XCTAssertNil(GeometrySheet.address("Geometry1.X4294967296"))
    }

    func testAddressRejectsMalformedReferences() {
        for reference in ["Width","Geometry.X","Geometry1.","Geometry1.X-1","Geometry1.X2.extra","Geometry 1.X2"] {
            XCTAssertNil(GeometrySheet.address(reference),reference)
        }
    }
}
