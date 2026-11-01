import XCTest
@testable import HeadTrack

final class CalibrationTests: XCTestCase {
    /// Synthetic face whose landmarks respond to yaw AND pitch (cross-talk),
    /// like the real data did. The fit should recover clean angles anyway.
    private func features(yaw: Double, pitch: Double, noise: Double = 0) -> FaceFeatures {
        let n = { Double.random(in: -noise...noise) }
        return FaceFeatures(
            noseOffset: 0.02 + 0.008 * yaw - 0.003 * pitch + n() * 0.01,
            noseRatio: 0.70 - 0.006 * pitch + 0.002 * yaw + n() * 0.01,
            visionYaw: yaw + n() * 2,
            visionPitch: pitch + yaw * 0.5 + n() * 2) // Vision's pitch is polluted by yaw
    }

    private func session(noise: Double = 0) -> [CalibrationStep: [FaceFeatures]] {
        let poses: [CalibrationStep: (Double, Double)] = [
            .centre: (0, 0), .left: (30, 0), .right: (-30, 0), .up: (0, 20), .down: (0, -20),
        ]
        return poses.mapValues { p in (0..<30).map { _ in features(yaw: p.0, pitch: p.1, noise: noise) } }
    }

    func testRecoversAnglesDespiteCrossTalk() throws {
        let result = try CalibrationFitter.fit(session())
        let cal = result.calibration
        for (yaw, pitch) in [(0.0, 0.0), (20, 0), (-25, 0), (0, 15), (0, -10), (15, 10)] {
            let p = cal.pose(from: features(yaw: yaw, pitch: pitch))
            XCTAssertEqual(p.yaw, yaw, accuracy: 0.5, "yaw for (\(yaw), \(pitch))")
            XCTAssertEqual(p.pitch, pitch, accuracy: 0.5, "pitch for (\(yaw), \(pitch))")
        }
        XCTAssertEqual(result.yawRange, 60, accuracy: 1)
        XCTAssertLessThan(result.yawRMS, 0.5)
    }

    func testRobustToNoise() throws {
        let cal = try CalibrationFitter.fit(session(noise: 1)).calibration
        let p = cal.pose(from: features(yaw: 30, pitch: 0))
        XCTAssertEqual(p.yaw, 30, accuracy: 4)
        XCTAssertEqual(p.pitch, 0, accuracy: 4)
    }

    func testTurningLeftIsPositiveYaw() throws {
        let cal = try CalibrationFitter.fit(session()).calibration
        XCTAssertGreaterThan(cal.pose(from: features(yaw: 25, pitch: 0)).yaw, 0)
        XCTAssertLessThan(cal.pose(from: features(yaw: -25, pitch: 0)).yaw, 0)
    }

    func testRejectsMissingStep() {
        var s = session()
        s[.down] = []
        XCTAssertThrowsError(try CalibrationFitter.fit(s))
    }

    func testRejectsNoMovement() {
        var s = session()
        s[.left] = s[.centre]
        s[.right] = s[.centre]
        XCTAssertThrowsError(try CalibrationFitter.fit(s))
    }

    func testLeastSquaresExactSolution() {
        // y = 2 + 3a - 4b
        let x = [[1, 0, 0], [1, 1, 0], [1, 0, 1], [1, 2, 3.0]]
        let y = x.map { 2 + 3 * $0[1] - 4 * $0[2] }
        let c = CalibrationFitter.leastSquares(x, y)!
        XCTAssertEqual(c[0], 2, accuracy: 1e-9)
        XCTAssertEqual(c[1], 3, accuracy: 1e-9)
        XCTAssertEqual(c[2], -4, accuracy: 1e-9)
    }
}
