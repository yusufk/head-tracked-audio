import AppKit

/// Menu bar icon: a head wearing a headset, drawn as a template image so it
/// follows light/dark menu bars. Distinct from the system volume icon.
enum MenuBarIcon {
    static func image(on: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            let cx: CGFloat = 9, cy: CGFloat = 7.5

            // Head
            let head = NSBezierPath(ovalIn: NSRect(x: cx - 3.8, y: cy - 4.2, width: 7.6, height: 8.4))
            if on {
                head.fill()
            } else {
                head.lineWidth = 1.3
                head.stroke()
            }

            // Headband over the top, ear to ear
            let band = NSBezierPath()
            band.appendArc(withCenter: NSPoint(x: cx, y: cy), radius: 6.6,
                           startAngle: -5, endAngle: 185, clockwise: false)
            band.lineWidth = 1.5
            band.lineCapStyle = .round
            band.stroke()

            // Ear cups
            for x in [cx - 6.6, cx + 6.6] {
                let cup = NSBezierPath(roundedRect: NSRect(x: x - 1.6, y: cy - 3.2, width: 3.2, height: 5.6),
                                       xRadius: 1.4, yRadius: 1.4)
                cup.fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = on ? "HeadTrack on" : "HeadTrack off"
        return image
    }
}
