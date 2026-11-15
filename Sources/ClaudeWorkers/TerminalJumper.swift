import AppKit
import ClaudeWorkersCore

/// Brings the terminal / editor that owns a session to the front.
@MainActor
enum TerminalJumper {
    static let vscodeFamily: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf", "com.vscodium",
    ]

    @discardableResult
    static func jump(to s: AgentSession) -> Bool {
        guard let pid = s.agentPID ?? s.ppid else {
            AppPaths.log("jump \(s.title): no pid known"); NSSound.beep(); return false
        }
        guard let app = owningApp(of: pid) else {
            AppPaths.log("jump \(s.title): no GUI app owns pid \(pid)"); NSSound.beep(); return false
        }
        let bundle = app.bundleIdentifier ?? ""
        let tty = devicePath(s.tty)
        AppPaths.log("jump \(s.title) → \(bundle) pid=\(pid) tty=\(tty ?? "-")")

        switch bundle {
        case "com.apple.Terminal":
            selectTab(script: tty.map(terminalScript), then: app)
        case "com.googlecode.iterm2":
            selectTab(script: tty.map(itermScript), then: app)
        case _ where vscodeFamily.contains(bundle):
            // Re-opening the folder raises the window that already has it.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-b", bundle, s.cwd]
            try? p.run()
        default:
            activate(app)
        }
        return true
    }

    /// "ttys006" → "/dev/ttys006". The value arrives over HTTP and ends up inside
    /// AppleScript source, so accept nothing but a plain device name.
    static func devicePath(_ tty: String?) -> String? {
        guard var t = tty else { return nil }
        if t.hasPrefix("/dev/") { t.removeFirst(5) }
        guard !t.isEmpty, t.count <= 16, t.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return "/dev/" + t
    }

    /// Walk up the process tree to the first regular GUI app.
    static func owningApp(of pid: Int32) -> NSRunningApplication? {
        var p = pid
        for _ in 0..<20 {
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy == .regular { return app }
            guard let parent = ProcessTree.parent(of: p), parent > 1 else { return nil }
            p = parent
        }
        return nil
    }

    /// `NSRunningApplication.activate()` is ignored when we're not the frontmost app
    /// (we're a non-activating panel), so go through LaunchServices instead.
    private static func activate(_ app: NSRunningApplication) {
        if let url = app.bundleURL {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, err in
                if let err { AppPaths.log("activate failed: \(err.localizedDescription)") }
            }
        } else {
            app.activate(options: [.activateAllWindows])
        }
    }

    /// Runs the tab-selection script in an `osascript` child, then activates the app.
    /// Out of process on purpose: the first run shows macOS's Automation consent
    /// dialog, and an in-process NSAppleScript would freeze our main thread (and with
    /// it the hook server) until that is answered.
    private static func selectTab(script: String?, then app: NSRunningApplication) {
        guard let script else { return activate(app) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                if proc.terminationStatus != 0 {
                    AppPaths.log("tab select failed (\(proc.terminationStatus)): \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
                activate(app)   // still bring the app forward even if the tab couldn't be chosen
            }
        }
        do { try p.run() } catch {
            AppPaths.log("osascript failed to start: \(error.localizedDescription)")
            activate(app)
        }
    }

    private static func terminalScript(tty: String) -> String {
        """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(tty)" then
                set selected of t to true
                set index of w to 1
                return "ok"
              end if
            end repeat
          end repeat
        end tell
        error "no Terminal tab on \(tty)"
        """
    }

    private static func itermScript(tty: String) -> String {
        """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "\(tty)" then
                  tell w to select t
                  select s
                  return "ok"
                end if
              end repeat
            end repeat
          end repeat
        end tell
        error "no iTerm2 session on \(tty)"
        """
    }
}
