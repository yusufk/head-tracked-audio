import AVFoundation

/// Anything that can supply interleaved-free stereo frames on demand.
protocol StereoFrameSource: AnyObject {
    @discardableResult
    func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Int
}

extension StereoRingBuffer: StereoFrameSource {}

enum SpatialMode: String, CaseIterable, Identifiable {
    case stereo   // plain stereo, glued to the head (A/B reference)
    case speakers // virtual speakers, not tracked
    case tracked  // virtual speakers fixed to the screen

    var id: String { rawValue }

    /// Modes offered in the UI. `.speakers` (virtual speakers without head
    /// tracking) is kept for tests and A/B work but hidden: to a user it
    /// sounds like a confusing half-way house.
    static let userModes: [SpatialMode] = [.stereo, .tracked]

    var label: String {
        switch self {
        case .stereo: "Normal"
        case .speakers: "Speakers"
        case .tracked: "Tracked"
        }
    }

    /// One-line explanation shown under the mode picker.
    var explanation: String {
        switch self {
        case .stereo:
            "Ordinary headphone sound: it sits inside your head and turns with you. Switch to compare."
        case .speakers:
            "Virtual speakers in front of you, not following your head."
        case .tracked:
            "Sound comes from the screen, like real speakers. Turn your head and it stays put."
        }
    }
}

/// Splits one stereo pull into the three render callbacks (L mono, R mono,
/// plain stereo) that the engine invokes for the same render cycle.
/// All callbacks run on the single render thread, so no locking is needed.
private final class Deinterleaver: @unchecked Sendable {
    let source: StereoFrameSource
    let capacity = 8192
    let left: UnsafeMutablePointer<Float>
    let right: UnsafeMutablePointer<Float>
    private var lastSampleTime: Float64 = -1
    private var lastFrames = 0

    init(source: StereoFrameSource) {
        self.source = source
        left = .allocate(capacity: capacity)
        right = .allocate(capacity: capacity)
        left.initialize(repeating: 0, count: capacity)
        right.initialize(repeating: 0, count: capacity)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    /// Ensure this cycle's frames are pulled exactly once.
    func pull(frames: Int, sampleTime: Float64) {
        let n = min(frames, capacity)
        if sampleTime != lastSampleTime || n > lastFrames {
            source.read(left: left, right: right, frames: n)
            lastSampleTime = sampleTime
            lastFrames = n
        }
    }
}

/// Binaural renderer: stereo L/R become two HRTF point sources either side of
/// the screen. The listener is rotated with the head so sources stay put.
final class SpatialRenderer {
    let engine = AVAudioEngine()
    let environment = AVAudioEnvironmentNode()
    let sampleRate: Double

    private let deinterleaver: Deinterleaver
    private var leftNode: AVAudioSourceNode!
    private var rightNode: AVAudioSourceNode!
    private var stereoNode: AVAudioSourceNode!

    private(set) var mode: SpatialMode = .speakers
    private(set) var widthDegrees: Double = 30
    private(set) var head = Pose()
    var distance: Float = 1.5

    init(source: StereoFrameSource, sampleRate: Double) {
        self.sampleRate = sampleRate
        deinterleaver = Deinterleaver(source: source)
        build()
    }

    private func build() {
        let mono = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let d = deinterleaver

        func channelNode(_ channel: Int) -> AVAudioSourceNode {
            AVAudioSourceNode(format: mono) { _, timestamp, frameCount, abl in
                let frames = Int(frameCount)
                d.pull(frames: frames, sampleTime: timestamp.pointee.mSampleTime)
                let src = channel == 0 ? d.left : d.right
                let out = UnsafeMutableAudioBufferListPointer(abl)
                if let dst = out[0].mData?.assumingMemoryBound(to: Float.self) {
                    dst.update(from: src, count: min(frames, d.capacity))
                }
                return noErr
            }
        }

        leftNode = channelNode(0)
        rightNode = channelNode(1)
        stereoNode = AVAudioSourceNode(format: stereo) { _, timestamp, frameCount, abl in
            let frames = Int(frameCount)
            d.pull(frames: frames, sampleTime: timestamp.pointee.mSampleTime)
            let out = UnsafeMutableAudioBufferListPointer(abl)
            for (i, buf) in out.enumerated() {
                guard let dst = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                dst.update(from: i == 0 ? d.left : d.right, count: min(frames, d.capacity))
            }
            return noErr
        }

        [leftNode, rightNode, stereoNode, environment].forEach { engine.attach($0!) }

        for node in [leftNode!, rightNode!] {
            engine.connect(node, to: environment, format: mono)
            node.renderingAlgorithm = .HRTFHQ
            node.sourceMode = .pointSource
            node.reverbBlend = 0.15
        }

        // Direction only: sources sit at the reference distance, no rolloff.
        environment.distanceAttenuationParameters.referenceDistance = distance
        environment.distanceAttenuationParameters.maximumDistance = 100
        environment.distanceAttenuationParameters.rolloffFactor = 0
        environment.reverbParameters.enable = true
        environment.reverbParameters.loadFactoryReverbPreset(.mediumRoom)
        environment.reverbParameters.level = -6
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)

        engine.connect(environment, to: engine.mainMixerNode, format: stereo)
        engine.connect(stereoNode, to: engine.mainMixerNode, format: stereo)

        applyMode()
        updatePositions()
    }

    /// Render offline instead of to hardware (tests).
    func enableOfflineRendering(maxFrames: AVAudioFrameCount = 4096) throws {
        let stereo = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        try engine.enableManualRenderingMode(.offline, format: stereo, maximumFrameCount: maxFrames)
    }

    func start() throws {
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.stop()
    }

    // MARK: Controls

    func setMode(_ mode: SpatialMode) {
        self.mode = mode
        applyMode()
        applyHead()
    }

    func setWidth(_ degrees: Double) {
        widthDegrees = degrees
        updatePositions()
    }

    func setRoom(_ amount: Float) {
        leftNode.reverbBlend = amount
        rightNode.reverbBlend = amount
    }

    /// Head pose in degrees (yaw > 0 = turned left, pitch > 0 = looking up).
    func setHead(_ pose: Pose) {
        head = pose
        applyHead()
    }

    private func applyMode() {
        let spatial = mode != .stereo
        environment.outputVolume = spatial ? 1 : 0
        stereoNode.volume = spatial ? 0 : 1
    }

    private func applyHead() {
        let tracked = mode == .tracked
        let o = Self.listenerOrientation(yaw: tracked ? head.yaw : 0, pitch: tracked ? head.pitch : 0)
        environment.listenerVectorOrientation = AVAudio3DVectorOrientation(forward: o.forward, up: o.up)
    }

    /// Listener forward/up vectors for a head pose (degrees, yaw > 0 = left,
    /// pitch > 0 = up). Vectors avoid any ambiguity in AVAudio's Euler angle
    /// signs (its yaw turned out to be the opposite of our convention).
    /// Listener at rest faces -Z with +Y up and +X to the right.
    static func listenerOrientation(yaw: Double, pitch: Double) -> (forward: AVAudio3DVector, up: AVAudio3DVector) {
        let a = Float(yaw * .pi / 180), p = Float(pitch * .pi / 180)
        // Pitch about the listener's right axis, then yaw anticlockwise about +Y.
        let forward = AVAudio3DVector(x: -sin(a) * cos(p), y: sin(p), z: -cos(a) * cos(p))
        let up = AVAudio3DVector(x: sin(a) * sin(p), y: cos(p), z: cos(a) * sin(p))
        return (forward, up)
    }

    private func updatePositions() {
        let w = Float(widthDegrees * .pi / 180)
        // Listener faces -Z, +X is to the right.
        leftNode.position = AVAudio3DPoint(x: -sin(w) * distance, y: 0, z: -cos(w) * distance)
        rightNode.position = AVAudio3DPoint(x: sin(w) * distance, y: 0, z: -cos(w) * distance)
    }

    /// Speaker angles relative to the head (degrees, > 0 = left), for display.
    var relativeSpeakerAngles: (left: Double, right: Double) {
        let yaw = mode == .tracked ? head.yaw : 0
        return (widthDegrees - yaw, -widthDegrees - yaw)
    }

    /// Output latency reported by the engine, in seconds.
    var outputLatency: Double {
        engine.outputNode.presentationLatency
    }
}
