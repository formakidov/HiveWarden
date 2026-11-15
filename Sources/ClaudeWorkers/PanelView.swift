import SwiftUI
import ClaudeWorkersCore

private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct HeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PanelView: View {
    @Bindable var model: AppModel
    @State private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    @State private var dragMoved = false

    private var store: SessionStore { model.store }
    private var selected: AgentSession? {
        model.selectedID.flatMap { id in store.visibleSessions.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.showContent {
                Group {
                    if let s = selected {
                        DetailView(model: model, session: s)
                    } else if store.visibleSessions.isEmpty {
                        EmptyState(model: model)
                    } else {
                        FittingScroll(maxHeight: 620) {
                            VStack(spacing: 8) {
                                ForEach(Array(store.visibleSessions.enumerated()), id: \.element.id) { i, s in
                                    SessionRow(model: model, session: s, index: i)
                                }
                            }
                            .padding(.horizontal, 10).padding(.bottom, 10)
                        }
                    }
                }
            } else {
                Color.clear.frame(height: 4)   // collapsed: balance the header's bottom padding
            }
        }
        .onPreferenceChange(HeaderHeightKey.self) { model.headerHeight = $0 }
        .frame(width: Theme.width)
        .animation(.snappy(duration: 0.22), value: model.selectedID)
        .animation(.snappy(duration: 0.22), value: store.visibleSessions.map(\.id))
        .fixedSize(horizontal: false, vertical: true)
        // The window follows this measured height (AppDelegate.fitPanel).
        .background(GeometryReader { g in Color.clear.preference(key: PanelHeightKey.self, value: g.size.height) })
        .onPreferenceChange(PanelHeightKey.self) { model.contentHeight = $0 }
        // Collapse/expand is animated by the window itself, top edge fixed. The panel fills
        // the window with its content pinned to the top, so the moving bottom edge reveals
        // or covers the content. minHeight 0 makes this frame take the window's height even
        // when the content is taller; otherwise the whole view gets centred and jumps.
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.panel.opacity(0.97))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    @ViewBuilder private var header: some View {
        HStack(spacing: 8) {
            if let s = selected {
                IconButton(system: "chevron.left", help: "Back") { model.selectedID = nil }
                ForEach(store.visibleSessions) { other in
                    Button { model.selectedID = other.id } label: {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(other.color)
                            .frame(width: 30, height: 24)
                            .overlay(Text(other.id == s.id ? "▪ ▪" : "· ·")
                                .font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.ink))
                            .opacity(other.id == s.id ? 1 : 0.55)
                            .overlay(alignment: .topTrailing) {
                                if other.needsAttention {
                                    Circle().fill(Theme.lime).frame(width: 8, height: 8)
                                        .overlay(Circle().strokeBorder(Theme.panel, lineWidth: 1.5)).offset(x: 3, y: -3)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(other.title)
                }
            } else {
                Circle()
                    .fill(store.attentionCount > 0 ? Color.orange : (store.workingCount > 0 ? Theme.lime : Theme.text3))
                    .frame(width: 9, height: 9)
                Text(AppInfo.name).font(.system(size: 17, weight: .bold))
                Text("\(store.visibleSessions.count)")
                    .font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text2)
            }
            Spacer(minLength: 0)
            if let s = selected {
                IconButton(system: "arrow.up.forward.square", help: "Jump to \(s.title)") { model.jump(s) }
            }
            IconButton(system: model.soundEnabled ? "speaker.wave.2" : "speaker.slash",
                       help: model.soundEnabled ? "Mute alerts" : "Unmute alerts") { model.soundEnabled.toggle() }
            IconButton(system: model.collapsed ? "chevron.down" : "chevron.up",
                       help: model.collapsed ? "Expand" : "Collapse", size: 12) { model.collapsed.toggle() }
            IconButton(system: "xmark", help: "Hide (menu bar icon brings it back)", size: 12) { model.hidePanel() }
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
        .background(GeometryReader { g in Color.clear.preference(key: HeaderHeightKey.self, value: g.size.height) })
        .contentShape(Rectangle())
        .gesture(headerDrag)
        .help(model.collapsed ? "Click to expand, drag to move" : "Click to collapse, drag to move")
    }

    /// Click (no movement) on the header's empty space toggles collapse; dragging moves
    /// the panel. Done by hand because a tap gesture here would stop the window's own
    /// drag-by-background. Uses screen coordinates so moving the window doesn't feed
    /// back into the gesture. The buttons in the header keep their own clicks.
    private var headerDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { _ in
                guard let w = model.panelWindow() else { return }
                let mouse = NSEvent.mouseLocation
                if dragStart == nil { dragStart = (mouse, w.frame.origin) }
                guard let start = dragStart else { return }
                let dx = mouse.x - start.mouse.x, dy = mouse.y - start.mouse.y
                if !dragMoved, hypot(dx, dy) < 3 { return }   // still a click
                dragMoved = true
                w.setFrameOrigin(NSPoint(x: start.origin.x + dx, y: start.origin.y + dy))
            }
            .onEnded { _ in
                if !dragMoved { model.collapsed.toggle() }
                dragStart = nil
                dragMoved = false
            }
    }
}

// MARK: - Empty / onboarding

private struct EmptyState: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                ForEach(0..<4, id: \.self) { i in
                    MascotView(color: Color(white: 0.24), mood: .working, scale: 0.7, phase: Double(i) * 0.7)
                        .opacity(0.8)
                }
            }
            .padding(.top, 4)

            if model.hooksInstalled {
                Text("No agents running").font(.system(size: 14, weight: .semibold))
                Text("Start `claude` in any terminal or editor and it will show up here.")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
                    .multilineTextAlignment(.center)
            } else {
                Text("Connect Claude Code").font(.system(size: 14, weight: .semibold))
                Text("Install the hooks so your agents can report in. This adds a few entries to ~/.claude/settings.json (a backup is kept).")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
                    .multilineTextAlignment(.center)
                PillButton(title: "Install hooks", style: .primary) { model.installHooks() }
                    .padding(.top, 2)
            }
            if let e = model.installError {
                Text(e).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 22).padding(.vertical, 16)
    }
}
