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
    private var host: NSHostingController<PanelView>!
    /// Height the window is currently animating to (nil when idle), and a counter so only
    /// the latest animation's completion runs.
    private var fitTarget: CGFloat?
    private var fitGeneration = 0
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var topLeft: NSPoint?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.hidePanel = { [weak self] in self?.panel.orderOut(nil) }
        model.panelWindow = { [weak self] in self?.panel }

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

    /// Clicking the Dock icon (or opening the app again) brings the panel back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    // MARK: Panel

    private func buildPanel() {
        let host = NSHostingController(rootView: PanelView(model: model))
        host.sizingOptions = []   // the window follows model.contentHeight instead
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        self.host = host

        // The hosting view sits in a plain container instead of being the window's content
        // view controller, so the window no longer snaps to the SwiftUI size; fitPanel()
        // animates it instead. The view is pinned to the container's top edge, and the
        // container clips to the panel's rounded shape while the window resizes.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: Theme.width, height: 200))
        container.wantsLayer = true
        container.layer?.cornerRadius = 20
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        host.view.frame = container.bounds
        host.view.autoresizingMask = [.width, .minYMargin]
        container.addSubview(host.view)

        let p = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: Theme.width, height: 200),
                            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        p.contentView = container
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

        // Follow the content's measured height (and collapse/expand), animated, top edge
        // fixed. (KVO on the hosting controller's preferredContentSize missed changes.)
        model.onCollapseChange = { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.fitPanel(animated: true) } }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let f = self.panel.frame
                self.topLeft = NSPoint(x: f.minX, y: f.maxY)
                UserDefaults.standard.set(NSStringFromPoint(self.topLeft!), forKey: "panelTopLeft")
            }
        }
        fitPanel(animated: false)
        showPanel()
    }

    /// Sizes the window to the panel: the header alone when collapsed, otherwise the
    /// SwiftUI content's preferred height. The top edge stays where it is. When animated,
    /// the hosting view is held at the larger of the two heights (pinned to the top) so the
    /// window's bottom edge slides over the content rather than the content re-laying out.
    private func fitPanel(animated: Bool) {
        guard let panel, let host else { return }
        if model.collapsed, model.headerHeight < 1 { return }   // header not measured yet
        let want = model.collapsed ? model.headerHeight + 4 : model.contentHeight
        guard want > 1 else { return }
        let h = ceil(want)
        // Already animating to this height: let that animation finish undisturbed.
        if let t = fitTarget, abs(t - h) < 0.5 { return }
        let cur = panel.frame
        if fitTarget == nil, abs(cur.height - h) < 0.5 {
            if model.collapsed { model.showContent = false }
            return
        }
        let target = NSRect(x: cur.minX, y: cur.maxY - h, width: Theme.width, height: h)
        fitGeneration += 1
        let generation = fitGeneration
        guard animated, panel.isVisible else {
            fitTarget = nil
            panel.setFrame(target, display: true)
            host.view.frame = panel.contentView?.bounds ?? .zero
            if model.collapsed { model.showContent = false }
            return
        }
        fitTarget = h
        let hostH = max(h, cur.height)
        host.view.frame = NSRect(x: 0, y: cur.height - hostH, width: Theme.width, height: hostH)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // A newer animation replaced this one: its own completion does the cleanup.
                // (Running this early snapped the content view back to the old height
                // mid-expand, so the panel looked like it jumped at the end.)
                guard let self, generation == self.fitGeneration, let panel = self.panel else { return }
                self.fitTarget = nil
                self.host?.view.frame = panel.contentView?.bounds ?? .zero
                if self.model.collapsed { self.model.showContent = false }
                panel.invalidateShadow()
                self.fitPanel(animated: true)   // catch any size change that came in meanwhile
            }
        })
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
        let state: MenuBarIcon.State = attention > 0 ? .attention : (store.workingCount > 0 ? .working : .idle)
        statusItem.button?.image = MenuBarIcon.image(state)
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
