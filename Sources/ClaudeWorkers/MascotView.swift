import SwiftUI

/// The little coloured buddy. Pure shapes, animated by a TimelineView:
/// bobs while working, hops when it needs you, happy-eyed when idle, blinks.
struct MascotView: View {
    enum Mood { case working, attention, happy }
    var color: Color
    var mood: Mood
    var scale: CGFloat = 1
    var phase: Double = 0     // desync multiple mascots

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate + phase
            let lift: CGFloat = {
                switch mood {
                case .working: return CGFloat(sin(t * 3.2)) * 1.6 * scale
                case .attention: return -CGFloat(abs(sin(t * 5.5))) * 7 * scale
                case .happy: return 0
                }
            }()
            let blink = t.truncatingRemainder(dividingBy: 3.7) < 0.12
            let shadowScale = 1 - (-lift / (12 * scale)) * 0.35

            ZStack(alignment: .bottom) {
                Ellipse()
                    .fill(Color.black.opacity(0.45))
                    .frame(width: 26 * scale * shadowScale, height: 5 * scale)
                    .blur(radius: 1.2)
                    .offset(y: 3 * scale)

                VStack(spacing: 0) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6 * scale, style: .continuous).fill(color)
                        Face(mood: mood, blink: blink, scale: scale)
                    }
                    .frame(width: 28 * scale, height: 38 * scale)
                    HStack(spacing: 11 * scale) {
                        Leg(color: color, scale: scale)
                        Leg(color: color, scale: scale)
                    }
                }
                .offset(y: lift)
            }
            .frame(width: 44 * scale, height: 56 * scale, alignment: .bottom)
        }
    }

    private struct Leg: View {
        var color: Color
        var scale: CGFloat
        var body: some View {
            UnevenRoundedRectangle(bottomLeadingRadius: 2 * scale, bottomTrailingRadius: 2 * scale)
                .fill(color).frame(width: 5 * scale, height: 7 * scale)
        }
    }

    private struct Face: View {
        var mood: Mood
        var blink: Bool
        var scale: CGFloat
        private let ink = Color(hex: "#1B1B1D")

        var body: some View {
            VStack(spacing: 7 * scale) {
                HStack(spacing: 8 * scale) { eye; eye }
                Capsule().fill(ink).frame(width: 8 * scale, height: 2 * scale)
                    .opacity(mood == .happy ? 1 : 0.9)
            }
            .offset(y: -1 * scale)
        }

        @ViewBuilder private var eye: some View {
            if mood == .happy || blink {
                // ︶ closed / happy eye (an upside-down U when happy)
                Arc(up: mood == .happy)
                    .stroke(ink, style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round))
                    .frame(width: 7 * scale, height: 4 * scale)
            } else {
                RoundedRectangle(cornerRadius: 1.5 * scale).fill(ink)
                    .frame(width: 4.5 * scale, height: 6.5 * scale)
            }
        }
    }

    private struct Arc: Shape {
        var up: Bool
        func path(in r: CGRect) -> Path {
            var p = Path()
            if up {
                p.move(to: CGPoint(x: r.minX, y: r.maxY))
                p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX, y: r.minY - r.height * 0.6))
            } else {
                p.move(to: CGPoint(x: r.minX, y: r.midY))
                p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            }
            return p
        }
    }
}
