import Foundation
import Observation

/// The reducer: turns hook events into session state, and parks blocking requests
/// (permissions, questions) until the UI resolves them.
@MainActor @Observable
public final class SessionStore {
    public private(set) var sessions: [AgentSession] = []

    /// Called when a session starts needing the user (play a sound, show panel…).
    @ObservationIgnored public var onAttention: ((AgentSession) -> Void)?

    /// Ask agents (via hook-injected context) to announce their plan. See `PlanReport`.
    /// Off here so the reducer is inert by default; the app enables it.
    @ObservationIgnored public var planReporting = false

    public init() {}

    /// Sessions that need you float to the top; otherwise start order is stable.
    public var visibleSessions: [AgentSession] {
        let v = sessions.filter { !$0.dismissed }
        return v.filter(\.needsAttention) + v.filter { !$0.needsAttention }
    }
    public var attentionCount: Int { visibleSessions.filter(\.needsAttention).count }
    public var workingCount: Int { visibleSessions.filter { $0.state == .working }.count }

    // MARK: - Public API

    public func session(id: String) -> AgentSession? { sessions.first { $0.id == id } }

    /// Resolve the front permission request from outside the UI (control API).
    @discardableResult
    public func decidePermission(sessionID: String, choice: PermissionChoice) -> Bool {
        guard let p = session(id: sessionID)?.permission else { return false }
        p.resolve(choice)
        return true
    }

    public func dismiss(_ id: String) {
        guard let s = session(id: id) else { return }
        clearPending(s)
        s.dismissed = true
    }

    public func remove(_ id: String) {
        guard let s = session(id: id) else { return }
        clearPending(s)
        sessions.removeAll { $0.id == id }
    }

    /// Drop sessions whose `claude` process is gone, or that have been silent for ages.
    public func prune(now: Date = Date(), isAlive: (Int32) -> Bool = SessionStore.processAlive) {
        for s in sessions {
            if let pid = s.agentPID, !isAlive(pid) {
                remove(s.id)
            } else if s.state == .idle, now.timeIntervalSince(s.lastEventAt) > 12 * 3600 {
                remove(s.id)
            }
        }
    }

    public nonisolated static func processAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Handle one hook event. Returns the body to print on the hook's stdout
    /// (empty = "no opinion"). May suspend for a long time on blocking events.
    public func handle(_ ev: HookEvent,
                       meta: HookMeta = HookMeta(),
                       request: RequestHandle = RequestHandle()) async -> String {
        let s = ensureSession(ev, meta)
        s.lastEventAt = Date()
        if let c = ev.cwd { s.cwd = c }

        switch ev.name {
        case "SessionStart":
            clearPending(s)
            s.dismissed = false
            if ev.source != "resume" && ev.source != "compact" { s.todos = []; s.tools = [] }
            s.state = .idle
            s.currentThought = "Session started"
            // Also re-sent after compaction, when the instruction is gone again.
            s.planInstructed = planReporting
            if planReporting { return PlanReport.contextReply(event: "SessionStart") }

        case "UserPromptSubmit":
            clearPending(s)
            s.dismissed = false
            s.state = .working
            s.currentThought = "Thinking…"
            s.turnToolCount = 0
            s.turnStartedAt = Date()
            s.tools = []     // "Recent" is this turn only; old steps would read as already done
            // A finished plan belongs to the previous request.
            if !s.todos.isEmpty, s.todos.allSatisfy({ $0.status == .completed }) { s.todos = [] }
            if let p = ev.prompt, !p.isEmpty {
                if s.firstPrompt == nil { s.firstPrompt = p }
                if s.topic == nil { s.topic = AgentSession.topic(from: p) }
            }
            // Sessions that were already open when the switch was turned on (or when the
            // app restarted) get the instruction once, with their next prompt.
            if planReporting, !s.planInstructed {
                s.planInstructed = true
                return PlanReport.contextReply(event: "UserPromptSubmit")
            }

        case "PreToolUse":
            guard let tool = ev.toolName else { break }
            if tool == "AskUserQuestion" {
                return await askQuestion(s, ev, request)
            }
            // NB: a parked card is NOT cleared here. Parallel tool calls and subagents
            // keep producing events while one call waits for you.
            s.terminalPrompt = nil
            if !s.needsAttention { s.state = .working }
            var input = ev.toolInput
            if let scan = Self.planReport(ev) {
                // The agent announcing its plan. A report in front of the real command is
                // the state while it runs; one after it only counts once it has finished.
                if let now = scan.leading { s.todos = PlanReport.todos(from: now) }
                if scan.remainder.isEmpty { break }          // nothing but the report: not a step
                input["command"] = scan.remainder             // show the real work, not the report
            }
            let d = ToolDescriber.describe(tool: tool, input: input)
            let line = ToolLine(id: ev.toolUseID ?? UUID().uuidString, kind: d.kind,
                                title: d.title, detail: d.detail, running: true)
            s.tools.append(line)
            s.turnToolCount += 1
            if s.tools.count > 40 { s.tools.removeFirst(s.tools.count - 40) }

        case "PostToolUse":
            // This exact call ran, so anything still asking about it was answered elsewhere.
            if let tool = ev.toolName {
                let sig = Self.signature(tool: tool, input: ev.toolInput)
                settlePermissions(s) { $0.signature == sig }
                if tool == "AskUserQuestion" { s.question?.passthrough(); s.question = nil }
            }
            s.terminalPrompt = nil
            restoreState(s)
            if !s.needsAttention { s.state = .working }
            if let scan = Self.planReport(ev) {
                s.todos = PlanReport.todos(from: scan.last)
                if scan.remainder.isEmpty { break }      // was never shown as a step
            }
            if let id = ev.toolUseID, let i = s.tools.lastIndex(where: { $0.id == id }) {
                s.tools[i].running = false
            } else if let i = s.tools.lastIndex(where: \.running) {
                s.tools[i].running = false
            }
            applyPlanTool(s, ev)

        case "PermissionRequest":
            guard let tool = ev.toolName, tool != "AskUserQuestion" else { return "" }
            if tool == "ExitPlanMode" {
                // A bare "allow" can't approve a plan; send the user to Claude's own UI.
                s.terminalPrompt = "Plan ready for review"
                s.dismissed = false
                onAttention?(s)
                return ""
            }
            return await askPermission(s, tool: tool, input: ev.toolInput, request)

        case "Notification":
            if ev.notificationType == "idle_prompt", !s.needsAttention { s.state = .idle }

        case "PreCompact":
            s.currentThought = "Compacting context…"

        case "Stop":
            clearPending(s)
            s.state = .idle
            for i in s.tools.indices { s.tools[i].running = false }
            if let m = ev.lastAssistantMessage, !m.isEmpty { s.lastAssistantMessage = m }

        case "SessionEnd":
            remove(s.id)

        default:
            break
        }
        return ""
    }

    // MARK: - Blocking requests

    private func askPermission(_ s: AgentSession, tool: String, input: [String: Any],
                               _ request: RequestHandle) async -> String {
        let p = PendingPermission(toolName: tool,
                                  detail: ToolDescriber.permissionDetail(tool: tool, input: input),
                                  signature: Self.signature(tool: tool, input: input))
        let choice: PermissionChoice = await withCheckedContinuation { cont in
            p.resolver = { cont.resume(returning: $0) }
            request.onCancel = { p.resolve(.passthrough) }
            s.permissionQueue.append(p)
            s.terminalPrompt = nil
            s.state = .needsPermission
            s.dismissed = false
            onAttention?(s)
        }
        s.permissionQueue.removeAll { $0 === p }
        if choice == .terminal { s.terminalPrompt = "Needs permission in the terminal" }
        restoreState(s)
        return HookReply.permission(choice)
    }

    private func askQuestion(_ s: AgentSession, _ ev: HookEvent,
                             _ request: RequestHandle) async -> String {
        let questions = Self.parseQuestions(ev.toolInput)
        guard !questions.isEmpty else { return "" }
        s.question?.passthrough()
        let q = PendingQuestion(questions: questions)
        let answer: [String: String]? = await withCheckedContinuation { cont in
            q.resolver = { cont.resume(returning: $0) }
            request.onCancel = { q.passthrough() }
            s.question = q
            s.terminalPrompt = nil
            s.state = .asksQuestion
            s.dismissed = false
            onAttention?(s)
        }
        if s.question === q { s.question = nil }
        if q.wentToTerminal { s.terminalPrompt = "Asks a question in the terminal" }
        restoreState(s)
        return HookReply.question(questions: ev.toolInput["questions"], answers: answer)
    }

    static func parseQuestions(_ input: [String: Any]) -> [Question] {
        let arr = input["questions"] as? [[String: Any]] ?? []
        return arr.enumerated().map { qi, d in
            let opts = (d["options"] as? [[String: Any]] ?? []).enumerated().map { oi, o in
                QuestionOption(id: oi, label: o["label"] as? String ?? "Option \(oi + 1)",
                               detail: o["description"] as? String)
            }
            return Question(id: qi,
                            header: (d["header"] as? String ?? "Question").uppercased(),
                            text: d["question"] as? String ?? "",
                            options: opts,
                            multiSelect: d["multiSelect"] as? Bool ?? false)
        }
    }

    static func planReport(_ ev: HookEvent) -> PlanReport.Scan? {
        guard ev.toolName == "Bash", let cmd = ev.toolInput["command"] as? String else { return nil }
        return PlanReport.scan(command: cmd)
    }

    /// Tool name + canonical (sorted-key) input. `PermissionRequest` carries no
    /// tool_use_id, so this is how we recognise the PostToolUse of the same call.
    static func signature(tool: String, input: [String: Any]) -> String {
        let d = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        return tool + "|" + (d.flatMap { String(data: $0, encoding: .utf8) } ?? "")
    }

    /// Drop matching cards right away (so the UI updates) and release their hooks.
    private func settlePermissions(_ s: AgentSession, where stale: (PendingPermission) -> Bool) {
        let gone = s.permissionQueue.filter(stale)
        guard !gone.isEmpty else { return }
        s.permissionQueue.removeAll(where: stale)
        gone.forEach { $0.resolve(.passthrough) }
    }

    /// The turn is over (or restarted): nothing parked can still be valid.
    private func clearPending(_ s: AgentSession) {
        settlePermissions(s) { _ in true }
        s.question?.passthrough()
        s.question = nil
        s.terminalPrompt = nil
    }

    /// Keep `state` in step with what is (still) parked.
    private func restoreState(_ s: AgentSession) {
        if s.permission != nil {
            s.state = .needsPermission
        } else if s.question != nil {
            s.state = .asksQuestion
        } else if s.state == .needsPermission || s.state == .asksQuestion {
            s.state = .working
        }
    }

    // MARK: - Plan / todo tracking

    private func applyPlanTool(_ s: AgentSession, _ ev: HookEvent) {
        guard let tool = ev.toolName else { return }
        let input = ev.toolInput
        switch tool {
        case "TodoWrite":
            let arr = input["todos"] as? [[String: Any]] ?? []
            s.todos = arr.enumerated().map { i, d in
                let content = d["content"] as? String ?? d["subject"] as? String ?? "Step \(i + 1)"
                return TodoItem(id: String(i), content: content,
                                activeForm: d["activeForm"] as? String ?? content,
                                status: TodoStatus(rawValue: d["status"] as? String ?? "") ?? .pending)
            }
        case "TaskCreate":
            // Newer Claude Code task tools. Shapes inferred; best effort.
            let subject = input["subject"] as? String ?? input["content"] as? String ?? "Task"
            let id = Self.extractTaskID(ev.toolResponse) ?? String(s.todos.count + 1)
            guard !s.todos.contains(where: { $0.id == id }) else { break }
            s.todos.append(TodoItem(id: id, content: subject,
                                    activeForm: input["activeForm"] as? String ?? subject,
                                    status: .pending))
        case "TaskUpdate":
            let id = (input["taskId"] as? String) ?? (input["taskId"] as? Int).map(String.init) ?? ""
            guard let i = s.todos.firstIndex(where: { $0.id == id }) else { break }
            if let st = input["status"] as? String {
                if st == "deleted" { s.todos.remove(at: i); break }
                if let v = TodoStatus(rawValue: st) { s.todos[i].status = v }
            }
            if let sub = input["subject"] as? String { s.todos[i].content = sub }
            if let af = input["activeForm"] as? String { s.todos[i].activeForm = af }
        default: break
        }
    }

    static func extractTaskID(_ response: Any?) -> String? {
        guard let response else { return nil }
        var text = ""
        if let s = response as? String { text = s }
        else if let d = try? JSONSerialization.data(withJSONObject: response),
                let s = String(data: d, encoding: .utf8) { text = s }
        for pattern in [#"[Tt]ask\s*#?(\d+)"#, #""(?:task)?[iI]d"\s*:\s*"?(\d+)"#, #"#(\d+)"#] {
            if let re = try? NSRegularExpression(pattern: pattern),
               let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(m.range(at: 1), in: text) { return String(text[r]) }
        }
        return nil
    }

    // MARK: - Session bookkeeping

    private func ensureSession(_ ev: HookEvent, _ meta: HookMeta) -> AgentSession {
        if let s = session(id: ev.sessionID) {
            if let p = meta.ppid { s.ppid = p; if s.agentPID == nil { s.agentPID = Self.findAgentPID(from: p) } }
            if let t = meta.tty, !t.isEmpty, t != "??" { s.tty = t }
            return s
        }
        let cwd = ev.cwd ?? "~"
        var folder = (cwd as NSString).lastPathComponent
        if folder.isEmpty { folder = "Claude" }
        let dupes = sessions.filter { $0.folder == folder }.count
        let title = dupes == 0 ? folder : "\(folder) (\(dupes + 1))"
        let used = Set(sessions.map(\.colorSlot))
        let slot = (0..<Palette.hex.count).first { !used.contains($0) } ?? sessions.count
        let s = AgentSession(id: ev.sessionID, cwd: cwd, folder: folder, baseTitle: title, colorSlot: slot)
        s.ppid = meta.ppid
        s.agentPID = meta.ppid.flatMap { Self.findAgentPID(from: $0) }
        if let t = meta.tty, !t.isEmpty, t != "??" { s.tty = t }
        sessions.append(s)
        return s
    }

    /// The hook's parent is normally `claude` itself; if it's a transient shell, climb.
    static func findAgentPID(from pid: Int32) -> Int32? {
        var p = pid
        for _ in 0..<6 {
            if ProcessTree.name(of: p)?.lowercased().contains("claude") == true { return p }
            guard let parent = ProcessTree.parent(of: p), parent > 1 else { return nil }
            p = parent
        }
        return nil
    }
}

/// Tiny process-tree helper (no subprocess spawning).
public enum ProcessTree {
    /// Uses sysctl rather than proc_pidinfo: the latter is denied for setuid binaries
    /// like `login`, which sits between Terminal.app and your shell.
    public static func parent(of pid: Int32) -> Int32? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    public static func name(of pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }
}
