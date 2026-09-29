import AppKit
import SwiftUI

/// Floating Spotlight-style panel hosted outside the normal SwiftUI window scenes.
@MainActor
final class AskPanelController {
    static let shared = AskPanelController()

    private var panel: NSPanel?
    private var monitor: Any?

    private init() {}

    func show() {
        if panel == nil {
            buildPanel()
        }
        guard let panel else { return }

        positionCentered(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        installEscapeMonitor()
    }

    func hide() {
        panel?.orderOut(nil)
        removeEscapeMonitor()
        AppState.shared.isPanelVisible = false
    }

    private func buildPanel() {
        let content = AskPanelView()
            .environmentObject(AppState.shared)

        let hosting = NSHostingView(rootView: content)
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 480)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        panel.delegate = PanelDelegate.shared

        self.panel = panel
    }

    private func positionCentered(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let x = visible.midX - size.width / 2
        let y = visible.midY - size.height / 2 + 80
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape
                AskPanelController.shared.hide()
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

private final class PanelDelegate: NSObject, NSWindowDelegate {
    static let shared = PanelDelegate()

    func windowDidResignKey(_ notification: Notification) {
        // Keep open when clicking into Settings; only hide on explicit Esc / toggle.
    }
}
