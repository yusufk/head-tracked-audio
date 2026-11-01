import AVFoundation
import CoreImage
import Synchronization
import Vision
import os

/// Webcam head tracking with Apple Vision. Frames are analysed in memory and
/// discarded.
///
/// Left/right: Vision's face-rectangle yaw (revision 3), every frame.
/// Up/down: from facial landmarks (nose position between eyes and mouth),
/// computed on a second worker in parallel. Vision's own pitch follows
/// left/right turns on a real face, so it isn't used.
///
/// Measured on a 2018 Intel MacBook Pro (live camera):
///   VNSequenceRequestHandler detect+landmarks: 122 ms/frame, 8 fps
///   VNImageRequestHandler detect only:         39 ms/frame, ~24 fps
///   landmarks only (given the face box):       26 ms/frame
/// Image resolution made no difference (Vision rescales internally).
final class CameraHeadTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// Called on the capture queue with a raw pose (degrees) and host time (s).
    var onPose: ((Pose, Double) -> Void)?
    var onFaceLost: (() -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "headtrack.camera", qos: .userInteractive)
    private let landmarkQueue = DispatchQueue(label: "headtrack.landmarks", qos: .userInteractive)
    private let log = Logger(subsystem: "com.yusufk.headtrack", category: "camera")
    private var configured = false
    private let active = Mutex(false)

    /// Latest up/down (degrees) from the landmark worker, and whether it's busy.
    private let latestPitch = Mutex<Double?>(nil)
    private let landmarkBusy = Mutex(false)
    private var lastLandmarkStart = 0.0 // camera queue only

    // Frames per second actually analysed.
    private let fpsLock = NSLock()
    private var frameCount = 0
    private var lastFpsTime = CACurrentMediaTime()
    private var _fps = 0
    var fps: Int { fpsLock.withLock { _fps } }

    var isRunning: Bool { session.isRunning }
    var pitchAvailable: Bool { latestPitch.withLock { $0 != nil } }

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
        latestPitch.withLock { $0 = nil }
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() throws {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video, position: .unspecified)
        // Prefer the built-in camera: it faces you and sits above the screen.
        guard let device = discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
            ?? discovery.devices.first else {
            throw NSError(domain: "HeadTrack", code: 1, userInfo: [NSLocalizedDescriptionKey: "No camera found"])
        }

        session.beginConfiguration()
        session.sessionPreset = .vga640x480
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "HeadTrack", code: 2, userInfo: [NSLocalizedDescriptionKey: "Camera input unavailable"])
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
            throw NSError(domain: "HeadTrack", code: 3, userInfo: [NSLocalizedDescriptionKey: "Camera output unavailable"])
        }
        session.addOutput(output)
        // Unmirrored image, so Vision's left/right sign is consistent.
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        session.commitConfiguration()
        configured = true
        log.info("Camera: \(device.localizedName)")
    }

    // MARK: Per frame

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard active.withLock({ $0 }),
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

        if benchmarkFile != nil {
            runBenchmarkFrame(pixels: pixels, time: time)
            return
        }

        // Left/right: face detection every frame. A fresh VNImageRequestHandler
        // per frame is ~3x cheaper here than VNSequenceRequestHandler.
        let detect = VNDetectFaceRectanglesRequest()
        detect.revision = VNDetectFaceRectanglesRequestRevision3
        do {
            try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([detect])
        } catch {
            log.error("Vision failed: \(error.localizedDescription)")
            return
        }
        countFrame()

        // Largest face = the person at the screen.
        guard let face = detect.results?.max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }), let yaw = face.yaw?.doubleValue else {
            onFaceLost?()
            return
        }

        // Up/down: hand the frame to the landmark worker if it's free.
        updatePitchInBackground(pixels: pixels, box: face.boundingBox)

        let pitch = latestPitch.withLock { $0 } ?? 0
        let pose = Pose(yaw: yaw * 180 / .pi, pitch: pitch, roll: 0)
        writeDiagnostic(pose: pose, visionPitch: face.pitch.map { -$0.doubleValue * 180 / .pi }, time: time)
        onPose?(pose, time)
    }

    private func updatePitchInBackground(pixels: CVPixelBuffer, box: CGRect) {
        // Up/down is less critical than left/right, and running landmarks on
        // every frame slowed detection through contention (frame age 70 ms
        // alone vs 113 ms with both). ~8 Hz keeps left/right fast.
        let now = CACurrentMediaTime()
        guard now - lastLandmarkStart > 0.12 else { return }
        let wasBusy = landmarkBusy.withLock { busy in
            defer { busy = true }
            return busy
        }
        guard !wasBusy else { return }
        lastLandmarkStart = now

        landmarkQueue.async { [weak self] in
            guard let self else { return }
            defer { self.landmarkBusy.withLock { $0 = false } }
            let landmarks = VNDetectFaceLandmarksRequest()
            landmarks.inputFaceObservations = [VNFaceObservation(boundingBox: box)]
            try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([landmarks])
            guard let face = landmarks.results?.first, let ratio = Self.noseRatio(face) else { return }
            self.latestPitch.withLock { $0 = Self.pitchFromNoseRatio(ratio) }
        }
    }

    // MARK: Landmark maths

    /// Where the nose tip sits between the eye line (0) and the mouth (1).
    /// Changes with up/down tilt.
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

    // MARK: Diagnostics (--diagnose): pose CSV at ~4 Hz

    var diagnosticsFile: FileHandle?
    private var lastDiagnostic = 0.0

    private func writeDiagnostic(pose: Pose, visionPitch: Double?, time: Double) {
        guard let file = diagnosticsFile else { return }
        let now = CACurrentMediaTime()
        guard now - lastDiagnostic > 0.25 else { return }
        lastDiagnostic = now
        let line = String(format: "%.2f,%.1f,%.1f,%.1f,%.1f\n", now, pose.yaw, pose.pitch,
                          visionPitch ?? .nan, (now - time) * 1000)
        file.write(Data(line.utf8))
    }

    // MARK: Benchmark (--benchmark): times Vision variants on live frames

    struct BenchConfig {
        let name: String
        let scale: CGFloat
        let requests: String // "detect", "landmarks", "detect+landmarks"
    }

    var benchmarkFile: FileHandle?
    private let benchConfigs = [
        BenchConfig(name: "detect + landmarks, full res", scale: 1, requests: "detect+landmarks"),
        BenchConfig(name: "detect only, full res", scale: 1, requests: "detect"),
        BenchConfig(name: "detect only, half res", scale: 0.5, requests: "detect"),
        BenchConfig(name: "landmarks only (given face box)", scale: 1, requests: "landmarks"),
    ]
    private let framesPerConfig = 90
    private var benchIndex = 0
    private var benchVision: [Double] = []
    private var benchAge: [Double] = []
    private var benchStart = 0.0
    private var benchFound = 0
    private var benchBox: CGRect?

    private func runBenchmarkFrame(pixels: CVPixelBuffer, time: Double) {
        guard benchIndex < benchConfigs.count else { return }
        let bench = benchConfigs[benchIndex]
        let detect = VNDetectFaceRectanglesRequest()
        detect.revision = VNDetectFaceRectanglesRequestRevision3
        let landmarks = VNDetectFaceLandmarksRequest()
        let started = CACurrentMediaTime()

        var image = CIImage(cvPixelBuffer: pixels)
        if bench.scale < 1 {
            image = image.transformed(by: CGAffineTransform(scaleX: bench.scale, y: bench.scale))
        }
        var requests: [VNRequest] = []
        if bench.requests.contains("detect") { requests.append(detect) }
        if bench.requests.contains("landmarks") {
            if bench.requests == "landmarks", let box = benchBox {
                landmarks.inputFaceObservations = [VNFaceObservation(boundingBox: box)]
            }
            requests.append(landmarks)
        }
        try? VNImageRequestHandler(ciImage: image, orientation: .up).perform(requests)
        if let box = detect.results?.first?.boundingBox { benchBox = box }
        let found = bench.requests == "landmarks" ? landmarks.results?.first != nil : detect.results?.first?.yaw != nil

        let done = CACurrentMediaTime()
        recordBenchmark(visionMs: (done - started) * 1000, frameAgeMs: (done - time) * 1000, faceFound: found)
    }

    private func recordBenchmark(visionMs: Double, frameAgeMs: Double, faceFound: Bool) {
        if benchVision.isEmpty { benchStart = CACurrentMediaTime(); benchFound = 0 }
        benchVision.append(visionMs)
        benchAge.append(frameAgeMs)
        if faceFound { benchFound += 1 }
        guard benchVision.count >= framesPerConfig else { return }

        let elapsed = CACurrentMediaTime() - benchStart
        let sortedV = benchVision.sorted(), sortedA = benchAge.sorted()
        let line = String(format: "%@\n  vision median %.1f ms, p90 %.1f ms | frame age median %.1f ms | %.1f fps | face found %d%%\n",
                          benchConfigs[benchIndex].name, sortedV[sortedV.count / 2], sortedV[sortedV.count * 9 / 10],
                          sortedA[sortedA.count / 2], Double(benchVision.count - 1) / elapsed,
                          benchFound * 100 / benchVision.count)
        benchmarkFile?.write(Data(line.utf8))
        benchVision.removeAll()
        benchAge.removeAll()
        benchIndex += 1
        if benchIndex == benchConfigs.count {
            benchmarkFile?.write(Data("\nDone.\n".utf8))
            benchmarkFile = nil
        }
    }
}
