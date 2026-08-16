import AppKit
import SwiftUI
import XFlowCore

/// The app's only window. AppKit owns the frame; everything inside is SwiftUI.
///
/// It replaces the old setup window, which was 210 lines of hand-rolled
/// NSStackView for a form. The deployment target is macOS 14, so there is no
/// reason to keep laying out views by hand.
final class MainWindow: NSObject {
    private let window: NSWindow
    private let store: HistoryStore

    init(store: HistoryStore) {
        self.store = store
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "XFlow"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 480)
        window.setFrameAutosaveName("XFlowMainWindow")
        window.contentView = NSHostingView(rootView: SettingsView(store: store))
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showSettings() { show() }
}
