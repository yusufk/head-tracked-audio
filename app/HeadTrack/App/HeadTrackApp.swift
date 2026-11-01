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

            Text(model.isOn ? "Output: \(model.outputName)" : "Off: your Mac's audio plays normally")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Mode", selection: $model.mode) {
                ForEach(SpatialMode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

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
            let on = model.mode != .stereo
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

/// Side view: you are seen from your right. Screen on the left, speakers at
/// ear level in front of you, head arrow tilts with your pitch.
private struct SideRadar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width * 0.62, cy = size.height / 2, r = size.width * 0.5
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 8),
                     with: .color(.black.opacity(0.25)))

            // Screen (vertical, in front of you)
            var screen = Path()
            screen.move(to: CGPoint(x: 8, y: cy - 24))
            screen.addLine(to: CGPoint(x: 8, y: cy + 24))
            ctx.stroke(screen, with: .color(.cyan.opacity(0.6)), lineWidth: 3)

            // Ear-level guide line
            var level = Path()
            level.move(to: CGPoint(x: 12, y: cy))
            level.addLine(to: CGPoint(x: size.width - 6, y: cy))
            ctx.stroke(level, with: .color(.white.opacity(0.12)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

            // Both speakers sit at ear level, so from the side they overlap.
            let on = model.mode != .stereo
            let s = CGPoint(x: cx - r * cos(model.width * .pi / 180), y: cy)
            ctx.fill(Path(ellipseIn: CGRect(x: s.x - 5, y: s.y - 5, width: 10, height: 10)),
                     with: .color(on ? .green : .gray))
            ctx.draw(Text("L+R").font(.caption2), at: CGPoint(x: s.x, y: s.y + 13))

            // pitch > 0 = looking up: arrow (pointing left) rotates clockwise
            // on screen, so its tip rises. Grey when pitch isn't applied.
            var head = ctx
            head.translateBy(x: cx, y: cy)
            head.rotate(by: .degrees(model.head.pitch))
            let color: Color = !model.tracking ? .orange : (model.usePitch ? .cyan : .gray)
            head.fill(Path(ellipseIn: CGRect(x: -9, y: -9, width: 18, height: 18)), with: .color(color))
            var arrow = Path()
            arrow.move(to: CGPoint(x: -9, y: 0))
            arrow.addLine(to: CGPoint(x: -30, y: 0))
            arrow.move(to: CGPoint(x: -24, y: -5))
            arrow.addLine(to: CGPoint(x: -32, y: 0))
            arrow.addLine(to: CGPoint(x: -24, y: 5))
            head.stroke(arrow, with: .color(color), lineWidth: 2)
        }
    }
}
