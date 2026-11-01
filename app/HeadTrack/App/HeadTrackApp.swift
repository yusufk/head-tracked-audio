import SwiftUI

@main
struct HeadTrackApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            ControlPanel(model: model)
        } label: {
            Image(nsImage: MenuBarIcon.image(on: model.isOn))
        }
        .menuBarExtraStyle(.window)
    }
}

struct ControlPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("HeadTrack").font(.headline)
                Spacer()
                Toggle("Spatial audio", isOn: $model.isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel("Spatial audio on or off")
            }

            Text(model.isOn
                 ? "Sound comes from the screen and stays put when you turn your head. Output: \(model.outputName)"
                 : "Off: your Mac's audio plays normally")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            CompareButton(model: model)

            HStack(spacing: 10) {
                VStack(spacing: 2) {
                    Radar(model: model)
                        .frame(width: 150, height: 110)
                        .accessibilityLabel("Top-down view: left and right head turns")
                    Text("Left / right").font(.caption2).foregroundStyle(.secondary)
                }
                VStack(spacing: 2) {
                    SideRadar(model: model)
                        .frame(width: 150, height: 110)
                        .accessibilityLabel("Side view: up and down head tilt")
                    Text("Up / down").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Readout(model: model)

            LabeledSlider(title: "Speaker width", value: $model.width, range: 10...90, step: 1) {
                "±\(Int($0))°"
            }
            LabeledSlider(title: "Room", value: $model.room, range: 0...1, step: 0.01) {
                "\(Int($0 * 100))%"
            }
            HStack {
                LabeledSlider(title: "Prediction", value: $model.predictionMs, range: 0...250, step: 5) {
                    "\(Int($0)) ms"
                }
                Button("Auto") { model.matchPredictionToLatency() }
                    .help("Match the measured latency (useful on Bluetooth)")
            }

            HStack {
                Toggle("Use pitch", isOn: $model.usePitch)
                Spacer()
                Button("Recentre") { model.recentre() }
                    .keyboardShortcut("c", modifiers: [])
                    .disabled(!model.cameraOn)
            }
            .font(.callout)
            HStack {
                Toggle("Flip left/right", isOn: $model.invertYaw)
                Toggle("Flip up/down", isOn: $model.invertPitch)
            }
            .font(.callout)

            if let error = model.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Button(model.cameraOn ? "Stop camera" : "Start camera") {
                    if model.cameraOn { model.stopCamera() } else { Task { await model.startCamera() } }
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}

private struct Readout: View {
    @ObservedObject var model: AppModel

    private func side(_ deg: Double) -> String {
        "\(Int(abs(deg).rounded()))°\(deg >= 0 ? "L" : "R")"
    }

    private var pitchText: String {
        guard model.pitchAvailable else { return "pitch n/a" }
        let p = model.head.pitch
        return "\(Int(abs(p).rounded()))°\(p >= 0 ? "up" : "down")"
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
            row("Head", model.cameraOn
                ? "\(side(model.head.yaw)) \(pitchText)\(model.tracking ? "" : " (lost)")"
                : "camera off")
            let s = model.relativeSpeakers
            row("Speakers", "\(side(s.left)) · \(side(s.right))")
            row("Latency", model.latencyMs.map { "\(Int($0)) ms" } ?? "-")
            row("Tracking", model.cameraOn ? "\(model.cameraFps) fps" : "-",
                warn: model.cameraOn && model.cameraFps < 10)
        }
        .font(.system(.caption, design: .monospaced))
    }

    private func row(_ k: String, _ v: String, warn: Bool = false) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).foregroundStyle(warn ? .orange : .green)
        }
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue(format(value))
            Text(format(value))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 52, alignment: .trailing)
        }
        .font(.callout)
    }
}

/// Top-down: screen at the top, speakers fixed, head arrow turns with you.
private struct Radar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2, cy = size.height * 0.62, r = size.height * 0.48
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8),
                     with: .color(.black.opacity(0.25)))

            var screen = Path()
            screen.move(to: CGPoint(x: cx - 26, y: 8))
            screen.addLine(to: CGPoint(x: cx + 26, y: 8))
            ctx.stroke(screen, with: .color(.cyan.opacity(0.6)), lineWidth: 3)

            let w = model.width * .pi / 180
            let on = model.isOn && !model.comparing
            for (az, label) in [(w, "L"), (-w, "R")] {
                let p = CGPoint(x: cx - sin(az) * r, y: cy - cos(az) * r)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                         with: .color(on ? .green : .gray))
                ctx.draw(Text(label).font(.caption2), at: CGPoint(x: p.x, y: p.y + 13))
            }

            // yaw > 0 = turned left = anticlockwise on screen.
            var head = ctx
            head.translateBy(x: cx, y: cy)
            head.rotate(by: .degrees(-model.head.yaw))
            let color: Color = model.tracking ? .cyan : .orange
            head.fill(Path(ellipseIn: CGRect(x: -9, y: -9, width: 18, height: 18)), with: .color(color))
            var arrow = Path()
            arrow.move(to: CGPoint(x: 0, y: -9))
            arrow.addLine(to: CGPoint(x: 0, y: -30))
            arrow.move(to: CGPoint(x: -5, y: -24))
            arrow.addLine(to: CGPoint(x: 0, y: -32))
            arrow.addLine(to: CGPoint(x: 5, y: -24))
            head.stroke(arrow, with: .color(color), lineWidth: 2)
        }
    }
}

/// Side view for up/down only: your head in profile (facing the screen on the
/// left) tilts with your pitch, and an UP/DOWN gauge on the right shows the
/// angle. Nothing here moves when you turn left or right.
private struct SideRadar: View {
    @ObservedObject var model: AppModel

    /// Gauge range: ±40° fills the bar.
    private let range = 40.0

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let cx = w * 0.55, cy = h / 2
            let pitch = model.head.pitch
            let color: Color = !model.tracking ? .orange : (model.usePitch ? .cyan : .gray)

            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8),
                     with: .color(.black.opacity(0.25)))

            // Screen, seen edge-on
            var screen = Path()
            screen.move(to: CGPoint(x: 8, y: cy - 26))
            screen.addLine(to: CGPoint(x: 8, y: cy + 26))
            ctx.stroke(screen, with: .color(.cyan.opacity(0.6)), lineWidth: 3)

            // Speakers at ear level (L and R overlap from the side)
            ctx.fill(Path(ellipseIn: CGRect(x: 18, y: cy - 4, width: 8, height: 8)),
                     with: .color(model.isOn && !model.comparing ? .green : .gray))

            // Level reference line
            var level = Path()
            level.move(to: CGPoint(x: 28, y: cy))
            level.addLine(to: CGPoint(x: cx - 12, y: cy))
            ctx.stroke(level, with: .color(.white.opacity(0.15)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            // Head in profile: rotate so looking up lifts the nose.
            var head = ctx
            head.translateBy(x: cx, y: cy)
            head.rotate(by: .degrees(pitch)) // + = clockwise on screen = nose up (facing left)
            var gaze = Path()
            gaze.move(to: CGPoint(x: -12, y: 0))
            gaze.addLine(to: CGPoint(x: -cx + 30, y: 0))
            head.stroke(gaze, with: .color(color.opacity(0.7)),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            head.fill(Path(ellipseIn: CGRect(x: -11, y: -12, width: 22, height: 24)), with: .color(color))
            var nose = Path()
            nose.move(to: CGPoint(x: -10, y: -4))
            nose.addLine(to: CGPoint(x: -17, y: 2))
            nose.addLine(to: CGPoint(x: -10, y: 4))
            nose.closeSubpath()
            head.fill(nose, with: .color(color))
            // Ear (marks the side of the head)
            head.fill(Path(ellipseIn: CGRect(x: 1, y: -3, width: 5, height: 7)),
                      with: .color(.black.opacity(0.35)))

            // UP / DOWN gauge
            let gx = w - 16, top = 16.0, bottom = h - 16
            var bar = Path()
            bar.move(to: CGPoint(x: gx, y: top))
            bar.addLine(to: CGPoint(x: gx, y: bottom))
            ctx.stroke(bar, with: .color(.white.opacity(0.3)), style: StrokeStyle(lineWidth: 3, lineCap: .round))
            var mid = Path()
            mid.move(to: CGPoint(x: gx - 5, y: cy))
            mid.addLine(to: CGPoint(x: gx + 5, y: cy))
            ctx.stroke(mid, with: .color(.white.opacity(0.4)), lineWidth: 1)
            let t = max(-1, min(1, pitch / range))
            let my = cy - t * (cy - top)
            ctx.fill(Path(ellipseIn: CGRect(x: gx - 5, y: my - 5, width: 10, height: 10)), with: .color(color))
            ctx.draw(Text("UP").font(.system(size: 8, weight: .semibold)), at: CGPoint(x: gx, y: 7))
            ctx.draw(Text("DOWN").font(.system(size: 8, weight: .semibold)), at: CGPoint(x: gx, y: h - 7))
        }
    }
}

/// Press and hold to hear ordinary headphone sound; release to go back.
/// VoiceOver users get a toggle action instead of press-and-hold.
private struct CompareButton: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text(model.comparing ? "Playing normal sound…" : "Hold to compare with normal sound")
            .font(.callout)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(model.comparing ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.15)))
            .opacity(model.isOn ? 1 : 0.4)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if model.isOn && !model.comparing { model.comparing = true } }
                .onEnded { _ in model.comparing = false })
            .accessibilityElement()
            .accessibilityLabel("Compare with normal sound")
            .accessibilityValue(model.comparing ? "Playing normal sound" : "Playing spatial sound")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if model.isOn { model.comparing.toggle() } }
            .disabled(!model.isOn)
    }
}
