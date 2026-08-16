import AppKit
import ApplicationServices
import AVFoundation
import IOKit.hid

enum Permissions {
    // Checked directly rather than via Recorder: PermissionsWindow and Recorder
    // are owned by different workstreams and must not reference each other.
    static var microphone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Required to post the synthetic Cmd-V and to observe keys globally.
    static var accessibility: Bool { AXIsProcessTrusted() }

    /// Some macOS versions require this separately from Accessibility.
    static var inputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static var allGranted: Bool { microphone && accessibility && inputMonitoring }

    static func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// The app's only real window: permission status plus the API key field.
final class PermissionsWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let stack = NSStackView()
    private let keyField = NSSecureTextField()
    private var rows: [(label: String, status: NSTextField, check: () -> Bool)] = []
    private var refreshTimer: Timer?

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "XFlow Setup"
        window.isReleasedWhenClosed = false
        super.init()
        window.delegate = self

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        addPermissionRow("Microphone", pane: "security?Privacy_Microphone") { Permissions.microphone }
        addPermissionRow("Accessibility", pane: "security?Privacy_Accessibility") { Permissions.accessibility }
        addPermissionRow("Input Monitoring", pane: "security?Privacy_ListenEvent") { Permissions.inputMonitoring }
        addManualRow(
            "Set Keyboard > \"Press 🌐 key to\" > Do Nothing",
            pane: "keyboard"
        )

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("OpenAI API key"))

        keyField.placeholderString = "sk-…"
        keyField.stringValue = Keychain.apiKey ?? ""
        keyField.target = self
        keyField.action = #selector(saveKey)
        keyField.widthAnchor.constraint(equalToConstant: 400).isActive = true
        stack.addArrangedSubview(keyField)

        let save = NSButton(title: "Save key", target: self, action: #selector(saveKey))
        stack.addArrangedSubview(save)

        stack.addArrangedSubview(caption("Stored in your macOS Keychain, never on disk."))

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        window.contentView = content
    }

    func show() {
        refresh()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // Grants are made in System Settings, outside this app, so poll while open.
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        for row in rows {
            let granted = row.check()
            row.status.stringValue = granted ? "✅" : "⚠️"
        }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    @objc private func saveKey() {
        let value = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.apiKey = value.isEmpty ? nil : value
    }

    private func addPermissionRow(_ title: String, pane: String, check: @escaping () -> Bool) {
        let status = NSTextField(labelWithString: "⚠️")
        let label = NSTextField(labelWithString: title)
        let button = NSButton(title: "Open Settings", target: self, action: #selector(openPane(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(pane)

        let row = NSStackView(views: [status, label, button])
        row.orientation = .horizontal
        row.spacing = 8
        label.widthAnchor.constraint(equalToConstant: 200).isActive = true

        rows.append((title, status, check))
        stack.addArrangedSubview(row)
    }

    private func addManualRow(_ title: String, pane: String) {
        let label = NSTextField(labelWithString: title)
        let button = NSButton(title: "Open Settings", target: self, action: #selector(openPane(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(pane)

        let row = NSStackView(views: [NSTextField(labelWithString: "•"), label, button])
        row.orientation = .horizontal
        row.spacing = 8
        stack.addArrangedSubview(row)
    }

    @objc private func openPane(_ sender: NSButton) {
        guard let pane = sender.identifier?.rawValue else { return }
        Permissions.openSettings(pane)
    }

    private func heading(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        return field
    }

    private func caption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.widthAnchor.constraint(equalToConstant: 400).isActive = true
        return box
    }
}
