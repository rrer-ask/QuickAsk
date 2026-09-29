import SwiftUI
import AppKit

@main
struct QuickAskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(state)
        } label: {
            Image("MenuBarIcon")
                .renderingMode(.template)
        }

        Settings {
            SettingsView()
                .environmentObject(state)
                .onAppear {
                    AppDelegate.shared?.bringSettingsToFront()
                }
                .onDisappear {
                    AppDelegate.shared?.restoreMenuBarMode()
                }
        }
    }
}

/// Separate view so `@Environment(\.openSettings)` works inside MenuBarExtra.
private struct MenuBarContent: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Ask…") {
            state.showPanel()
        }
        .keyboardShortcut("k")

        Divider()

        if let active = state.activeProfile {
            Text("Active: \(active.name)")
            ForEach(state.profiles) { profile in
                Button {
                    state.setActiveProfile(profile.id)
                } label: {
                    HStack {
                        Text(profile.name)
                        if profile.id == active.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Divider()
        }

        Button("Settings…") {
            AppDelegate.shared?.openSettingsWindow(using: { openSettings() })
        }

        Divider()

        Button("Quit QuickAsk") {
            NSApp.terminate(nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        NSApp.setActivationPolicy(.accessory)
        _ = AppState.shared

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func windowWillClose(_ notification: Notification) {
        // Defer: window is still listed as visible during willClose.
        DispatchQueue.main.async { [weak self] in
            self?.restoreMenuBarMode()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.restoreMenuBarMode()
        }
    }

    /// Switch out of accessory mode so Settings can become key / appear on-screen.
    func prepareForSettings() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Hide Dock icon again once Settings (and other normal windows) are gone.
    func restoreMenuBarMode() {
        if hasVisibleNormalWindow() { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private func hasVisibleNormalWindow() -> Bool {
        NSApp.windows.contains { window in
            if window is NSPanel { return false }
            if !window.isVisible { return false }
            if window.frame.width < 280 || window.frame.height < 200 { return false }
            if window.contentView == nil { return false }
            return true
        }
    }

    /// Opens Settings via SwiftUI's `openSettings`. Must defer until MenuBarExtra menu dismisses.
    func openSettingsWindow(using openSettings: @escaping () -> Void) {
        prepareForSettings()
        DispatchQueue.main.async {
            openSettings()
            self.bringSettingsToFront()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.bringSettingsToFront()
        }
    }

    /// Fallback for callers without Environment (e.g. older hooks).
    func openSettingsWindow() {
        prepareForSettings()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        DispatchQueue.main.async { self.bringSettingsToFront() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.bringSettingsToFront() }
    }

    func bringSettingsToFront() {
        NSApp.activate(ignoringOtherApps: true)

        let candidates = NSApp.windows.filter { window in
            // Ask panel is NSPanel — skip it.
            if window is NSPanel { return false }
            // Status-item / invisible chrome.
            if window.frame.width < 280 || window.frame.height < 200 { return false }
            if window.contentView == nil { return false }
            return true
        }

        for window in candidates {
            window.collectionBehavior.insert(.moveToActiveSpace)
            // Never keep Settings at .floating — that left it off-space / invisible.
            if window.level > .normal {
                window.level = .normal
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}
