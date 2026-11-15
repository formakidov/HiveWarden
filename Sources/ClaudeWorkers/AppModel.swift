import AppKit
import SwiftUI
import Observation
import ClaudeWorkersCore

@MainActor @Observable
final class AppModel {
    let store = SessionStore()
    var collapsed = false
    var selectedID: String?
    /// Sessions whose "Next" list is expanded in the list view.
    var expandedNext: Set<String> = []
    var hooksInstalled = HookInstaller.isInstalled
    var installError: String?
    var soundEnabled: Bool = UserDefaults.standard.object(forKey: "soundEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(soundEnabled, forKey: "soundEnabled") }
    }

    /// Ask agents to announce their plan (for Claude builds without a todo tool).
    /// On unless the user has switched it off in the menu.
    var planReporting: Bool = UserDefaults.standard.object(forKey: "planReporting") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(planReporting, forKey: "planReporting")
            store.planReporting = planReporting
        }
    }

    @ObservationIgnored var hidePanel: () -> Void = {}

    init() {
        store.onAttention = { [weak self] _ in self?.attentionSound() }
        store.planReporting = planReporting
    }

    func jump(_ s: AgentSession) { TerminalJumper.jump(to: s) }

    func installHooks() {
        do {
            try HookInstaller.install()
            hooksInstalled = true
            installError = nil
        } catch {
            installError = error.localizedDescription
        }
    }

    func uninstallHooks() {
        do {
            try HookInstaller.uninstall()
            hooksInstalled = false
            installError = nil
        } catch {
            installError = error.localizedDescription
        }
    }

    func refreshHooksState() { hooksInstalled = HookInstaller.isInstalled }

    private func attentionSound() {
        guard soundEnabled else { return }
        NSSound(named: "Glass")?.play()
    }
}

extension AgentSession {
    var mood: MascotView.Mood {
        if needsAttention { return .attention }
        return state == .working ? .working : .happy
    }
    var color: Color { Color(hex: Palette.color(slot: colorSlot)) }
}
