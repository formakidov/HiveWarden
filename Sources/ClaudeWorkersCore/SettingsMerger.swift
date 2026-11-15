import Foundation

/// Pure functions that add/remove our hook entries in a Claude Code settings dict.
/// Entries are identified by `marker` appearing in the hook command, so we never
/// touch anyone else's hooks.
public enum SettingsMerger {
    public static let marker = "HiveWarden/hivewarden-hook.sh"

    /// (event, timeout seconds). Blocking events get a long timeout.
    public static let events: [(String, Int)] = [
        ("SessionStart", 10),
        ("SessionEnd", 10),
        ("UserPromptSubmit", 10),
        ("PreToolUse", 600),       // AskUserQuestion blocks here
        ("PostToolUse", 10),
        ("PermissionRequest", 600),
        ("Notification", 10),
        ("PreCompact", 10),
        ("Stop", 10),
    ]

    public struct NotAnObject: LocalizedError {
        public var errorDescription: String? {
            "~/.claude/settings.json isn't valid JSON, so nothing was changed. Fix or remove it, then try again."
        }
    }

    /// Decode a settings file. Empty/whitespace = no settings yet. Anything that isn't a
    /// JSON object throws, so we never overwrite a file we couldn't understand.
    public static func parse(_ data: Data) throws -> [String: Any] {
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) { return [:] }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NotAnObject()
        }
        return obj
    }

    public static func isInstalled(_ settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { ev, _ in
            (hooks[ev] as? [[String: Any]] ?? []).contains(where: isOurs)
        }
    }

    public static func install(into settings: [String: Any], command: String) -> [String: Any] {
        var out = remove(from: settings)
        var hooks = out["hooks"] as? [String: Any] ?? [:]
        for (ev, timeout) in events {
            var arr = hooks[ev] as? [[String: Any]] ?? []
            arr.append(["hooks": [["type": "command", "command": command, "timeout": timeout]]])
            hooks[ev] = arr
        }
        out["hooks"] = hooks
        return out
    }

    public static func remove(from settings: [String: Any]) -> [String: Any] {
        var out = settings
        guard var hooks = out["hooks"] as? [String: Any] else { return out }
        for (ev, value) in hooks {
            guard let arr = value as? [[String: Any]] else { continue }
            let kept: [[String: Any]] = arr.compactMap { group in
                guard var inner = group["hooks"] as? [[String: Any]] else { return group }
                inner.removeAll { ($0["command"] as? String)?.contains(marker) == true }
                if inner.isEmpty { return nil }
                var g = group
                g["hooks"] = inner
                return g
            }
            if kept.isEmpty { hooks.removeValue(forKey: ev) } else { hooks[ev] = kept }
        }
        if hooks.isEmpty { out.removeValue(forKey: "hooks") } else { out["hooks"] = hooks }
        return out
    }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains {
            ($0["command"] as? String)?.contains(marker) == true
        }
    }
}
