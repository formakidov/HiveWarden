import Foundation

/// A decoded Claude Code hook payload. We keep the raw dictionary because the
/// shape varies per event/tool and we only read a handful of keys.
public struct HookEvent {
    public let raw: [String: Any]

    public init(raw: [String: Any]) { self.raw = raw }

    public init?(data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["session_id"] is String else { return nil }
        self.raw = obj
    }

    public var name: String { raw["hook_event_name"] as? String ?? "" }
    public var sessionID: String { raw["session_id"] as? String ?? "" }
    public var cwd: String? { raw["cwd"] as? String }
    public var toolName: String? { raw["tool_name"] as? String }
    public var toolInput: [String: Any] { raw["tool_input"] as? [String: Any] ?? [:] }
    public var toolResponse: Any? { raw["tool_response"] }
    public var toolUseID: String? { raw["tool_use_id"] as? String }
    public var prompt: String? { raw["prompt"] as? String }
    public var message: String? { raw["message"] as? String }
    public var notificationType: String? { raw["notification_type"] as? String }
    public var lastAssistantMessage: String? { raw["last_assistant_message"] as? String }
    public var source: String? { raw["source"] as? String }
}

/// Extra facts the hook shim adds (it knows its own parent process).
public struct HookMeta {
    public var ppid: Int32?
    public var tty: String?
    public init(ppid: Int32? = nil, tty: String? = nil) {
        self.ppid = ppid
        self.tty = tty
    }
}

/// Lets the transport tell the store "the client hung up" (e.g. the user answered
/// in the terminal and Claude killed the hook).
public final class RequestHandle {
    public var onCancel: (() -> Void)?
    public init() {}
    public func cancel() {
        let f = onCancel
        onCancel = nil
        f?()
    }
}

/// JSON the hook shim prints back to Claude Code.
public enum HookReply {
    public static func permission(_ choice: PermissionChoice) -> String {
        switch choice {
        case .passthrough, .terminal: return ""   // Claude falls back to its own dialog
        case .allow:
            return json(["hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "allow"],
            ]])
        case .deny:
            return json(["hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "deny", "message": "Denied by the user from \(AppInfo.name)."],
            ]])
        }
    }

    /// Answer `AskUserQuestion` programmatically: allow the tool with `updatedInput`
    /// carrying the original `questions` plus an `answers` map keyed by question text
    /// (documented in the Claude Code hooks reference). nil = no opinion.
    public static func question(questions: Any?, answers: [String: String]?) -> String {
        guard let answers, let questions else { return "" }
        return json(["hookSpecificOutput": [
            "hookEventName": "PreToolUse",
            "permissionDecision": "allow",
            "updatedInput": ["questions": questions, "answers": answers],
        ]])
    }

    /// Compact JSON for diagnostics.
    public static func compact(_ obj: Any) -> String { json(obj) }

    static func json(_ obj: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]),
              let s = String(data: d, encoding: .utf8) else { return "" }
        return s
    }
}
