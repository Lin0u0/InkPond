import XCTest
@testable import InkPond

final class SlideshowRegionTests: XCTestCase {
    func testSceneConversionBasisMustSettleIncludingRotationAndScale() {
        let settled = [CGPoint(x: 0, y: 0), CGPoint(x: 667, y: 0), CGPoint(x: 0, y: 399)]
        XCTAssertFalse(SlideshowSceneGeometry.matches([], []))
        XCTAssertFalse(SlideshowSceneGeometry.matches(settled, Array(settled.prefix(2))))
        XCTAssertTrue(SlideshowSceneGeometry.matches(settled, settled))
        let rotating = [CGPoint(x: 0, y: 0), CGPoint(x: 650, y: 17), CGPoint(x: -17, y: 382)]
        XCTAssertFalse(SlideshowSceneGeometry.matches(rotating, settled))
        var scaled = settled
        scaled[1].x = 388.17
        XCTAssertFalse(SlideshowSceneGeometry.matches(scaled, settled))
    }

    func testPixelSafeRegionProvidesRealFractionalFoldClearance() {
        let bounds = CGRect(x: 0, y: 0, width: 951, height: 669)
        let fold = CGRect(x: 435.5, y: 0, width: 80, height: 669)
        let region = SlideshowUsableRegion.pixelSafe(in: bounds, excluding: [fold])
        XCTAssertEqual(region, CGRect(x: 1, y: 1, width: 433.5, height: 667))
        XCTAssertEqual(fold.minX - region.maxX, 1, accuracy: 0.0001)
        XCTAssertEqual(SlideshowUsableRegion.pixelSafe(in: bounds, excluding: []), bounds)
    }

    func testFlatUsesEntireContainer() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 700)
        XCTAssertEqual(SlideshowUsableRegion.largest(in: bounds, excluding: []), bounds)
    }

    func testBothFoldAxesAndOffCenterDivision() {
        let bounds = CGRect(x: 0, y: 0, width: 900, height: 700)
        for fold in [CGRect(x: 440, y: 0, width: 20, height: 700),
                     CGRect(x: 0, y: 280, width: 900, height: 30)] {
            let region = SlideshowUsableRegion.largest(in: bounds, excluding: [fold])
            XCTAssertTrue(bounds.contains(region))
            let overlap = region.intersection(fold)
            XCTAssertTrue(overlap.isNull || overlap.width == 0 || overlap.height == 0)
            XCTAssertGreaterThan(region.width * region.height, 0)
        }
        XCTAssertEqual(SlideshowUsableRegion.largest(in: bounds, excluding: [CGRect(x: 0, y: 280, width: 900, height: 30)]),
                       CGRect(x: 0, y: 310, width: 900, height: 390))
    }

    func testCameraAndFoldStayOutsideSelectedRectangle() {
        let bounds = CGRect(x: 30, y: 20, width: 800, height: 600)
        let obstacles = [CGRect(x: 420, y: 0, width: 20, height: 800),
                         CGRect(x: 30, y: 20, width: 100, height: 50)]
        let region = SlideshowUsableRegion.largest(in: bounds, excluding: obstacles)
        XCTAssertTrue(bounds.contains(region))
        for obstacle in obstacles {
            let overlap = region.intersection(obstacle)
            XCTAssertTrue(overlap.isNull || overlap.width == 0 || overlap.height == 0)
        }
    }
}
