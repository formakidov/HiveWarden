import Foundation
import Observation

public enum AgentState: String {
    case working, needsPermission, asksQuestion, idle
}

public enum TodoStatus: String {
    case pending
    case inProgress = "in_progress"
    case completed
}

public struct TodoItem: Identifiable, Equatable {
    public var id: String
    public var content: String
    public var activeForm: String
    public var status: TodoStatus
    public init(id: String, content: String, activeForm: String, status: TodoStatus) {
        self.id = id
        self.content = content
        self.activeForm = activeForm
        self.status = status
    }
}

public enum ToolKind { case terminal, edit, read, search, web, agent, plan, other }

public struct ToolLine: Identifiable, Equatable {
    public let id: String
    public let kind: ToolKind
    public var title: String
    public var detail: String?
    public var running: Bool
    public init(id: String, kind: ToolKind, title: String, detail: String?, running: Bool) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.running = running
    }
}

/// `passthrough` = no opinion (request went stale / client hung up);
/// `terminal` = the user chose to answer in the terminal instead.
public enum PermissionChoice { case allow, deny, passthrough, terminal }

public struct QuestionOption: Identifiable, Equatable {
    public var id: Int
    public var label: String
    public var detail: String?
}

public struct Question: Identifiable, Equatable {
    public var id: Int
    public var header: String
    public var text: String
    public var options: [QuestionOption]
    public var multiSelect: Bool
}

@MainActor @Observable
public final class PendingPermission: Identifiable {
    public nonisolated let id = UUID()
    public let toolName: String
    public let detail: String
    /// Tool name + canonical input, to recognise the matching PostToolUse.
    let signature: String
    var resolver: ((PermissionChoice) -> Void)?
    private var resolved = false

    init(toolName: String, detail: String, signature: String) {
        self.toolName = toolName
        self.detail = detail
        self.signature = signature
    }

    public func resolve(_ choice: PermissionChoice) {
        guard !resolved else { return }
        resolved = true
        resolver?(choice)
    }
}

@MainActor @Observable
public final class PendingQuestion: Identifiable {
    public nonisolated let id = UUID()
    public let questions: [Question]
    /// question id → selected option ids
    public private(set) var selections: [Int: Set<Int>] = [:]
    /// question id → free-text "Other" answer
    public private(set) var customText: [Int: String] = [:]
    public private(set) var wentToTerminal = false
    var resolver: (([String: String]?) -> Void)?
    private var resolved = false

    init(questions: [Question]) { self.questions = questions }

    private func custom(_ q: Question) -> String {
        (customText[q.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isComplete: Bool {
        questions.allSatisfy { !(selections[$0.id] ?? []).isEmpty || !custom($0).isEmpty }
    }

    public func toggle(question: Question, option: QuestionOption) {
        var s = selections[question.id] ?? []
        if question.multiSelect {
            if s.contains(option.id) { s.remove(option.id) } else { s.insert(option.id) }
        } else {
            s = [option.id]
            customText[question.id] = nil      // single choice: an option replaces free text
        }
        selections[question.id] = s
    }

    public func setCustom(question: Question, text: String) {
        customText[question.id] = text
        if !question.multiSelect, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            selections[question.id] = []       // single choice: free text replaces the option
        }
    }

    /// Keyed by question text; the value is the chosen label(s) and/or free text, joined with ", ".
    public var answers: [String: String] {
        var out: [String: String] = [:]
        for q in questions {
            var picked = q.options.filter { (selections[q.id] ?? []).contains($0.id) }.map(\.label)
            if !custom(q).isEmpty { picked.append(custom(q)) }
            out[q.text] = picked.joined(separator: ", ")
        }
        return out
    }

    public func submit() {
        guard !resolved, isComplete else { return }
        resolved = true
        resolver?(answers)
    }

    /// No opinion: the request went stale or the client hung up.
    public func passthrough() {
        guard !resolved else { return }
        resolved = true
        resolver?(nil)
    }

    /// The user wants Claude's own prompt in the terminal.
    public func typeInTerminal() {
        guard !resolved else { return }
        wentToTerminal = true
        passthrough()
    }
}

@MainActor @Observable
public final class AgentSession: Identifiable {
    public nonisolated let id: String
    public var cwd: String
    public var customTitle: String?
    /// Folder name, de-duplicated with " (2)" when another session shares it.
    public var baseTitle: String
    public let folder: String
    /// Short label from the first prompt, so two sessions in one folder are tellable apart.
    public var topic: String?
    public var colorSlot: Int
    public var state: AgentState = .idle
    public var todos: [TodoItem] = []
    public var tools: [ToolLine] = []
    public var firstPrompt: String?
    public var lastAssistantMessage: String?
    public var currentThought = "Starting…"
    /// Parallel tool calls can each ask; they're answered one at a time.
    public var permissionQueue: [PendingPermission] = []
    public var question: PendingQuestion?
    /// Claude is blocked on something only its own terminal UI can answer.
    public var terminalPrompt: String?
    public var dismissed = false
    /// Whether this session has been sent the plan-reporting instruction (see `PlanReport`).
    public var planInstructed = false
    public var ppid: Int32?
    public var agentPID: Int32?
    public var tty: String?
    /// Tool calls and start time of the current turn (for sessions without a todo list).
    public var turnToolCount = 0
    public var turnStartedAt = Date()
    public var startedAt = Date()
    public var lastEventAt = Date()

    init(id: String, cwd: String, folder: String, baseTitle: String, colorSlot: Int) {
        self.id = id
        self.cwd = cwd
        self.folder = folder
        self.baseTitle = baseTitle
        self.colorSlot = colorSlot
    }

    public var permission: PendingPermission? { permissionQueue.first }

    public var title: String {
        if let customTitle { return customTitle }
        if let topic { return "\(folder) · \(topic)" }
        return baseTitle
    }

    public var needsAttention: Bool { permission != nil || question != nil || terminalPrompt != nil }

    public var progress: (done: Int, total: Int)? {
        guard !todos.isEmpty else { return nil }
        return (todos.filter { $0.status == .completed }.count, todos.count)
    }

    public var currentTodo: TodoItem? { todos.first { $0.status == .inProgress } }
    /// What the agent plans to do after the current step, in order.
    public var upcomingTodos: [TodoItem] { todos.filter { $0.status == .pending } }
    public var runningTool: ToolLine? { tools.last(where: \.running) }

    public var statusLine: String {
        if permission != nil {
            return permissionQueue.count > 1 ? "needs permission (\(permissionQueue.count))" : "needs permission"
        }
        if question != nil { return "asks a question" }
        if let terminalPrompt { return terminalPrompt }
        switch state {
        case .idle: return "Waiting for you"
        default:
            if let t = currentTodo { return t.activeForm }
            if let t = runningTool { return t.title }
            return currentThought
        }
    }

    /// "Fix the jump button" from a longer prompt. nil for slash commands / injected tags.
    static func topic(from prompt: String) -> String? {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        // Drop pasted prompt glyphs ("❯", ">", "$") in front of the actual text.
        let words = line.split(whereSeparator: \.isWhitespace)
            .drop { w in !w.contains { $0.isLetter || $0.isNumber || $0 == "/" || $0 == "<" } }
        // One-word prompts ("go", "yes", "continue") say nothing about the session.
        guard words.count >= 2, let first = words.first,
              !first.hasPrefix("/"), !first.hasPrefix("<") else { return nil }
        let text = words.joined(separator: " ")
        return text.count <= 26 ? text : String(text.prefix(25)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

public enum Palette {
    public static let hex = ["#5B8DEF", "#F08CB0", "#F5AA5B", "#A98BF5", "#5BD6A4", "#F2D45B"]
    public static func color(slot: Int) -> String { hex[((slot % hex.count) + hex.count) % hex.count] }
}
