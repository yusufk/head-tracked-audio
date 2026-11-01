import XCTest
@testable import HeadTrack

final class CameraPoseTests: XCTestCase {
    func testNeutralNoseRatioIsLevel() {
        XCTAssertEqual(CameraHeadTracker.pitchFromNoseRatio(0.70), 0, accuracy: 1e-9)
    }

    func testNoseTowardsMouthMeansLookingDown() {
        XCTAssertLessThan(CameraHeadTracker.pitchFromNoseRatio(0.85), -15)
        XCTAssertGreaterThan(CameraHeadTracker.pitchFromNoseRatio(0.55), 15)
    }

    func testRecordedRangeIsPlausible() {
        // Real samples ranged 0.51 to 0.91 while reading and typing.
        let up = CameraHeadTracker.pitchFromNoseRatio(0.51)
        let down = CameraHeadTracker.pitchFromNoseRatio(0.91)
        XCTAssert((20...45).contains(up), "up \(up)")
        XCTAssert((-45 ... -20).contains(down), "down \(down)")
    }

    func testExtremeRatiosAreClamped() {
        XCTAssertEqual(CameraHeadTracker.pitchFromNoseRatio(5), -90, accuracy: 1e-9)
        XCTAssertEqual(CameraHeadTracker.pitchFromNoseRatio(-5), 90, accuracy: 1e-9)
    }
}
