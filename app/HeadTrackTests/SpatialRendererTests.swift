import AVFoundation
import XCTest
@testable import HeadTrack

/// 1 kHz tone on the LEFT channel only. 1 kHz gives a clear level difference
/// between the ears, so direction is easy to measure.
private final class LeftToneSource: StereoFrameSource {
    let rate: Double
    var phase = 0.0
    init(rate: Double) { self.rate = rate }

    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        for i in 0..<frames {
            left[i] = Float(sin(phase) * 0.5)
            right[i] = 0
            phase += 2 * .pi * 1000 / rate
        }
        return frames
    }
}

final class SpatialRendererTests: XCTestCase {
    /// Render ~0.5 s and return output RMS for (left ear, right ear).
    private func render(mode: SpatialMode, yaw: Double) throws -> (l: Float, r: Float) {
        let rate = 48_000.0
        let renderer = SpatialRenderer(source: LeftToneSource(rate: rate), sampleRate: rate)
        renderer.setRoom(0) // dry, so only direction affects levels
        try renderer.enableOfflineRendering()
        renderer.setMode(mode)
        renderer.setHead(Pose(yaw: yaw))
        try renderer.start()
        defer { renderer.stop() }

        let format = renderer.engine.manualRenderingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        var sumL: Float = 0, sumR: Float = 0, count = 0
        for block in 0..<6 {
            let status = try renderer.engine.renderOffline(4096, to: buffer)
            XCTAssertEqual(status, .success)
            guard block > 0 else { continue } // skip HRTF warm-up
            let n = Int(buffer.frameLength)
            let l = buffer.floatChannelData![0], r = buffer.floatChannelData![1]
            for i in 0..<n {
                sumL += l[i] * l[i]
                sumR += r[i] * r[i]
            }
            count += n
        }
        return (sqrt(sumL / Float(count)), sqrt(sumR / Float(count)))
    }

    func testStereoModeIsPlainStereo() throws {
        let out = try render(mode: .stereo, yaw: 0)
        XCTAssertGreaterThan(out.l, 0.1)
        XCTAssertLessThan(out.r, 0.001)
    }

    func testSpeakersModePlacesLeftChannelOnTheLeft() throws {
        let out = try render(mode: .speakers, yaw: 0)
        XCTAssertGreaterThan(out.l, out.r * 1.2, "left speaker should be louder in the left ear: \(out)")
        XCTAssertGreaterThan(out.r, 0.001, "HRTF should leak some sound to the far ear")
    }

    func testTurningLeftMovesLeftSpeakerToTheRightEar() throws {
        // Head turned 60 deg left: the left speaker (30 deg left) is now 30 deg right.
        let out = try render(mode: .tracked, yaw: 60)
        XCTAssertGreaterThan(out.r, out.l * 1.2, "expected right ear louder: \(out)")
    }

    func testTurningRightPushesLeftSpeakerFurtherLeft() throws {
        let straight = try render(mode: .tracked, yaw: 0)
        let turned = try render(mode: .tracked, yaw: -60)
        XCTAssertGreaterThan(turned.l / turned.r, straight.l / straight.r, "\(straight) vs \(turned)")
    }

    func testSpeakersModeIgnoresHeadPose() throws {
        let a = try render(mode: .speakers, yaw: 0)
        let b = try render(mode: .speakers, yaw: 60)
        XCTAssertEqual(a.l, b.l, accuracy: 0.01)
        XCTAssertEqual(a.r, b.r, accuracy: 0.01)
    }
}
