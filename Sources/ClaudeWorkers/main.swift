import AppKit
import ClaudeWorkersCore

// Command-line helpers (no UI). The binary lives at HiveWarden.app/Contents/MacOS/HiveWarden.
//   --install-hooks     add the hooks to ~/.claude/settings.json (same as the panel button)
//   --uninstall-hooks   remove them again
//   --write-shim        just (re)write the hook shim script
let args = CommandLine.arguments.dropFirst()
if let flag = args.first(where: { ["--install-hooks", "--uninstall-hooks", "--write-shim"].contains($0) }) {
    do {
        switch flag {
        case "--install-hooks":
            try HookInstaller.install()
            print("Hooks installed in \(AppPaths.claudeSettings.path)")
        case "--uninstall-hooks":
            try HookInstaller.uninstall()
            print("Hooks removed from \(AppPaths.claudeSettings.path)")
        default:
            try HookInstaller.writeScript()
            print(AppPaths.script.path)
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("\(AppInfo.name): \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
