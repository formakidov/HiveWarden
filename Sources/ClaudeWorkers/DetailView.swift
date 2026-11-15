import SwiftUI
import ClaudeWorkersCore

struct DetailView: View {
    @Bindable var model: AppModel
    var session: AgentSession

    var body: some View {
        FittingScroll(maxHeight: 620) {
            VStack(alignment: .leading, spacing: 10) {
                summary
                if let p = session.permission { PermissionCard(model: model, session: session, pending: p) }
                if let q = session.question { QuestionCard(model: model, session: session, pending: q) }
                if session.permission == nil, session.question == nil, session.terminalPrompt != nil {
                    TerminalCard(model: model, session: session)
                }
                if !session.todos.isEmpty { todoList }
                recentTools
                terminalBlock
            }
            .padding(.horizontal, 10).padding(.bottom, 10)
        }
    }

    private var summary: some View {
        HStack(spacing: 14) {
            MascotView(color: session.color, mood: session.mood, scale: 1.15)
                .frame(width: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title).font(.system(size: 20, weight: .bold)).lineLimit(1)
                Text(session.statusLine)
                    .font(.system(size: 14, weight: session.needsAttention ? .bold : .regular))
                    .foregroundStyle(session.needsAttention ? Theme.lime : Theme.text2)
                    .lineLimit(2)
                ProgressLine(session: session)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.row))
    }

    private var todoList: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(session.todos) { t in
                HStack(spacing: 10) {
                    StatusGlyph(status: t.status)
                    Text(t.status == .inProgress ? t.activeForm : t.content)
                        .font(.system(size: 14, weight: t.status == .inProgress ? .semibold : .regular))
                        .foregroundStyle(t.status == .pending ? Theme.text2 : (t.status == .completed ? Theme.text2 : .white))
                        .strikethrough(false)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.row))
    }

    @ViewBuilder private var recentTools: some View {
        let tools = Array(session.tools.suffix(6).reversed())
        if !tools.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Text("RECENT").font(.system(size: 10.5, weight: .heavy)).foregroundStyle(Theme.text3)
                ForEach(tools) { t in
                    HStack(spacing: 10) {
                        Group {
                            if t.running {
                                Spinner().frame(width: 16, height: 16)
                            } else {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 15)).foregroundStyle(Color.white.opacity(0.28))
                            }
                        }
                        .frame(width: 20, height: 20)
                        Image(systemName: icon(t.kind))
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.text2)
                            .frame(width: 18, height: 18)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.09)))
                        Text(t.title)
                            .font(.system(size: 13.5, weight: t.running ? .semibold : .regular))
                            .foregroundStyle(t.running ? .white : Theme.text2)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.row))
        }
    }

    @ViewBuilder private var terminalBlock: some View {
        if let cmd = lastCommand {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: "terminal").font(.system(size: 11, weight: .semibold))
                    Text("Terminal").font(.system(size: 12.5, weight: .semibold))
                }
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.10)))
                (Text("$ ").foregroundStyle(Theme.lime) + Text(cmd).foregroundStyle(Theme.lime))
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineLimit(5)
                    .textSelection(.enabled)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.09)))
        } else if session.state == .idle, let m = session.lastAssistantMessage {
            Text(ToolDescriber.shorten(m, 400))
                .font(.system(size: 12.5)).foregroundStyle(Theme.text2)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(white: 0.09)))
        }
    }

    private var lastCommand: String? {
        session.tools.last(where: { $0.kind == .terminal && $0.detail != nil })?.detail
    }

    private func icon(_ k: ToolKind) -> String {
        switch k {
        case .terminal: return "terminal"
        case .edit: return "pencil"
        case .read: return "doc.text"
        case .search: return "magnifyingglass"
        case .web: return "globe"
        case .agent: return "person.2"
        case .plan: return "checklist"
        case .other: return "wrench.and.screwdriver"
        }
    }
}

private struct StatusGlyph: View {
    var status: TodoStatus
    var body: some View {
        Group {
            switch status {
            case .completed:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(Color.white.opacity(0.32))
            case .inProgress:
                Spinner().frame(width: 16, height: 16)
            case .pending:
                Circle().strokeBorder(Color.white.opacity(0.28), lineWidth: 1.6).frame(width: 15, height: 15)
            }
        }
        .frame(width: 20, height: 20)   // fixed slot so labels line up
    }
}

struct Spinner: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            Circle().trim(from: 0, to: 0.72)
                .stroke(Theme.lime, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(t.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360))
                .padding(1)
        }
    }
}
