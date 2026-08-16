import AppKit

final class MenuBarController: NSObject {
    var onOpenSettings: () -> Void = {}
    var onOpenWindow: () -> Void = {}

    private let item: NSStatusItem
    private let cleanupMenuItem: NSMenuItem
    private let segmentingMenuItem: NSMenuItem
    private let historyMenuItem: NSMenuItem

    override init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        cleanupMenuItem = NSMenuItem(
            title: "Clean up transcripts",
            action: #selector(toggleCleanup),
            keyEquivalent: ""
        )
        segmentingMenuItem = NSMenuItem(
            title: "Transcribe while speaking",
            action: #selector(toggleSegmenting),
            keyEquivalent: ""
        )
        historyMenuItem = NSMenuItem(
            title: "Save history",
            action: #selector(toggleHistory),
            keyEquivalent: ""
        )
        super.init()

        setRecording(false)

        let menu = NSMenu()
        menu.addItem(withTitle: "Hold fn to dictate", action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        cleanupMenuItem.target = self
        cleanupMenuItem.state = Settings.cleanupEnabled ? .on : .off
        menu.addItem(cleanupMenuItem)

        segmentingMenuItem.target = self
        segmentingMenuItem.state = Settings.segmentingEnabled ? .on : .off
        menu.addItem(segmentingMenuItem)

        historyMenuItem.target = self
        historyMenuItem.state = Settings.historyEnabled ? .on : .off
        menu.addItem(historyMenuItem)

        let openWindow = NSMenuItem(title: "Open XFlow", action: #selector(openWindow), keyEquivalent: "0")
        openWindow.target = self
        menu.addItem(openWindow)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit XFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.menu = menu
    }

    func setRecording(_ isRecording: Bool) {
        let symbol = isRecording ? "mic.fill" : "mic"
        item.button?.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: isRecording ? "XFlow recording" : "XFlow idle"
        )
        item.button?.contentTintColor = isRecording ? .systemRed : nil
    }

    @objc private func toggleCleanup() {
        Settings.cleanupEnabled.toggle()
        cleanupMenuItem.state = Settings.cleanupEnabled ? .on : .off
    }

    @objc private func toggleSegmenting() {
        Settings.segmentingEnabled.toggle()
        segmentingMenuItem.state = Settings.segmentingEnabled ? .on : .off
    }

    @objc private func toggleHistory() {
        Settings.historyEnabled.toggle()
        historyMenuItem.state = Settings.historyEnabled ? .on : .off
    }

    @objc private func openWindow() {
        onOpenWindow()
    }

    @objc private func openSettings() {
        onOpenSettings()
    }
}
