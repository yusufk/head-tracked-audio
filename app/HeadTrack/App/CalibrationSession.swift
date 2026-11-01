import AppKit
import AVFoundation
import Synchronization
import SwiftUI

/// Runs the guided calibration: speaks each instruction, waits for the head
/// to settle, records features, then fits and saves the calibration.
@MainActor
final class CalibrationSession: ObservableObject {
    enum Phase: Equatable {
        case intro
        case step(CalibrationStep, settled: Bool)
        case done(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .intro
    @Published private(set) var progress: Double = 0

    /// Seconds to let the head settle, then seconds to record, per step.
    private let settleTime = 1.8
    private let recordTime = 1.6

    private let camera: CameraHeadTracker
    private let speech = AVSpeechSynthesizer()
    private let store = SampleStore()
    private var task: Task<Void, Never>?
    var onFinish: ((Calibration?) -> Void)?

    /// Thread-safe sample buffer shared with the camera queue.
    private final class SampleStore: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [CalibrationStep: [FaceFeatures]] = [:]
        private var step: CalibrationStep?

        func reset() { lock.withLock { samples = [:]; step = nil } }
        func record(_ s: CalibrationStep?) { lock.withLock { step = s } }
        func add(_ f: FaceFeatures) {
            lock.withLock { if let s = step { samples[s, default: []].append(f) } }
        }
        var all: [CalibrationStep: [FaceFeatures]] { lock.withLock { samples } }
    }

    init(camera: CameraHeadTracker) {
        self.camera = camera
    }

    func start() {
        store.reset()
        camera.isCalibrating.withLock { $0 = true }
        let store = store
        camera.onFeatures = { f in store.add(f) }

        task = Task { [weak self] in
            guard let self else { return }
            self.say("Calibration. Keep your shoulders still and move only your head.")
            try? await Task.sleep(for: .seconds(3.2))

            let steps = CalibrationStep.allCases
            for (i, s) in steps.enumerated() {
                if Task.isCancelled { return }
                self.phase = .step(s, settled: false)
                self.say(s.spoken)
                try? await Task.sleep(for: .seconds(self.settleTime))
                self.phase = .step(s, settled: true)
                self.store.record(s)
                try? await Task.sleep(for: .seconds(self.recordTime))
                self.store.record(nil)
                self.progress = Double(i + 1) / Double(steps.count)
            }
            self.finish()
        }
    }

    func cancel() {
        task?.cancel()
        speech.stopSpeaking(at: .immediate)
        cleanUp()
        onFinish?(nil)
    }

    private func finish() {
        let samples = store.all
        cleanUp()
        Self.writeLog(samples)
        do {
            let result = try CalibrationFitter.fit(samples)
            result.calibration.save()
            camera.calibration.withLock { $0 = result.calibration }
            let msg = String(format: "Done. Left/right range %.0f°, fit error %.1f° (left/right) and %.1f° (up/down). Tracking now runs at full speed.",
                             result.yawRange, result.yawRMS, result.pitchRMS)
            phase = .done(msg)
            say("Done. Calibration saved.")
            onFinish?(result.calibration)
        } catch {
            phase = .failed(error.localizedDescription)
            say("Calibration didn't work. Please try again.")
            onFinish?(nil)
        }
    }

    private func cleanUp() {
        camera.onFeatures = nil
        camera.isCalibrating.withLock { $0 = false }
        store.record(nil)
    }

    private func say(_ text: String) {
        speech.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.rate = 0.5
        speech.speak(u)
    }

    /// Raw samples for troubleshooting: ~/Library/Logs/HeadTrack/calibration.csv
    private static func writeLog(_ samples: [CalibrationStep: [FaceFeatures]]) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/HeadTrack")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var csv = "step,noseOffset,noseRatio,visionYaw,visionPitch\n"
        for step in CalibrationStep.allCases {
            for f in samples[step] ?? [] {
                csv += String(format: "%@,%.4f,%.4f,%.1f,%.1f\n", step.rawValue, f.noseOffset, f.noseRatio,
                              f.visionYaw ?? .nan, f.visionPitch ?? .nan)
            }
        }
        try? csv.write(to: dir.appendingPathComponent("calibration.csv"), atomically: true, encoding: .utf8)
    }
}

/// Large, glanceable prompt shown in the middle of the screen.
struct CalibrationView: View {
    @ObservedObject var session: CalibrationSession
    let close: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            switch session.phase {
            case .intro:
                Image(systemName: "face.dashed").font(.system(size: 64))
                Text("Calibration").font(.title.bold())
                Text("Keep your shoulders still and move only your head. You'll hear each instruction, so you don't need to read while turning.")
                    .multilineTextAlignment(.center)
            case let .step(step, settled):
                Image(systemName: step.symbol)
                    .font(.system(size: 96, weight: .bold))
                    .foregroundStyle(settled ? Color.green : Color.accentColor)
                Text(step.instruction).font(.title2).multilineTextAlignment(.center)
                Text(settled ? "Hold still…" : "Move now").foregroundStyle(.secondary)
            case let .done(message):
                Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green)
                Text(message).multilineTextAlignment(.center)
                Button("Close", action: close).keyboardShortcut(.defaultAction)
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 64)).foregroundStyle(.orange)
                Text(message).multilineTextAlignment(.center)
                Button("Close", action: close).keyboardShortcut(.defaultAction)
            }

            ProgressView(value: session.progress)
                .frame(width: 320)
                .accessibilityLabel("Calibration progress")

            if case .step = session.phase {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
            } else if case .intro = session.phase {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
            }
        }
        .padding(32)
        .frame(width: 520, height: 400)
    }
}
