import Foundation

/// Head orientation in degrees, from the listener's point of view.
///   yaw   > 0: head turned to the LEFT
///   pitch > 0: looking UP
///   roll  > 0: tilted towards the LEFT shoulder
struct Pose: Equatable {
    var yaw: Double = 0
    var pitch: Double = 0
    var roll: Double = 0
}

/// One Euro filter (Casiez et al. 2012): smooths jitter when still, adds very
/// little lag when moving fast. Also exposes a velocity estimate for prediction.
struct OneEuroFilter {
    var minCutoff: Double
    var beta: Double
    var dCutoff: Double

    private(set) var value: Double?
    private(set) var velocity: Double = 0
    private var prevRaw: Double = 0
    private var lastTime: Double = 0

    init(minCutoff: Double = 1.0, beta: Double = 0.02, dCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    mutating func reset() {
        value = nil
        velocity = 0
    }

    /// - Parameters: raw sample, timestamp in seconds.
    mutating func filter(_ raw: Double, at t: Double) -> Double {
        guard let x = value else {
            value = raw
            prevRaw = raw
            lastTime = t
            return raw
        }
        let dt = max(1e-3, t - lastTime)
        lastTime = t

        // Velocity from consecutive RAW samples. Differencing against the
        // smoothed value would add its lag and overestimate speed.
        let rawVelocity = (raw - prevRaw) / dt
        prevRaw = raw
        velocity += Self.alpha(cutoff: dCutoff, dt: dt) * (rawVelocity - velocity)

        let cutoff = minCutoff + beta * abs(velocity)
        let next = x + Self.alpha(cutoff: cutoff, dt: dt) * (raw - x)
        value = next
        return next
    }
}

/// Filtered head pose with auto-centre, recentre, lost-face easing and
/// short-term prediction. Not thread-safe; wrap in `HeadPoseStore`.
struct HeadPoseTracker {
    var invertYaw = false
    var invertPitch = false
    var holdSeconds = 0.4
    var easeSeconds = 1.2

    private var yawFilter = OneEuroFilter(minCutoff: 1.2, beta: 0.03)
    private var pitchFilter = OneEuroFilter(minCutoff: 1.2, beta: 0.03)
    private var rollFilter = OneEuroFilter(minCutoff: 1.0, beta: 0.02)
    private(set) var current = Pose()
    private(set) var offset = Pose()
    private(set) var lastSampleTime: Double = 0
    private(set) var hasSample = false
    private var needsAutoCentre = true

    mutating func update(_ raw: Pose, at t: Double) {
        current = Pose(
            yaw: yawFilter.filter(raw.yaw, at: t),
            pitch: pitchFilter.filter(raw.pitch, at: t),
            roll: rollFilter.filter(raw.roll, at: t)
        )
        // First sample defines "forward": webcams are rarely dead centre.
        if needsAutoCentre {
            offset = current
            needsAutoCentre = false
        }
        lastSampleTime = t
        hasSample = true
    }

    mutating func recentre() {
        offset = current
    }

    mutating func reset() {
        yawFilter.reset()
        pitchFilter.reset()
        rollFilter.reset()
        needsAutoCentre = true
        hasSample = false
    }

    /// Pose relative to forward at time `now`, predicted `ahead` seconds.
    /// Returns `tracking == false` while the face is lost (easing to centre).
    func pose(at now: Double, ahead: Double = 0) -> (pose: Pose, tracking: Bool) {
        let sign = invertYaw ? -1.0 : 1.0
        let pSign = invertPitch ? -1.0 : 1.0
        var yaw = current.yaw - offset.yaw
        var pitch = current.pitch - offset.pitch
        let roll = current.roll - offset.roll
        let since = now - lastSampleTime

        guard hasSample, since <= holdSeconds else {
            let k = hasSample ? max(0, 1 - (since - holdSeconds) / easeSeconds) : 0
            return (Pose(yaw: sign * yaw * k, pitch: pSign * pitch * k, roll: roll * k), false)
        }

        // Extrapolate with the filters' velocity. Capped so noise can't fling
        // the sound around. ahead == 0 means no prediction (for A/B tests).
        if ahead > 0 {
            let horizon = min(since + ahead, 0.25)
            yaw += yawFilter.velocity * horizon
            pitch += pitchFilter.velocity * horizon
        }
        return (Pose(yaw: sign * yaw, pitch: pSign * pitch, roll: roll), true)
    }
}

/// Thread-safe wrapper: the camera writes on its queue, the UI/audio reads.
final class HeadPoseStore: @unchecked Sendable {
    private var tracker = HeadPoseTracker()
    private let lock = NSLock()

    func update(_ raw: Pose, at t: Double) {
        lock.withLock { tracker.update(raw, at: t) }
    }

    func recentre() { lock.withLock { tracker.recentre() } }
    func reset() { lock.withLock { tracker.reset() } }

    var invertYaw: Bool {
        get { lock.withLock { tracker.invertYaw } }
        set { lock.withLock { tracker.invertYaw = newValue } }
    }

    var invertPitch: Bool {
        get { lock.withLock { tracker.invertPitch } }
        set { lock.withLock { tracker.invertPitch = newValue } }
    }

    func pose(at now: Double, ahead: Double = 0) -> (pose: Pose, tracking: Bool) {
        lock.withLock { tracker.pose(at: now, ahead: ahead) }
    }
}
