import Foundation

/// Cheap per-frame measurements from facial landmarks, plus Vision's own
/// (slow) angles when available as the reference during calibration.
struct FaceFeatures: Equatable {
    var noseOffset: Double   // nose centre vs eye midpoint, in eye spacings
    var noseRatio: Double    // nose between eye line (0) and mouth (1)
    var visionYaw: Double?   // degrees, > 0 = left (reference)
    var visionPitch: Double? // degrees, > 0 = up (reference, unreliable alone)
}

/// Linear map from landmark features to head angles, fitted per user:
///   yaw   = y0 + y1·noseOffset + y2·noseRatio
///   pitch = p0 + p1·noseOffset + p2·noseRatio
/// Using both features for both angles cancels the cross-talk seen on real
/// faces (nose position moves a little with both turns and tilts).
struct Calibration: Codable, Equatable {
    var yaw: [Double]   // [intercept, noseOffset, noseRatio]
    var pitch: [Double]
    var date = Date()

    func pose(from f: FaceFeatures) -> (yaw: Double, pitch: Double) {
        (yaw[0] + yaw[1] * f.noseOffset + yaw[2] * f.noseRatio,
         pitch[0] + pitch[1] * f.noseOffset + pitch[2] * f.noseRatio)
    }

    // MARK: Persistence

    private static let key = "calibration.v1"

    static func load() -> Calibration? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Calibration.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

/// The guided steps. Targets say which way the head points in each step.
enum CalibrationStep: String, CaseIterable {
    case centre, left, right, up, down

    var instruction: String {
        switch self {
        case .centre: "Look at the centre of the screen"
        case .left: "Turn your head to the left, about as far as the edge of the screen"
        case .right: "Now turn your head to the right"
        case .up: "Look up, towards the top of the screen"
        case .down: "Now look down, towards the bottom of the screen"
        }
    }

    var spoken: String {
        switch self {
        case .centre: "Look at the centre of the screen, and hold still."
        case .left: "Turn your head to the left, and hold."
        case .right: "Now turn your head to the right, and hold."
        case .up: "Look up, and hold."
        case .down: "Now look down, and hold."
        }
    }

    var symbol: String {
        switch self {
        case .centre: "circle.circle"
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .up: "arrow.up"
        case .down: "arrow.down"
        }
    }
}

enum CalibrationError: LocalizedError {
    case notEnoughData(CalibrationStep)
    case noMovement(String)

    var errorDescription: String? {
        switch self {
        case let .notEnoughData(step): "Couldn't see your face during \"\(step.rawValue)\". Check the lighting and try again."
        case let .noMovement(what): "Barely any \(what) movement was detected. Try turning a little further."
        }
    }
}

struct CalibrationResult {
    let calibration: Calibration
    /// Reference angles reached (degrees) for the report.
    let yawRange: Double
    let pitchRange: Double
    /// Fit quality: RMS error (degrees) of the fitted model on the samples.
    let yawRMS: Double
    let pitchRMS: Double
}

enum CalibrationFitter {
    /// Fit from samples grouped by step. Reference angles come from Vision's
    /// yaw (trusted) for left/right. For up/down, Vision's pitch is used only
    /// in the pure up/down steps (where it can't be confused by turning);
    /// if it's missing, a nominal 20 degrees is assumed.
    static func fit(_ samples: [CalibrationStep: [FaceFeatures]]) throws -> CalibrationResult {
        for step in CalibrationStep.allCases where (samples[step]?.count ?? 0) < 5 {
            throw CalibrationError.notEnoughData(step)
        }
        func mean(_ xs: [Double]) -> Double { xs.reduce(0, +) / Double(max(1, xs.count)) }
        func refYaw(_ s: CalibrationStep) -> Double? {
            let v = samples[s]!.compactMap(\.visionYaw)
            return v.isEmpty ? nil : mean(v)
        }
        func refPitch(_ s: CalibrationStep) -> Double? {
            let v = samples[s]!.compactMap(\.visionPitch)
            return v.isEmpty ? nil : mean(v)
        }

        // Targets relative to the centre step (the tracker auto-centres anyway).
        let yawCentre = refYaw(.centre) ?? 0
        let yawLeft = (refYaw(.left) ?? 30) - yawCentre
        let yawRight = (refYaw(.right) ?? -30) - yawCentre
        guard yawLeft - yawRight > 10 else { throw CalibrationError.noMovement("left/right") }

        let pitchCentre = refPitch(.centre) ?? 0
        var pitchUp = (refPitch(.up) ?? 20) - pitchCentre
        var pitchDown = (refPitch(.down) ?? -20) - pitchCentre
        // If Vision's pitch didn't separate up from down, fall back to nominal.
        if pitchUp - pitchDown < 8 { pitchUp = 20; pitchDown = -20 }

        let target: [CalibrationStep: (yaw: Double, pitch: Double)] = [
            .centre: (0, 0), .left: (yawLeft, 0), .right: (yawRight, 0),
            .up: (0, pitchUp), .down: (0, pitchDown),
        ]

        var rows: [[Double]] = [], yawT: [Double] = [], pitchT: [Double] = []
        for (step, feats) in samples {
            guard let t = target[step] else { continue }
            for f in feats {
                rows.append([1, f.noseOffset, f.noseRatio])
                yawT.append(t.yaw)
                pitchT.append(t.pitch)
            }
        }
        guard let yawCoef = leastSquares(rows, yawT), let pitchCoef = leastSquares(rows, pitchT) else {
            throw CalibrationError.noMovement("head")
        }
        let cal = Calibration(yaw: yawCoef, pitch: pitchCoef)

        func rms(_ coef: [Double], _ t: [Double]) -> Double {
            var s = 0.0
            for (r, y) in zip(rows, t) {
                let e = coef[0] * r[0] + coef[1] * r[1] + coef[2] * r[2] - y
                s += e * e
            }
            return sqrt(s / Double(rows.count))
        }
        return CalibrationResult(calibration: cal,
                                 yawRange: yawLeft - yawRight, pitchRange: pitchUp - pitchDown,
                                 yawRMS: rms(yawCoef, yawT), pitchRMS: rms(pitchCoef, pitchT))
    }

    /// Ordinary least squares for 3 coefficients via the normal equations.
    static func leastSquares(_ x: [[Double]], _ y: [Double]) -> [Double]? {
        var a = [[Double]](repeating: [0, 0, 0], count: 3), b = [0.0, 0, 0]
        for (row, t) in zip(x, y) {
            for i in 0..<3 {
                b[i] += row[i] * t
                for j in 0..<3 { a[i][j] += row[i] * row[j] }
            }
        }
        return solve3(a, b)
    }

    /// Gaussian elimination with partial pivoting.
    private static func solve3(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        var m = a.enumerated().map { $0.element + [b[$0.offset]] }
        for col in 0..<3 {
            let pivot = (col..<3).max { abs(m[$0][col]) < abs(m[$1][col]) }!
            guard abs(m[pivot][col]) > 1e-12 else { return nil }
            m.swapAt(col, pivot)
            for r in 0..<3 where r != col {
                let f = m[r][col] / m[col][col]
                for c in col..<4 { m[r][c] -= f * m[col][c] }
            }
        }
        return (0..<3).map { m[$0][3] / m[$0][$0] }
    }
}
