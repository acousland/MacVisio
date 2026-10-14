import XCTest
@testable import MacVisio

final class ShapeSnappingTests: XCTestCase {
    func testAlignsNearestEdgesAndCentersWithinThreshold() {
        let moving = CGRect(x: 0, y: 0, width: 10, height: 10)
        let target = CGRect(x: 12, y: 0, width: 10, height: 10)

        let delta = ShapeSnapping.alignmentDelta(moving: moving, targets: [target], tolerance: 3)

        XCTAssertEqual(delta.x, 2, accuracy: 1e-9)
        XCTAssertEqual(delta.y, 0, accuracy: 1e-9)
    }

    func testDoesNotAlignOutsideThresholdOrWithoutTargets() {
        let moving = CGRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertEqual(ShapeSnapping.alignmentDelta(moving: moving, targets: [CGRect(x: 20, y: 20, width: 10, height: 10)], tolerance: 2), .zero)
        XCTAssertEqual(ShapeSnapping.alignmentDelta(moving: moving, targets: [], tolerance: 10), .zero)
    }

    func testChoosesTheSmallestIndependentAxisAdjustment() {
        let moving = CGRect(x: 0, y: 0, width: 10, height: 10)
        let targets = [CGRect(x: 13, y: 8, width: 20, height: 10), CGRect(x: 8, y: 13, width: 10, height: 20)]

        let delta = ShapeSnapping.alignmentDelta(moving: moving, targets: targets, tolerance: 4)

        XCTAssertEqual(delta.x, -2, accuracy: 1e-9)
        XCTAssertEqual(delta.y, -2, accuracy: 1e-9)
    }

    func testLayerSnapAndGlueSettingsControlTargetEligibility() {
        let enabled = DiagramLayer(name:"Enabled",snap:true,glue:true)
        let disabled = DiagramLayer(name:"Disabled",snap:false,glue:false)
        var page = DiagramPage(layers:[enabled,disabled])
        var target = DiagramNode(x:10,y:10);target.layer = "Enabled"
        XCTAssertTrue(page.permitsShapeSnap(to:target));XCTAssertTrue(page.permitsGlue(to:target))
        target.layer = "Disabled"
        XCTAssertFalse(page.permitsShapeSnap(to:target));XCTAssertFalse(page.permitsGlue(to:target))
        target.formatting.layerNames = ["Enabled"]
        XCTAssertFalse(page.permitsShapeSnap(to:target));XCTAssertFalse(page.permitsGlue(to:target))
        page.layers = nil;target.formatting.layerNames = [];target.layer = "Unlisted"
        XCTAssertTrue(page.permitsShapeSnap(to:target));XCTAssertTrue(page.permitsGlue(to:target))
    }

    func testRotatedShapeUsesItsTransformedAlignmentBounds() {
        var node = DiagramNode(x:0,y:0);node.width = 10;node.height = 4;node.rotation = 90
        let bounds = ShapeSnapping.bounds(of:node)
        XCTAssertEqual(bounds.width,4,accuracy:1e-9)
        XCTAssertEqual(bounds.height,10,accuracy:1e-9)
    }
}
