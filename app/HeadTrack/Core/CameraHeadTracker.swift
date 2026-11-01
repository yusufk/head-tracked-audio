import AVFoundation
import Synchronization
import Vision
import os

/// Webcam head tracking via Apple Vision face rectangles (revision 3 gives
/// continuous yaw/pitch/roll). Frames are analysed in memory and discarded.
final class CameraHeadTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Called on the capture queue with a raw pose (degrees) and host time (s).
    var onPose: ((Pose, Double) -> Void)?
    var onFaceLost: (() -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "headtrack.camera", qos: .userInteractive)
    private let sequenceHandler = VNSequenceRequestHandler()
    private let log = Logger(subsystem: "com.yusufk.headtrack", category: "camera")
    private var configured = false

    // Frames per second actually analysed.
    private let fpsLock = NSLock()
    private var frameCount = 0
    private var lastFpsTime = CACurrentMediaTime()
    private var _fps = 0
    var fps: Int { fpsLock.withLock { _fps } }

    var isRunning: Bool { session.isRunning }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    func start() throws {
        if !configured { try configure() }
        active.withLock { $0 = true }
        queue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    /// Stops processing immediately and releases the camera (green light off).
    func stop() {
        active.withLock { $0 = false }
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private let active = Mutex(false)

    private func configure() throws {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified)
        // Prefer the built-in camera: it faces you and sits above the screen.
        guard let device = discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
            ?? discovery.devices.first else {
            throw NSError(domain: "HeadTrack", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No camera found"])
        }

        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "HeadTrack", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Camera input unavailable"])
        }
        session.addInput(input)

        // Highest frame rate the camera supports at this size: lower latency.
        if let range = device.activeFormat.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
            try? device.lockForConfiguration()
            device.activeVideoMinFrameDuration = range.minFrameDuration
            device.unlockForConfiguration()
        }

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true // never queue stale frames
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            throw NSError(domain: "HeadTrack", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Camera output unavailable"])
        }
        session.addOutput(output)
        // Guarantee an unmirrored image so "nose moves to image-right" means
        // the subject turned to THEIR left (used to check Vision's yaw sign).
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        session.commitConfiguration()
        configured = true
        log.info("Camera: \(device.localizedName)")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard active.withLock({ $0 }),
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

        if benchmarkFile != nil {
            runBenchmarkFrame(pixels: pixels, time: time)
            return
        }

        // Until calibrated (and while calibrating), run the original trusted
        // pipeline: full detection every frame, Vision's own left/right.
        // ~8 fps on an Intel MacBook, but it's the reference.
        let cal = calibration.withLock { $0 }
        if cal == nil || isCalibrating.withLock({ $0 }) {
            processReferenceFrame(pixels: pixels, time: time)
            return
        }

        // Calibrated fast path. Full detection is slow (~85 ms), so it runs on
        // its own queue a few times a second just to keep the face box fresh.
        // Every frame only refines landmarks inside that box (~35 ms).
        scheduleDetectionIfNeeded(pixels: pixels)
        guard let box = faceBox.withLock({ $0 }) else { return } // waiting for first detection

        let landmarks = VNDetectFaceLandmarksRequest()
        landmarks.inputFaceObservations = [VNFaceObservation(boundingBox: box)]
        do {
            try sequenceHandler.perform([landmarks], on: pixels, orientation: .up)
        } catch {
            log.error("Vision failed: \(error.localizedDescription)")
            return
        }
        countFrame()

        guard let face = landmarks.results?.first,
              (face.landmarks?.confidence ?? 0) > 0.3,
              let features = Self.features(of: face, vision: nil) else {
            faceBox.withLock { $0 = nil } // force a fresh detection
            onFaceLost?()
            return
        }

        // Follow the head between detections using the landmarks themselves.
        if let followed = Self.boundingBox(of: face, in: box) {
            faceBox.withLock { $0 = followed }
        }

        pitchLock.withLock { _pitchAvailable = true }
        let angles = cal!.pose(from: features)
        let pose = Pose(yaw: angles.yaw, pitch: angles.pitch, roll: 0)
        writeDiagnostic(features: features, pose: pose, time: time)
        onFeatures?(features)
        onPose?(pose, time)
    }

    /// Original pipeline: detection + landmarks every frame. Left/right from
    /// Vision (trusted), up/down from the nose ratio (Vision's pitch follows
    /// left/right turns on a real face).
    private func processReferenceFrame(pixels: CVPixelBuffer, time: Double) {
        let detect = VNDetectFaceRectanglesRequest()
        detect.revision = VNDetectFaceRectanglesRequestRevision3
        let landmarks = VNDetectFaceLandmarksRequest()
        do {
            try sequenceHandler.perform([detect, landmarks], on: pixels, orientation: .up)
        } catch {
            log.error("Vision failed: \(error.localizedDescription)")
            return
        }
        countFrame()

        guard let face = detect.results?.max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }), let yawRad = face.yaw?.doubleValue,
              let lm = landmarks.results?.first,
              let features = Self.features(of: lm, vision: face) else {
            onFaceLost?()
            return
        }
        faceBox.withLock { $0 = face.boundingBox } // ready for the fast path
        pitchLock.withLock { _pitchAvailable = true }

        let pose = Pose(yaw: yawRad * 180 / .pi, pitch: Self.pitchFromNoseRatio(features.noseRatio), roll: 0)
        writeDiagnostic(features: features, pose: pose, time: time)
        onFeatures?(features)
        onPose?(pose, time)
    }

    static func features(of landmarks: VNFaceObservation, vision: VNFaceObservation?) -> FaceFeatures? {
        guard let offset = noseOffsetX(landmarks), let ratio = noseRatio(landmarks) else { return nil }
        let d = 180 / Double.pi
        return FaceFeatures(noseOffset: offset, noseRatio: ratio,
                            visionYaw: vision?.yaw.map { $0.doubleValue * d },
                            visionPitch: vision?.pitch.map { -$0.doubleValue * d })
    }

    private func writeDiagnostic(features f: FaceFeatures, pose: Pose, time: Double) {
        guard let file = diagnosticsFile else { return }
        let now = CACurrentMediaTime()
        guard now - lastDiagnostic > 0.25 else { return }
        lastDiagnostic = now
        let line = String(format: "%.2f,%.1f,%.1f,%.1f,%.1f,%.3f,%.3f,%.1f\n", now,
                          f.visionYaw ?? .nan, pose.yaw, f.visionPitch ?? .nan, pose.pitch,
                          f.noseOffset, f.noseRatio, (now - time) * 1000)
        file.write(Data(line.utf8))
    }

    // MARK: Calibration hooks

    /// Per-frame features (camera queue), used by the calibration session.
    var onFeatures: ((FaceFeatures) -> Void)? {
        get { featureSink.withLock { $0 } }
        set { featureSink.withLock { $0 = newValue } }
    }
    private let featureSink = Mutex<((FaceFeatures) -> Void)?>(nil)
    let calibration = Mutex<Calibration?>(Calibration.load())
    let isCalibrating = Mutex(false)

    // MARK: Background face detection

    private let detectQueue = DispatchQueue(label: "headtrack.detect", qos: .userInitiated)
    private let faceBox = Mutex<CGRect?>(nil)
    private let detecting = Mutex(false)
    private var lastDetectTime = 0.0
    /// Vision's own yaw/pitch (degrees) from the latest detection, for diagnostics.
    private let visionAngles = Mutex((yaw: Double.nan, pitch: Double.nan))

    private func scheduleDetectionIfNeeded(pixels: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        let hasBox = faceBox.withLock { $0 != nil }
        guard !hasBox || now - lastDetectTime > 0.25 else { return }
        let busy = detecting.withLock { busy in
            if busy { return true }
            busy = true
            return false
        }
        guard !busy else { return }
        lastDetectTime = now

        detectQueue.async { [weak self] in
            guard let self else { return }
            defer { self.detecting.withLock { $0 = false } }
            let request = VNDetectFaceRectanglesRequest()
            request.revision = VNDetectFaceRectanglesRequestRevision3
            try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([request])
            // Largest face = the person at the screen.
            guard let face = request.results?.max(by: {
                $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
            }) else { return }
            self.faceBox.withLock { $0 = face.boundingBox }
            let d = 180 / Double.pi
            self.visionAngles.withLock {
                $0 = ((face.yaw?.doubleValue ?? .nan) * d, (face.pitch?.doubleValue ?? .nan) * d)
            }
        }
    }

    /// Face box (image-normalised) enclosing this frame's landmarks, padded
    /// to roughly the size Vision's detector reports.
    static func boundingBox(of face: VNFaceObservation, in box: CGRect) -> CGRect? {
        guard let pts = face.landmarks?.allPoints?.normalizedPoints, pts.count > 10 else { return nil }
        let xs = pts.map { box.minX + $0.x * box.width }, ys = pts.map { box.minY + $0.y * box.height }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return nil }
        let w = maxX - minX, h = maxY - minY
        guard w > 0.02, h > 0.02 else { return nil }
        // Landmarks span brows to chin; the detector's box is a bit larger.
        return CGRect(x: minX - w * 0.15, y: minY - h * 0.1, width: w * 1.3, height: h * 1.35)
    }

    /// Set to log raw pose samples as CSV (time,yaw,pitch,roll,noseRatio).
    var diagnosticsFile: FileHandle?

    private var lastDiagnostic = 0.0
    private var lastFaceRect: CGRect?

    // MARK: Benchmark (--benchmark): times Vision under different settings

    struct BenchConfig {
        let name: String
        let gpu: Bool?          // nil = Vision's default device choice
        let landmarksOnly: Bool // reuse last face box, skip detection
    }

    /// Set to run the benchmark and write results here.
    var benchmarkFile: FileHandle?
    private let benchConfigs = [
        BenchConfig(name: "default device, detect+landmarks", gpu: nil, landmarksOnly: false),
        BenchConfig(name: "CPU, detect+landmarks", gpu: false, landmarksOnly: false),
        BenchConfig(name: "GPU, detect+landmarks", gpu: true, landmarksOnly: false),
        BenchConfig(name: "default device, landmarks only (reuse box)", gpu: nil, landmarksOnly: true),
        BenchConfig(name: "GPU, landmarks only (reuse box)", gpu: true, landmarksOnly: true),
    ]
    private let framesPerConfig = 90
    private var benchIndex = 0
    private var benchVision: [Double] = []
    private var benchAge: [Double] = []
    private var benchStart = 0.0

    private func benchmarkConfig() -> BenchConfig? {
        guard benchmarkFile != nil, benchIndex < benchConfigs.count else { return nil }
        // Need a face box before the landmarks-only configs can run.
        if benchConfigs[benchIndex].landmarksOnly && lastFaceRect == nil { return nil }
        return benchConfigs[benchIndex]
    }

    private func runBenchmarkFrame(pixels: CVPixelBuffer, time: Double) {
        let detect = VNDetectFaceRectanglesRequest()
        detect.revision = VNDetectFaceRectanglesRequestRevision3
        let landmarks = VNDetectFaceLandmarksRequest()
        let bench = benchmarkConfig()
        Self.setDevice(detect, gpu: bench?.gpu)
        Self.setDevice(landmarks, gpu: bench?.gpu)
        let started = CACurrentMediaTime()
        if let bench, bench.landmarksOnly, let rect = lastFaceRect {
            landmarks.inputFaceObservations = [VNFaceObservation(boundingBox: rect)]
            try? sequenceHandler.perform([landmarks], on: pixels, orientation: .up)
        } else {
            try? sequenceHandler.perform([detect, landmarks], on: pixels, orientation: .up)
            if let box = detect.results?.first?.boundingBox { lastFaceRect = box }
        }
        if bench != nil {
            let done = CACurrentMediaTime()
            recordBenchmark(visionMs: (done - started) * 1000, frameAgeMs: (done - time) * 1000)
        }
    }

    private func recordBenchmark(visionMs: Double, frameAgeMs: Double) {
        if benchVision.isEmpty {
            benchStart = CACurrentMediaTime()
            if benchIndex == 0 {
                let probe = VNDetectFaceLandmarksRequest()
                let devices = (try? probe.supportedComputeStageDevices)?
                    .map { "\($0.key.rawValue): \($0.value.map { "\($0)" }.joined(separator: ", "))" }
                    .joined(separator: " | ") ?? "unknown"
                benchmarkFile?.write(Data("Compute devices: \(devices)\n\n".utf8))
            }
        }
        benchVision.append(visionMs)
        benchAge.append(frameAgeMs)
        guard benchVision.count >= framesPerConfig else { return }

        let elapsed = CACurrentMediaTime() - benchStart
        let sortedV = benchVision.sorted(), sortedA = benchAge.sorted()
        let line = String(format: "%@\n  vision median %.1f ms, p90 %.1f ms | frame age at result median %.1f ms | %.1f fps\n",
                          benchConfigs[benchIndex].name, sortedV[sortedV.count / 2], sortedV[sortedV.count * 9 / 10],
                          sortedA[sortedA.count / 2], Double(benchVision.count - 1) / elapsed)
        benchmarkFile?.write(Data(line.utf8))
        benchVision.removeAll()
        benchAge.removeAll()
        benchIndex += 1
        if benchIndex == benchConfigs.count {
            benchmarkFile?.write(Data("\nDone.\n".utf8))
            benchmarkFile = nil
        }
    }

    private static func setDevice(_ request: VNRequest, gpu: Bool?) {
        guard let gpu, let stages = try? request.supportedComputeStageDevices else { return }
        for (stage, devices) in stages {
            let pick = devices.first { device in
                switch device {
                case .gpu: return gpu
                case .cpu: return !gpu
                default: return false
                }
            }
            if let pick { request.setComputeDevice(pick, for: stage) }
        }
    }

    /// Where the nose tip sits between the eye line (0) and the mouth (1).
    /// Changes with up/down tilt, barely with left/right turns.
    static func noseRatio(_ face: VNFaceObservation) -> Double? {
        guard let lm = face.landmarks,
              let leftEye = lm.leftEye?.normalizedPoints, !leftEye.isEmpty,
              let rightEye = lm.rightEye?.normalizedPoints, !rightEye.isEmpty,
              let nose = lm.nose?.normalizedPoints, !nose.isEmpty,
              let lips = lm.outerLips?.normalizedPoints, !lips.isEmpty else { return nil }
        let mean = { (pts: [CGPoint]) in pts.map(\.y).reduce(0, +) / CGFloat(pts.count) }
        let eyeY = (mean(leftEye) + mean(rightEye)) / 2
        let mouthY = mean(lips)
        let noseTipY = nose.map(\.y).min()! // lowest nose point (y is up)
        let span = eyeY - mouthY
        guard span > 0.01 else { return nil }
        return Double((eyeY - noseTipY) / span)
    }

    /// Nose tip horizontal offset from the eye midpoint, in units of eye
    /// spacing. In an unmirrored image, > 0 means the subject turned to THEIR
    /// left. Independent check on Vision's yaw sign.
    static func noseOffsetX(_ face: VNFaceObservation) -> Double? {
        guard let lm = face.landmarks,
              let leftEye = lm.leftEye?.normalizedPoints, !leftEye.isEmpty,
              let rightEye = lm.rightEye?.normalizedPoints, !rightEye.isEmpty,
              let nose = lm.nose?.normalizedPoints, !nose.isEmpty else { return nil }
        let meanX = { (pts: [CGPoint]) in pts.map(\.x).reduce(0, +) / CGFloat(pts.count) }
        let l = meanX(leftEye), r = meanX(rightEye)
        let spacing = abs(r - l)
        guard spacing > 0.01 else { return nil }
        // Centre of the whole nose outline, not its lowest point: the lowest
        // point jumps between nostrils as the head tilts, which made yaw
        // follow pitch (corr -0.66 on a real face).
        let noseCentre = meanX(nose)
        return Double((noseCentre - (l + r) / 2) / spacing)
    }

    /// Nose ratio -> pitch in degrees (> 0 = looking up).
    /// Geometry: the nose tip sits ~2.5 cm in front of the eyes and the
    /// eye-to-mouth span is ~7 cm, so tilting by θ shifts the ratio by about
    /// 0.36·sin θ. Looking DOWN pushes the nose tip towards the mouth (ratio
    /// up), so the sign is negative. The absolute offset doesn't matter: the
    /// tracker auto-centres on the first frame.
    static func pitchFromNoseRatio(_ ratio: Double) -> Double {
        let neutral = 0.70, gain = 0.36
        let s = max(-1, min(1, (ratio - neutral) / gain))
        return -asin(s) * 180 / .pi
    }

    private let pitchLock = NSLock()
    private var _pitchAvailable = true
    var pitchAvailable: Bool { pitchLock.withLock { _pitchAvailable } }

    private func countFrame() {
        fpsLock.withLock {
            frameCount += 1
            let now = CACurrentMediaTime()
            if now - lastFpsTime >= 1 {
                _fps = frameCount
                frameCount = 0
                lastFpsTime = now
            }
        }
    }
}
