import AppKit
import ClaudeWorkersCore

/// A tiny template-image version of the mascot (see MascotView / the app icon) for the
/// menu bar. Template images take the bar's own colour in light and dark mode.
///   .idle      outlined body: no agent is busy
///   .working   solid body: at least one agent is working
///   .attention solid body plus a "!": an agent is waiting for you
enum MenuBarIcon {
    enum State { case idle, working, attention }

    private static var cache: [State: NSImage] = [:]

    static func image(_ state: State) -> NSImage {
        if let img = cache[state] { return img }
        let width: CGFloat = state == .attention ? 17 : 13
        let img = NSImage(size: NSSize(width: width, height: 16), flipped: true) { _ in
            draw(state)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = AppInfo.name
        cache[state] = img
        return img
    }

    private static func draw(_ state: State) {
        NSColor.black.setFill()
        NSColor.black.setStroke()
        // Body 11×12 (MascotView's 28×38 squared up a little so it reads at this size).
        let body = NSRect(x: 1, y: 1, width: 11, height: 12)
        let eyes = [NSRect(x: 3.6, y: 4.2, width: 1.8, height: 3), NSRect(x: 7.6, y: 4.2, width: 1.8, height: 3)]
        // Legs, tucked under the body (just below the outline when idle).
        let legTop: CGFloat = state == .idle ? 12.6 : 11
        for x in [2.8, 7.7] as [CGFloat] {
            NSBezierPath(roundedRect: NSRect(x: x, y: legTop, width: 2.5, height: 15 - legTop), xRadius: 0.9, yRadius: 0.9).fill()
        }
        if state == .idle {
            let outline = NSBezierPath(roundedRect: body.insetBy(dx: 0.6, dy: 0.6), xRadius: 2.2, yRadius: 2.2)
            outline.lineWidth = 1.2
            outline.stroke()
            eyes.forEach { NSBezierPath(roundedRect: $0, xRadius: 0.6, yRadius: 0.6).fill() }
        } else {
            // Solid body with the eyes punched out.
            let p = NSBezierPath(roundedRect: body, xRadius: 2.6, yRadius: 2.6)
            eyes.forEach { p.append(NSBezierPath(roundedRect: $0, xRadius: 0.6, yRadius: 0.6)) }
            p.windingRule = .evenOdd
            p.fill()
        }
        if state == .attention {
            NSBezierPath(roundedRect: NSRect(x: 14, y: 1.5, width: 2, height: 7.5), xRadius: 1, yRadius: 1).fill()
            NSBezierPath(ovalIn: NSRect(x: 14, y: 10.5, width: 2, height: 2)).fill()
        }
    }
}
