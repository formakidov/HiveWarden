import AppKit
import SwiftUI
import ServiceManagement
import ClaudeWorkersCore

/// Non-activating so clicking Allow never steals focus from what you're typing.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }   // needed for the rename text field
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AppModel()
    private var server: HookServer!
    private var panel: FloatingPanel!
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var topLeft: NSPoint?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.hidePanel = { [weak self] in self?.panel.orderOut(nil) }

        server = HookServer(store: model.store, token: AppPaths.loadOrCreateToken())
        server.onJump = { [weak self] id in
            guard let s = self?.model.store.session(id: id) else { return false }
            return TerminalJumper.jump(to: s)
        }
        server.onSnapshot = { [weak self] q in self?.snapshot(q) }
        do { try server.start() } catch { NSLog("HiveWarden: cannot start server: \(error)") }
        if model.hooksInstalled { try? HookInstaller.writeScript() }   // keep shim current

        buildPanel()
        buildStatusItem()

        // Surface the panel whenever an agent needs you, even if you closed it.
        let previous = model.store.onAttention
        model.store.onAttention = { [weak self] s in
            previous?(s)
            self?.showPanel()
        }

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }

        // `kill`/Ctrl-C skip applicationWillTerminate; route them through a normal quit
        // so the port file is removed and the shim stops trying a dead port.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
    }

    func applicationWillTerminate(_ notification: Notification) { server.stop() }

    // MARK: Panel

    private func buildPanel() {
        let host = NSHostingController(rootView: PanelView(model: model))
        host.sizingOptions = [.preferredContentSize]
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor

        let p = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: Theme.width, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        p.contentViewController = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel = p

        if let saved = UserDefaults.standard.string(forKey: "panelTopLeft") {
            topLeft = NSPointFromString(saved)
        }

        // Keep the top edge pinned while the panel grows/shrinks with its content.
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let tl = self.topLeft else { return }
                self.panel.setFrameTopLeftPoint(tl)
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let f = self.panel.frame
                self.topLeft = NSPoint(x: f.minX, y: f.maxY)
                UserDefaults.standard.set(NSStringFromPoint(self.topLeft!), forKey: "panelTopLeft")
            }
        }
        showPanel()
    }

    func showPanel() {
        let tl = onScreen(topLeft)
        topLeft = tl
        panel.setFrameTopLeftPoint(tl)
        panel.orderFrontRegardless()
    }

    /// The saved position if its header strip is still reachable on some display
    /// (monitors get unplugged); otherwise the top-right corner of the main screen.
    private func onScreen(_ p: NSPoint?) -> NSPoint {
        if let p {
            let header = NSRect(x: p.x, y: p.y - 44, width: Theme.width, height: 44)
            for screen in NSScreen.screens {
                let hit = screen.visibleFrame.intersection(header)
                if hit.width >= 120, hit.height >= 30 { return p }
            }
        }
        let f = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: f.maxX - Theme.width - 18, y: f.maxY - 14)
    }

    private func togglePanel() {
        if panel.isVisible { panel.orderOut(nil) } else { showPanel() }
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshStatusItem()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        model.refreshHooksState()
        menu.removeAllItems()
        func add(_ title: String, _ sel: Selector, on: Bool = false) {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            i.state = on ? .on : .off
            menu.addItem(i)
        }
        add(panel.isVisible ? "Hide panel" : "Show panel", #selector(menuToggle))
        add("Alert sound", #selector(menuSound), on: model.soundEnabled)
        add("Ask agents to report their plan", #selector(menuPlan), on: model.planReporting)
        menu.addItem(.separator())
        if model.hooksInstalled {
            add("Reinstall Claude Code hooks", #selector(menuInstall))
            add("Remove Claude Code hooks", #selector(menuUninstall))
        } else {
            add("Install Claude Code hooks…", #selector(menuInstall))
        }
        add("Show event log", #selector(menuLog))
        add("Launch at login", #selector(menuLogin), on: SMAppService.mainApp.status == .enabled)
        menu.addItem(.separator())
        add("Quit \(AppInfo.name)", #selector(menuQuit))
    }

    @objc private func menuToggle() { togglePanel() }
    @objc private func menuSound() { model.soundEnabled.toggle() }
    @objc private func menuPlan() { model.planReporting.toggle() }
    @objc private func menuInstall() { model.installHooks(); showPanel(); reportInstallError() }
    @objc private func menuUninstall() { model.uninstallHooks(); reportInstallError() }

    private func reportInstallError() {
        guard let message = model.installError else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't update Claude Code hooks"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    @objc private func menuLog() { NSWorkspace.shared.open(AppPaths.eventLog) }
    @objc private func menuQuit() { NSApp.terminate(nil) }
    @objc private func menuLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSLog("HiveWarden: login item: \(error)") }
    }

    private func refreshStatusItem() {
        let store = model.store
        let n = store.visibleSessions.count
        let attention = store.attentionCount
        let name = attention > 0 ? "exclamationmark.bubble.fill" : (store.workingCount > 0 ? "person.3.sequence.fill" : "person.3.sequence")
        let img = NSImage(systemSymbolName: name, accessibilityDescription: AppInfo.name)
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.title = n > 0 ? " \(attention > 0 ? "\(attention)/" : "")\(n)" : ""
    }

    private func snapshot(_ query: [String: String]) {
        // Dev aids: ?select=<session id> opens its detail view, ?select= (empty) goes back.
        if let sel = query["select"] { model.selectedID = sel.isEmpty ? nil : sel }
        if let c = query["collapsed"] { model.collapsed = (c == "1") }
        if let e = query["expand"] { model.expandedNext = e.isEmpty ? [] : [e] }
        // Let SwiftUI apply the state change before we render.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let v = self?.panel.contentView,
                  let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: AppPaths.dir.appendingPathComponent("snapshot.png"))
        }
    }

    private func tick() {
        model.store.prune()
        refreshStatusItem()
    }
}
