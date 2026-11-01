import XCTest
@testable import HeadTrack

final class HeadPoseTests: XCTestCase {
    func testOneEuroConvergesAndTracksVelocity() {
        var f = OneEuroFilter(minCutoff: 1, beta: 0.05)
        var v = 0.0
        for i in 0...120 { v = f.filter(10, at: Double(i) / 60) }
        XCTAssertEqual(v, 10, accuracy: 1e-3)

        var g = OneEuroFilter(minCutoff: 1, beta: 0.05)
        for i in 0...120 { _ = g.filter(Double(i) * 0.5, at: Double(i) / 60) } // 30 deg/s
        XCTAssertEqual(g.velocity, 30, accuracy: 3)
    }

    func testAutoCentreAndRecentre() {
        var t = HeadPoseTracker()
        t.update(Pose(yaw: 12, pitch: -5), at: 1.0)
        XCTAssertEqual(t.pose(at: 1.0).pose.yaw, 0, accuracy: 1e-9)

        var time = 1.016
        while time < 3 { t.update(Pose(yaw: 42, pitch: -5), at: time); time += 0.016 }
        XCTAssertEqual(t.pose(at: 3).pose.yaw, 30, accuracy: 0.5)

        t.recentre()
        XCTAssertEqual(t.pose(at: 3).pose.yaw, 0, accuracy: 1e-9)
    }

    func testInvertYaw() {
        var t = HeadPoseTracker()
        t.update(Pose(), at: 0)
        var time = 0.016
        while time < 2 { t.update(Pose(yaw: 20), at: time); time += 0.016 }
        let a = t.pose(at: 2).pose.yaw
        t.invertYaw = true
        XCTAssertEqual(t.pose(at: 2).pose.yaw, -a, accuracy: 1e-9)
    }

    func testEasesToCentreWhenFaceLost() {
        var t = HeadPoseTracker()
        t.update(Pose(), at: 0)
        var time = 0.016
        while time < 2 { t.update(Pose(yaw: 30), at: time); time += 0.016 }
        let last = t.lastSampleTime
        XCTAssertTrue(t.pose(at: last + 0.1).tracking)
        let mid = t.pose(at: last + t.holdSeconds + t.easeSeconds / 2)
        XCTAssertFalse(mid.tracking)
        XCTAssert(mid.pose.yaw > 5 && mid.pose.yaw < 25, "mid \(mid.pose.yaw)")
        XCTAssertEqual(t.pose(at: last + t.holdSeconds + t.easeSeconds + 0.01).pose.yaw, 0, accuracy: 1e-9)
    }

    func testPredictionOnlyWhenAsked() {
        var t = HeadPoseTracker()
        t.update(Pose(), at: 0)
        var time = 0.0
        while time < 1 { t.update(Pose(yaw: time * 60), at: time); time += 0.016 } // 60 deg/s
        let now = t.lastSampleTime
        let plain = t.pose(at: now).pose.yaw
        let ahead = t.pose(at: now, ahead: 0.1).pose.yaw
        XCTAssert(ahead - plain > 3 && ahead - plain < 9, "predicted +\(ahead - plain)")
    }
}

final class StereoRingBufferTests: XCTestCase {
    func testRoundTripAndUnderrun() {
        let ring = StereoRingBuffer(capacityFrames: 64, maxLatencyFrames: 64)
        let l: [Float] = [1, 2, 3], r: [Float] = [-1, -2, -3]
        ring.write(left: l, right: r, frames: 3)
        XCTAssertEqual(ring.availableFrames, 3)

        var outL = [Float](repeating: 9, count: 5), outR = [Float](repeating: 9, count: 5)
        let got = ring.read(left: &outL, right: &outR, frames: 5)
        XCTAssertEqual(got, 3)
        XCTAssertEqual(outL, [1, 2, 3, 0, 0])
        XCTAssertEqual(outR, [-1, -2, -3, 0, 0])
        XCTAssertEqual(ring.availableFrames, 0)
    }

    func testSkipsBacklogBeyondLatencyBudget() {
        let ring = StereoRingBuffer(capacityFrames: 64, maxLatencyFrames: 4)
        let l = (0..<10).map(Float.init), r = l.map { -$0 }
        ring.write(left: l, right: r, frames: 10)
        var outL = [Float](repeating: 0, count: 2), outR = [Float](repeating: 0, count: 2)
        ring.read(left: &outL, right: &outR, frames: 2)
        // Only the newest 4 frames are kept; reading 2 gives frames 6 and 7.
        XCTAssertEqual(outL, [6, 7])
    }

    func testWrapsAround() {
        let ring = StereoRingBuffer(capacityFrames: 8, maxLatencyFrames: 8)
        var outL = [Float](repeating: 0, count: 6), outR = [Float](repeating: 0, count: 6)
        for round in 0..<5 {
            let l = (0..<6).map { Float(round * 10 + $0) }
            ring.write(left: l, right: l, frames: 6)
            ring.read(left: &outL, right: &outR, frames: 6)
            XCTAssertEqual(outL, l)
        }
    }
}
