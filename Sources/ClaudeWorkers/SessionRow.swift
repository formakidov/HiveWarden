import SwiftUI
import ClaudeWorkersCore

struct SessionRow: View {
    @Bindable var model: AppModel
    var session: AgentSession
    var index: Int
    @State private var renaming = false
    @State private var draft = ""

    private var attention: Bool { session.needsAttention }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                MascotView(color: session.color, mood: session.mood, scale: 0.92, phase: Double(index) * 0.9)
                    .frame(width: 44)

                VStack(alignment: .leading, spacing: 3) {
                    if renaming {
                        TextField("Name", text: $draft, onCommit: commitRename)
                            .textFieldStyle(.plain).font(.system(size: 16, weight: .bold))
                            .onExitCommand { renaming = false }
                    } else {
                        Text(session.title)
                            .font(.system(size: 16, weight: .bold)).lineLimit(1)
                    }
                    Text(session.statusLine)
                        .font(.system(size: 13, weight: attention ? .bold : .regular))
                        .foregroundStyle(attention ? Theme.lime : Theme.text2)
                        .lineLimit(1)
                    ProgressLine(session: session)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 2) {
                    IconButton(system: "arrow.up.forward.square", help: "Jump to this agent") { model.jump(session) }
                    IconButton(system: "xmark", help: "Stop tracking", size: 12) { model.store.dismiss(session.id) }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture { if !renaming { model.selectedID = session.id } }
            .contextMenu {
                Button("Rename…") { draft = session.title; renaming = true }
                if session.customTitle != nil { Button("Reset name") { session.customTitle = nil } }
                Button("Jump to terminal") { model.jump(session) }
                Divider()
                Button("Stop tracking") { model.store.dismiss(session.id) }
            }

            if !session.upcomingTodos.isEmpty {
                NextSteps(model: model, session: session)
                    .padding(.leading, 68).padding(.trailing, 12).padding(.bottom, 10)
            }

            if let p = session.permission {
                PermissionCard(model: model, session: session, pending: p)
                    .padding(.horizontal, 10).padding(.bottom, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let q = session.question {
                QuestionCard(model: model, session: session, pending: q)
                    .padding(.horizontal, 10).padding(.bottom, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if session.permission == nil, session.question == nil, session.terminalPrompt != nil {
                TerminalCard(model: model, session: session)
                    .padding(.horizontal, 10).padding(.bottom, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(attention ? Theme.rowHot : Theme.row)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(attention ? Theme.lime : .clear, lineWidth: 2)
        )
        .animation(.snappy(duration: 0.2), value: attention)
    }

    private func commitRename() {
        let t = draft.trimmingCharacters(in: .whitespaces)
        session.customTitle = t.isEmpty ? nil : t
        renaming = false
    }
}

// MARK: - Progress

struct ProgressLine: View {
    var session: AgentSession

    var body: some View {
        HStack(spacing: 8) {
            if let p = session.progress {
                (Text("\(p.done)/\(p.total)").foregroundStyle(Theme.lime)
                 + Text(" tasks").foregroundStyle(Color.white.opacity(0.85)))
                    .font(.system(size: 12.5, weight: .bold))
                    .fixedSize()
                ProgressBar(fraction: Double(p.done) / Double(max(p.total, 1)))
            } else if session.state != .idle {
                // Mid-turn with no todo list: there is nothing to measure, so no bar.
                // A spinner says "working"; it stops while the agent is parked on you.
                if !session.needsAttention {
                    Spinner().frame(width: 13, height: 13)
                }
                (Text(stepsText).foregroundStyle(Theme.lime)
                 + Text(" · ").foregroundStyle(Theme.text3)
                 + Text(session.turnStartedAt, style: .timer).foregroundStyle(Color.white.opacity(0.85)))
                    .font(.system(size: 12.5, weight: .bold).monospacedDigit())
                    .fixedSize()
                Spacer(minLength: 0)
            } else {
                // Relative times go stale unless something re-renders them.
                TimelineView(.periodic(from: .now, by: 20)) { tl in
                    if session.turnToolCount > 0 {
                        (Text("✓ Done").foregroundStyle(Theme.lime)
                         + Text(" · \(stepsText) · \(elapsed(at: tl.date))").foregroundStyle(Theme.text2))
                            .font(.system(size: 12.5, weight: .bold))
                            .lineLimit(1)
                    } else {
                        Text(elapsed(at: tl.date))
                            .font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.text3)
                    }
                }
            }
        }
        .frame(height: 14)
    }

    private var stepsText: String {
        let n = session.turnToolCount
        return n == 1 ? "1 step" : "\(n) steps"
    }

    private func elapsed(at now: Date) -> String {
        let s = Int(now.timeIntervalSince(session.lastEventAt))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }
}

struct ProgressBar: View {
    /// 0...1, from the agent's own todo list.
    var fraction: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.13))
                Capsule().fill(Theme.lime)
                    .frame(width: fraction > 0 ? max(5, g.size.width * min(fraction, 1)) : 0)
                    .animation(.snappy, value: fraction)
            }
        }
        .frame(height: 5)
    }
}

// MARK: - Inline cards

struct PermissionCard: View {
    @Bindable var model: AppModel
    var session: AgentSession
    var pending: PendingPermission

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pending.detail)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.85))
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                PillButton(title: "Allow", style: .primary) { pending.resolve(.allow) }
                PillButton(title: "Deny") { pending.resolve(.deny) }
                PillButton(title: "In terminal") {
                    pending.resolve(.terminal)
                    model.jump(session)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}

struct QuestionCard: View {
    @Bindable var model: AppModel
    var session: AgentSession
    var pending: PendingQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(pending.questions) { q in
                VStack(alignment: .leading, spacing: 7) {
                    Text(q.header)
                        .font(.system(size: 11, weight: .heavy)).foregroundStyle(Theme.ink)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.lime))
                    Text(q.text).font(.system(size: 14.5, weight: .bold))
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(q.options) { o in
                        let on = (pending.selections[q.id] ?? []).contains(o.id)
                        Button { pending.toggle(question: q, option: o) } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: on
                                      ? (q.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                                      : (q.multiSelect ? "square" : "circle"))
                                    .foregroundStyle(on ? Theme.lime : Theme.text2)
                                    .font(.system(size: 13)).padding(.top, 2)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(o.label).font(.system(size: 13.5, weight: .semibold))
                                    if let d = o.detail, !d.isEmpty {
                                        Text(d).font(.system(size: 11.5)).foregroundStyle(Theme.text2).lineLimit(2)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.white.opacity(on ? 0.14 : 0.07)))
                        }
                        .buttonStyle(.plain)
                    }
                    TextField("Other…", text: Binding(
                        get: { pending.customText[q.id] ?? "" },
                        set: { pending.setCustom(question: q, text: $0) }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.07)))
                        .onSubmit { pending.submit() }
                }
            }
            HStack(spacing: 8) {
                PillButton(title: "Send", style: .primary, enabled: pending.isComplete) { pending.submit() }
                PillButton(title: "Answer in terminal") {
                    pending.typeInTerminal()
                    model.jump(session)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}

/// Claude is waiting in its own terminal UI (you chose "In terminal", or it's a plan review).
struct TerminalCard: View {
    @Bindable var model: AppModel
    var session: AgentSession

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.text2)
            Text("Waiting for you there").font(.system(size: 12.5)).foregroundStyle(Theme.text2)
            Spacer(minLength: 0)
            PillButton(title: "Open terminal", style: .primary) { model.jump(session) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.07)))
    }
}

/// "Next: …" under a row; click to unfold everything the agent still plans to do.
struct NextSteps: View {
    @Bindable var model: AppModel
    var session: AgentSession
    @State private var hover = false

    private var expanded: Bool { model.expandedNext.contains(session.id) }

    var body: some View {
        let upcoming = session.upcomingTodos
        VStack(alignment: .leading, spacing: 5) {
            Button {
                if expanded { model.expandedNext.remove(session.id) } else { model.expandedNext.insert(session.id) }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .heavy))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 10)
                    if expanded {
                        Text("Next · \(upcoming.count)").font(.system(size: 11.5, weight: .bold))
                    } else {
                        // `first`, not `[0]`: the plan can be cleared (new session, new
                        // prompt) between two renders while this row is still on screen.
                        (Text("Next: ").font(.system(size: 11.5, weight: .bold))
                         + Text(upcoming.first?.content ?? "").font(.system(size: 11.5)))
                            .lineLimit(1)
                        if upcoming.count > 1 {
                            Text("+\(upcoming.count - 1)")
                                .font(.system(size: 10.5, weight: .bold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.white.opacity(0.12)))
                        }
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(hover ? Color.white.opacity(0.9) : Theme.text2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .help(expanded ? "Hide upcoming steps" : "Show upcoming steps")

            if expanded {
                ForEach(Array(upcoming.enumerated()), id: \.element.id) { i, t in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("\(i + 1)")
                            .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                            .foregroundStyle(Theme.text3)
                            .frame(width: 14, alignment: .trailing)
                        Text(t.content)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(i == 0 ? 0.9 : 0.62))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
                .transition(.opacity)
            }
        }
        .animation(.snappy(duration: 0.18), value: expanded)
    }
}
