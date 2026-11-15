import SwiftUI
import ClaudeWorkersCore

struct PanelView: View {
    @Bindable var model: AppModel

    private var store: SessionStore { model.store }
    private var selected: AgentSession? {
        model.selectedID.flatMap { id in store.visibleSessions.first { $0.id == id } }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !model.collapsed {
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
                .transition(.opacity)
            }
        }
        .frame(width: Theme.width)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Theme.panel.opacity(0.97))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .preferredColorScheme(.dark)
        .animation(.snappy(duration: 0.22), value: model.collapsed)
        .animation(.snappy(duration: 0.22), value: model.selectedID)
        .animation(.snappy(duration: 0.22), value: store.visibleSessions.map(\.id))
        .fixedSize(horizontal: false, vertical: true)
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
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, model.collapsed ? 12 : 8)
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
