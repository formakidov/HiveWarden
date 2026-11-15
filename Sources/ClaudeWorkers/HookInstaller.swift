import Foundation
import Security
import ClaudeWorkersCore

enum AppPaths {
    static let dir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HiveWarden", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return d
    }()
    static var script: URL { dir.appendingPathComponent("hivewarden-hook.sh") }
    static var portFile: URL { dir.appendingPathComponent("port") }
    static var tokenFile: URL { dir.appendingPathComponent("token") }
    static var claudeSettings: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }
    static var backup: URL { claudeSettings.deletingLastPathComponent().appendingPathComponent("settings.json.hivewarden-backup") }

    static var eventLog: URL { dir.appendingPathComponent("events.log") }

    /// Append-only diagnostics (capped ~512 KB): what the app received and decided.
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func log(_ line: String) {
        let data = Data("\(stamp.string(from: Date())) \(line)\n".utf8)
        if let h = try? FileHandle(forWritingTo: eventLog) {
            defer { try? h.close() }
            if let size = try? h.seekToEnd(), size > 512_000 {
                try? h.truncate(atOffset: 0)
            }
            try? h.write(contentsOf: data)
        } else {
            FileManager.default.createFile(atPath: eventLog.path, contents: data)
        }
    }

    static func writePort(_ p: UInt16) {
        try? "\(p)".write(to: portFile, atomically: true, encoding: .utf8)
    }
    static func removePort() { try? FileManager.default.removeItem(at: portFile) }

    /// 256-bit random token, created once, mode 0600.
    static func loadOrCreateToken() -> String {
        if let t = try? String(contentsOf: tokenFile, encoding: .utf8), t.count >= 32 { return t }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        FileManager.default.createFile(atPath: tokenFile.path, contents: Data(t.utf8),
                                       attributes: [.posixPermissions: 0o600])
        return t
    }
}

enum HookInstaller {
    /// Fails open: no app → no port file / refused connection → silent exit 0.
    static let scriptText = #"""
    #!/bin/bash
    # HiveWarden hook shim. Forwards Claude Code hook JSON to the HiveWarden app and
    # prints the app's reply (a permission decision / question answer) on stdout.
    # If the app isn't running this exits 0 silently and Claude carries on as normal.
    DIR="$HOME/Library/Application Support/HiveWarden"
    [ -r "$DIR/port" ] && [ -r "$DIR/token" ] || exit 0
    PORT=$(<"$DIR/port"); TOKEN=$(<"$DIR/token")
    INPUT=$(cat)
    # Only permission requests and questions wait for you. Everything else is capped at
    # 5 s, so a hung app can never stall Claude's tool calls.
    MAX=5
    case "$INPUT" in
      *'"hook_event_name":"PermissionRequest"'*|*'"hook_event_name": "PermissionRequest"'*) MAX=590 ;;
      *'"tool_name":"AskUserQuestion"'*|*'"tool_name": "AskUserQuestion"'*) MAX=590 ;;
    esac
    TTY=$(ps -o tty= -p "$PPID" 2>/dev/null | tr -d ' ')
    printf '%s' "$INPUT" | curl -sf --connect-timeout 1 --max-time "$MAX" -X POST \
      -H "X-HiveWarden-Token: $TOKEN" --data-binary @- \
      "http://127.0.0.1:$PORT/event?ppid=$PPID&tty=$TTY" 2>/dev/null
    exit 0
    """#.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.hasPrefix("    ") ? String($0.dropFirst(4)) : String($0) }
        .joined(separator: "\n") + "\n"

    static let command = "\"$HOME/Library/Application Support/HiveWarden/hivewarden-hook.sh\""

    static func writeScript() throws {
        try scriptText.write(to: AppPaths.script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: AppPaths.script.path)
    }

    /// Throws if the file exists but isn't a JSON object. Never treat that as "empty".
    static func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: AppPaths.claudeSettings.path) else { return [:] }
        return try SettingsMerger.parse(Data(contentsOf: AppPaths.claudeSettings))
    }

    static var isInstalled: Bool {
        (try? readSettings()).map(SettingsMerger.isInstalled) ?? false
    }

    private static func write(_ settings: [String: Any]) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: AppPaths.claudeSettings.deletingLastPathComponent(), withIntermediateDirectories: true)
        // One-time copy of the file as it was before we first touched it.
        if fm.fileExists(atPath: AppPaths.claudeSettings.path), !fm.fileExists(atPath: AppPaths.backup.path) {
            try fm.copyItem(at: AppPaths.claudeSettings, to: AppPaths.backup)
        }
        let data = try JSONSerialization.data(withJSONObject: settings,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        // Non-atomic so a symlinked settings.json (dotfiles repos) stays a symlink.
        try data.write(to: AppPaths.claudeSettings)
    }

    static func install() throws {
        let current = try readSettings()          // refuse before touching anything
        try writeScript()
        try write(SettingsMerger.install(into: current, command: command))
    }

    static func uninstall() throws {
        guard FileManager.default.fileExists(atPath: AppPaths.claudeSettings.path) else { return }
        try write(SettingsMerger.remove(from: readSettings()))
    }
}
