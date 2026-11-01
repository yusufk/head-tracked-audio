import AVFoundation
import Combine
import CoreAudio
import QuartzCore
import SwiftUI

/// Owns the pipeline: system audio tap -> ring -> spatial renderer, with the
/// camera driving head pose. All UI state lives here.
@MainActor
final class AppModel: ObservableObject {
    // Settings
    @Published var isOn = false { didSet { isOn ? startAudio() : stopAudio() } }
    @Published var mode: SpatialMode = .tracked { didSet { modeChanged() } }
    @Published var width: Double = 30 { didSet { renderer?.setWidth(width) } }
    @Published var room: Double = 0.15 { didSet { renderer?.setRoom(Float(room)) } }
    @Published var predictionMs: Double = 0
    @Published var usePitch = true
    @Published var invertYaw = false { didSet { poseStore.invertYaw = invertYaw } }
    @Published var invertPitch = false { didSet { poseStore.invertPitch = invertPitch } }

    // Readouts
    @Published private(set) var head = Pose()
    @Published private(set) var tracking = false
    @Published private(set) var cameraOn = false
    @Published private(set) var cameraFps = 0
    /// False if Vision isn't reporting pitch for this camera/OS.
    @Published private(set) var pitchAvailable = true
    @Published private(set) var latencyMs: Double?
    @Published private(set) var outputName = ""
    @Published private(set) var status = "Off"
    @Published private(set) var error: String?

    let poseStore = HeadPoseStore()
    private let ring = StereoRingBuffer()
    private lazy var tap = SystemAudioTap(ring: ring)
    private var renderer: SpatialRenderer?
    private let camera = CameraHeadTracker()
    private var timer: Timer?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var configObserver: NSObjectProtocol?

    init() {
        camera.onPose = { [poseStore] pose, t in poseStore.update(pose, at: t) }
        outputName = SystemAudioTap.defaultOutputDeviceName()
        watchDefaultOutput()

        // Hidden diagnostic: `open HeadTrack.app --args --diagnose` starts the
        // camera at launch so head pose can be logged without clicking.
        if CommandLine.arguments.contains("--diagnose") {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/HeadTrack")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("pose.csv")
            FileManager.default.createFile(atPath: url.path, contents: Data("time,yaw,visionPitch,roll,noseRatio,landmarkPitch\n".utf8))
            camera.diagnosticsFile = try? FileHandle(forWritingTo: url)
            camera.diagnosticsFile?.seekToEndOfFile()
            Task { await startCamera() }
        }
    }

    // MARK: Audio pipeline

    private func startAudio() {
        error = nil
        do {
            try tap.start()
            // Keep the queue short: ~20 ms at 48 kHz.
            ring.maxLatencyFrames = Int(tap.sampleRate * 0.02)
            let r = SpatialRenderer(source: ring, sampleRate: tap.sampleRate)
            r.setWidth(width)
            r.setRoom(Float(room))
            r.setMode(mode)
            try r.start()
            renderer = r
            observeEngineConfig(r.engine)
            outputName = SystemAudioTap.defaultOutputDeviceName()
            status = "On: \(mode.label)"
            startTimer()
            if mode == .tracked && !cameraOn {
                Task { await startCamera() }
            }
        } catch {
            stopAudio()
            self.error = "Couldn't start audio: \(error.localizedDescription). " +
                "Check System Settings > Privacy & Security > Screen & System Audio Recording."
            isOn = false
        }
    }

    private func stopAudio() {
        renderer?.stop()
        renderer = nil
        tap.stop() // original output unmutes immediately
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        configObserver = nil
        latencyMs = nil
        status = "Off"
        // Off means off: release the camera too (green light goes out).
        if cameraOn && !restarting { stopCamera() }
        stopTimer()
    }

    private var restarting = false

    private func restartAudio() {
        guard isOn else { return }
        restarting = true
        defer { restarting = false }
        stopAudio()
        startAudio()
    }

    /// Headphones plugged in / output switched: rebuild on the new device.
    private func watchDefaultOutput() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.outputName = SystemAudioTap.defaultOutputDeviceName()
                self?.restartAudio()
            }
        }
        outputListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    private func observeEngineConfig(_ engine: AVAudioEngine) {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restartAudio() }
        }
    }

    // MARK: Head tracking

    private func modeChanged() {
        renderer?.setMode(mode)
        if isOn { status = "On: \(mode.label)" }
        if mode == .tracked && !cameraOn {
            Task { await startCamera() }
        }
    }

    func startCamera() async {
        guard await CameraHeadTracker.requestAccess() else {
            error = "Camera access denied. Enable it in System Settings > Privacy & Security > Camera."
            return
        }
        do {
            poseStore.reset() // auto-centre on the first frame
            try camera.start()
            cameraOn = true
            startTimer()
        } catch {
            self.error = "Camera: \(error.localizedDescription)"
        }
    }

    func stopCamera() {
        camera.stop()
        cameraOn = false
        poseStore.reset() // sound eases back to centre and stays there
        if !isOn { stopTimer() }
    }

    func recentre() { poseStore.recentre() }

    // MARK: Update loop (60 Hz)

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common) // keep running while the menu is open
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private var lastReadout = 0.0

    private func tick() {
        let now = CACurrentMediaTime()
        let result = poseStore.pose(at: now, ahead: predictionMs / 1000)
        var applied = result.pose
        if !usePitch { applied.pitch = 0 }
        renderer?.setHead(applied)

        // Show the real head pose even when pitch isn't applied to the sound.
        head = result.pose
        tracking = cameraOn && result.tracking

        // Slow-changing readouts at ~4 Hz.
        if now - lastReadout > 0.25 {
            lastReadout = now
            cameraFps = cameraOn ? camera.fps : 0
            pitchAvailable = camera.pitchAvailable
            if let r = renderer {
                let ringMs = Double(ring.availableFrames) / tap.sampleRate * 1000
                latencyMs = r.outputLatency * 1000 + ringMs
            }
        }
    }

    var relativeSpeakers: (left: Double, right: Double) {
        let yaw = mode == .tracked ? head.yaw : 0
        return (width - yaw, -width - yaw)
    }

    /// Measured audio latency plus a rough camera pipeline allowance.
    func matchPredictionToLatency() {
        predictionMs = min(250, ((latencyMs ?? 20) + 40).rounded())
    }
}
