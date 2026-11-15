import SwiftUI

extension Color {
    init(hex: String) {
        var h = hex
        if h.hasPrefix("#") { h.removeFirst() }
        let v = UInt64(h, radix: 16) ?? 0
        self.init(.sRGB,
                  red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

enum Theme {
    static let lime = Color(hex: "#DEFF5E")
    static let panel = Color(white: 0.115)
    static let row = Color(white: 0.165)
    static let rowHot = Color(white: 0.20)
    static let chip = Color(white: 0.27)
    static let text2 = Color(white: 0.62)
    static let text3 = Color(white: 0.42)
    static let hairline = Color.white.opacity(0.08)
    static let ink = Color(hex: "#1B1B1D")
    static let width: CGFloat = 392
}

/// Measures content so the scroll area can hug it up to a max height.
private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// Shows the content at its natural height, and only becomes a scroll view once the
/// content is taller than `maxHeight`. (Always scrolling meant starting from a guessed
/// height every time the view appeared; content taller than the guess was centred in it
/// for a frame, which made rows jump on expand.)
struct FittingScroll<Content: View>: View {
    var maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var h: CGFloat = 0

    var body: some View {
        Group {
            if h <= maxHeight {
                measured.frame(maxHeight: maxHeight, alignment: .top).clipped()
            } else {
                ScrollView(.vertical, showsIndicators: false) { measured }
                    .frame(height: maxHeight)
            }
        }
        .onPreferenceChange(HeightKey.self) { h = $0 }
    }

    private var measured: some View {
        content.background(GeometryReader { g in
            Color.clear.preference(key: HeightKey.self, value: g.size.height)
        })
    }
}

struct IconButton: View {
    var system: String
    var help: String
    var size: CGFloat = 13
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(hover ? .white : Theme.text2)
                .frame(width: 26, height: 26)
                .background(Circle().fill(hover ? Color.white.opacity(0.10) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

struct PillButton: View {
    enum Style { case primary, secondary }
    var title: String
    var style: Style = .secondary
    var enabled = true
    var action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(style == .primary ? Theme.ink : Color.white.opacity(0.9))
                .padding(.horizontal, 14).padding(.vertical, 6)
                .background(Capsule().fill(style == .primary
                                           ? Theme.lime.opacity(hover ? 1 : 0.94)
                                           : Color.white.opacity(hover ? 0.20 : 0.13)))
                .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
    }
}
