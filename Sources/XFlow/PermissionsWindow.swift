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
    private let vocabularyField = NSTextField()
    private let groqField = NSSecureTextField()
    private var rows: [(label: String, status: NSTextField, check: () -> Bool)] = []
    private var refreshTimer: Timer?

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 680),
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
        keyField.stringValue = Keychain.openAIKey ?? ""
        keyField.target = self
        keyField.action = #selector(saveKey)
        keyField.widthAnchor.constraint(equalToConstant: 400).isActive = true
        stack.addArrangedSubview(keyField)

        let save = NSButton(title: "Save key", target: self, action: #selector(saveKey))
        stack.addArrangedSubview(save)

        stack.addArrangedSubview(caption("Stored in your macOS Keychain, never on disk. Get one at console.groq.com/keys"))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("Groq API key"))
        groqField.placeholderString = "gsk_…"
        groqField.stringValue = Keychain.groqKey ?? ""
        groqField.target = self
        groqField.action = #selector(saveGroqKey)
        groqField.widthAnchor.constraint(equalToConstant: 400).isActive = true
        stack.addArrangedSubview(groqField)
        stack.addArrangedSubview(NSButton(title: "Save Groq key", target: self, action: #selector(saveGroqKey)))
        stack.addArrangedSubview(caption(
            "Transcription runs on OpenAI because it is the only model that keeps Hindi and "
            + "English both intact in one sentence. Formatting runs on Groq, which is far faster."
        ))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(heading("Vocabulary"))

        vocabularyField.stringValue = Settings.vocabulary
        vocabularyField.target = self
        vocabularyField.action = #selector(saveVocabulary)
        vocabularyField.widthAnchor.constraint(equalToConstant: 400).isActive = true
        stack.addArrangedSubview(vocabularyField)

        let saveVocab = NSButton(title: "Save vocabulary", target: self, action: #selector(saveVocabulary))
        stack.addArrangedSubview(saveVocab)

        stack.addArrangedSubview(caption(
            "Names and acronyms you say often. This is the biggest accuracy lever in the app: "
            + "without it, RBAC came back as आरबैक and \"risk owner\" as \"response और\"."
        ))

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
        Keychain.openAIKey = value.isEmpty ? nil : value
    }

    @objc private func saveGroqKey() {
        let value = groqField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.groqKey = value.isEmpty ? nil : value
    }

    @objc private func saveVocabulary() {
        Settings.vocabulary = vocabularyField.stringValue
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
