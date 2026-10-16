import CoreGraphics
import Foundation

struct DrawingLocation { let point: CGPoint }
struct CanvasLocation { let point: CGPoint }

/// Paper scale and view zoom are applied exactly once at the UI boundary.
struct ViewportCoordinates {
    let pageOrigin: CGPoint
    let paperScale: Double
    let zoom: Double
    var drawingToCanvasScale: Double { paperScale * zoom }

    func drawing(_ value: CanvasLocation) -> DrawingLocation {
        DrawingLocation(
            point: CGPoint(
                x: (value.point.x - pageOrigin.x) / drawingToCanvasScale,
                y: (value.point.y - pageOrigin.y) / drawingToCanvasScale))
    }

    func canvas(_ value: DrawingLocation) -> CanvasLocation {
        CanvasLocation(
            point: CGPoint(
                x: pageOrigin.x + value.point.x * drawingToCanvasScale,
                y: pageOrigin.y + value.point.y * drawingToCanvasScale))
    }
}
