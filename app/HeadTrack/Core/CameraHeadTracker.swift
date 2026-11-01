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
        session.commitConfiguration()
        configured = true
        log.info("Camera: \(device.localizedName)")
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard active.withLock({ $0 }),
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        let landmarks = VNDetectFaceLandmarksRequest()
        do {
            try sequenceHandler.perform([request, landmarks], on: pixels, orientation: .up)
        } catch {
            log.error("Vision failed: \(error.localizedDescription)")
            return
        }

        countFrame()

        // Largest face = the person at the screen.
        guard let face = request.results?.max(by: {
            $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height
        }), let yaw = face.yaw?.doubleValue else {
            onFaceLost?()
            return
        }

        // Vision angles are radians. Signs are converted to our convention
        // (yaw > 0 = turned left, pitch > 0 = looking up) in poseFromVision.
        // Vision's own pitch turned out to follow left/right turns on a real
        // face (corr -0.55 with yaw over 211 samples), so up/down comes from
        // facial landmarks instead (corr -0.10 with yaw).
        let ratio = (landmarks.results?.first).flatMap(Self.noseRatio)
        pitchLock.withLock { _pitchAvailable = ratio != nil }
        let landmarkPitch = ratio.map(Self.pitchFromNoseRatio) ?? 0
        let pitch = face.pitch?.doubleValue
        let pose = Self.poseFromVision(yaw: yaw, pitch: 0, roll: face.roll?.doubleValue ?? 0)
            .with(pitch: landmarkPitch)

        // DIAGNOSTIC (temporary, --diagnose only): raw Vision angles vs a
        // landmark-based up/down estimate, ~4 Hz, to compare on a real face.
        if let file = diagnosticsFile {
            let now = CACurrentMediaTime()
            if now - lastDiagnostic > 0.25 {
                lastDiagnostic = now
                let d = 180 / Double.pi
                let line = String(format: "%.2f,%.1f,%.1f,%.1f,%.3f,%.1f\n", now, yaw * d,
                                  (pitch ?? .nan) * d, (face.roll?.doubleValue ?? .nan) * d,
                                  ratio ?? .nan, landmarkPitch)
                file.write(Data(line.utf8))
            }
        }
        onPose?(pose, time)
    }

    /// Set to log raw pose samples as CSV (time,yaw,pitch,roll,noseRatio).
    var diagnosticsFile: FileHandle?

    private var lastDiagnostic = 0.0

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

    /// Vision reports angles as seen in the (unmirrored) camera image.
    /// The camera faces you, so a positive image yaw is the subject turning to
    /// their LEFT. Flip in the UI if your camera reports otherwise.
    static func poseFromVision(yaw: Double, pitch: Double, roll: Double) -> Pose {
        let deg = 180 / Double.pi
        return Pose(yaw: yaw * deg, pitch: -pitch * deg, roll: roll * deg)
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
}
