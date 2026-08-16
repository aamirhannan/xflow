import AppKit

final class MenuBarController: NSObject {
    var onOpenSettings: () -> Void = {}

    private let item: NSStatusItem
    private let cleanupMenuItem: NSMenuItem
    private let segmentingMenuItem: NSMenuItem

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

    @objc private func openSettings() {
        onOpenSettings()
    }
}
