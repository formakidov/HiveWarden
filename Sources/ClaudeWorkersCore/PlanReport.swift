import Foundation

/// Plan reporting for Claude Code builds that give the agent no todo tool. The app
/// turns it on by default; the menu-bar switch turns it off.
///
/// At session start we inject one instruction asking the agent to announce its plan
/// with a no-op shell command, e.g.
///
///     echo HIVE_PLAN 1 '["Read the code","Write the fix","Run the tests"]'
///
/// (1 = steps already finished). We see that command in `PreToolUse` and turn it into
/// the same todo list a `TodoWrite` call would give us.
public enum PlanReport {
    public static let marker = "HIVE_PLAN"

    public static let instructions = """
        \(AppInfo.name), a progress dashboard on this machine, is watching this session. \
        When a task has 3 or more steps, report your plan so the user can see what is coming: \
        run the Bash command `echo \(marker) <number of steps already finished> '<JSON array of short step names>'` \
        once before you start, and again each time you finish a step (so the last one reports every step finished). \
        Example: echo \(marker) 1 '["Read the code","Write the fix","Run the tests"]' . \
        Keep step names under 60 characters and free of apostrophes. It is a harmless no-op, \
        so there is no need to comment on it in your replies. Skip it for tasks with fewer than 3 steps.
        """

    /// Hook reply that adds `instructions` to the session's context. Valid for the
    /// `SessionStart` and `UserPromptSubmit` events.
    public static func contextReply(event: String) -> String {
        HookReply.compact(["hookSpecificOutput": [
            "hookEventName": event,
            "additionalContext": instructions,
        ]])
    }

    public struct Plan: Equatable {
        public var done: Int
        public var steps: [String]
    }

    /// Recognises exactly `echo HIVE_PLAN <n> '<json array of strings>'` (double quotes
    /// around the array are tolerated). Anything else, including the same prefix with
    /// extra shell after it, is not a plan report.
    public static func parse(command: String) -> Plan? {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "echo \(marker) "
        guard c.hasPrefix(prefix) else { return nil }
        let rest = c.dropFirst(prefix.count)
        guard let space = rest.firstIndex(of: " "), let done = Int(rest[..<space]), done >= 0 else { return nil }
        var payload = rest[rest.index(after: space)...].trimmingCharacters(in: .whitespaces)

        if payload.count >= 2, payload.hasPrefix("'"), payload.hasSuffix("'") {
            payload = String(payload.dropFirst().dropLast())
            guard !payload.contains("'") else { return nil }       // would have ended the quoting
        } else if payload.count >= 2, payload.hasPrefix("\""), payload.hasSuffix("\"") {
            payload = String(payload.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
        } else {
            return nil
        }
        guard let data = payload.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [String], !arr.isEmpty else { return nil }
        let steps = arr.prefix(40).map { ToolDescriber.shorten($0, 90) }
        return Plan(done: min(done, steps.count), steps: Array(steps))
    }

    /// Plan reports found inside a (possibly compound) shell command.
    public struct Scan: Equatable {
        /// A report at the very start: the state while the rest of the command runs.
        public var leading: Plan?
        /// The last report in the command: the state once it has finished.
        public var last: Plan
        /// The command with the reports removed ("" if it was nothing but reports).
        public var remainder: String
    }

    /// Agents often bundle the report with the step itself, e.g.
    /// `sleep 6 && echo done; echo HIVE_PLAN 2 '[…]'`, so look anywhere in the command.
    public static func scan(command: String) -> Scan? {
        // group 1 = finished count, group 2 = the quoted JSON array (quotes included)
        let pattern = #"echo\s+HIVE_PLAN\s+(\d+)\s+('[^']*'|"(?:[^"\\]|\\.)*")"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = command as NSString
        var found: [(range: NSRange, plan: Plan)] = []
        for m in re.matches(in: command, range: NSRange(location: 0, length: ns.length)) {
            // Hand each piece to the strict single-report parser in its canonical spacing.
            let piece = "echo \(marker) \(ns.substring(with: m.range(at: 1))) \(ns.substring(with: m.range(at: 2)))"
            if let plan = parse(command: piece) { found.append((m.range, plan)) }
        }
        guard let first = found.first, let last = found.last else { return nil }

        // "Leading" = nothing but whitespace in front of the first report.
        let before = ns.substring(to: first.range.location)
        let leading = before.allSatisfy(\.isWhitespace) ? first.plan : nil

        var rest = command
        for f in found.reversed() { rest = (rest as NSString).replacingCharacters(in: f.range, with: "") }
        // Tidy the separators the reports were joined with.
        let sep = #"(?:;|&&|\n)"#
        let tidy: [(String, String)] = [
            (#"\s*"# + sep + #"\s*(?:"# + sep + #"\s*)+"#, "; "),   // "a ;  ; b" → "a; b"
            (#"^\s*(?:"# + sep + #"\s*)+"#, ""),                    // leading separator
            (#"(?:\s*"# + sep + #")+\s*$"#, ""),                    // trailing separator
        ]
        for (pat, with) in tidy {
            rest = rest.replacingOccurrences(of: pat, with: with, options: .regularExpression)
        }
        return Scan(leading: leading, last: last.plan,
                    remainder: rest.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func todos(from plan: Plan) -> [TodoItem] {
        plan.steps.enumerated().map { i, name in
            let status: TodoStatus = i < plan.done ? .completed : (i == plan.done ? .inProgress : .pending)
            return TodoItem(id: String(i), content: name, activeForm: name, status: status)
        }
    }
}
