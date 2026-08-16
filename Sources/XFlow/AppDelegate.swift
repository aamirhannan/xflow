import AppKit
import Carbon.HIToolbox
import OSLog
import UserNotifications
import XFlowCore

private let log = Logger(subsystem: "com.aamirhannan.xflow", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotkey = HotkeyMonitor()
    private let recorder = Recorder()
    private let pill = OverlayPill()
    private let menuBar = MenuBarController()
    private let permissionsWindow = PermissionsWindow()
    private let transcriber = Transcriber()

    private var state: SessionState = .idle

    /// Must be retained: releasing the token ends the activity and lets macOS
    /// nap the app again.
    private var activityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        preventAppNap()
        installEditMenu()
        menuBar.onOpenSettings = { [weak self] in self?.permissionsWindow.show() }

        hotkey.onDown = { [weak self] in self?.handle(.hotkeyDown) }
        hotkey.onUp = { [weak self] in self?.handle(.hotkeyUp) }
        hotkey.start()

        recorder.onLevel = { [weak self] level in self?.pill.update(level: level) }
        recorder.onAutoStop = { [weak self] in self?.handle(.hotkeyUp) }

        requestNotificationAuthorization()

        Task {
            _ = await Recorder.requestMicrophoneAccess()
            if !Permissions.allGranted || Keychain.apiKey == nil {
                await MainActor.run { self.permissionsWindow.show() }
            }
        }
    }

    /// A menu-bar app with no visible window is the textbook App Nap target, and
    /// a napped process gets its timers coalesced and its network work deferred —
    /// which is indistinguishable from a hang. A push-to-talk tool has to answer
    /// a keypress instantly, so it must never be napped.
    ///
    /// `.userInitiatedAllowingIdleSystemSleep` prevents App Nap but still lets
    /// the Mac itself sleep normally.
    ///
    /// ponytail: held for the whole app lifetime rather than scoped to a
    /// dictation. Scoping it to hotkey-down through paste would be tighter, but
    /// this app runs no timers while idle, so App Nap saves almost nothing here
    /// and the lifecycle would be one more thing to get wrong. Scope it if
    /// battery measurements ever say otherwise.
    private func preventAppNap() {
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "XFlow must respond to the fn key without delay"
        )
        log.notice("app nap prevented")
    }

    /// An accessory app gets no main menu, and macOS dispatches Cmd-X/C/V/A and
    /// Cmd-Z through the main menu before anything else sees them. Without this,
    /// paste silently does nothing in every text field the app will ever have —
    /// which makes an API key field unusable, since nobody types a key by hand.
    private func installEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editItem = NSMenuItem()
        editItem.submenu = edit

        let mainMenu = NSMenu()
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    // MARK: - State machine

    private func handle(_ event: SessionEvent) {
        let previous = state
        state = state.next(on: event, now: Date())
        guard state != previous else { return }

        switch (previous, state) {
        case (.idle, .recording):         startRecording()
        case (.recording, .transcribing): finishRecording()
        case (_, .idle):                  menuBar.setRecording(false)
        default:                          break
        }
    }

    private func fail(_ message: String) {
        pill.showMessage(message)
        menuBar.setRecording(false)
        state = state.next(on: .failed, now: Date())
    }

    // MARK: - Steps

    private func startRecording() {
        // Password fields turn on Secure Event Input, which blocks both key
        // monitoring and paste. Refuse visibly rather than record into a void.
        guard !IsSecureEventInputEnabled() else {
            fail("Can't dictate into a password field")
            return
        }

        do {
            try recorder.start()
            pill.showRecording()
            menuBar.setRecording(true)
        } catch {
            fail("Microphone unavailable")
        }
    }

    private func finishRecording() {
        menuBar.setRecording(false)

        guard let clip = recorder.stop() else {
            state = state.next(on: .failed, now: Date())
            pill.hide()
            return
        }

        guard RecordingPolicy.shouldTranscribe(duration: clip.duration) else {
            // An accidental fn tap. No API call, no message, no cost.
            try? FileManager.default.removeItem(at: clip.url)
            state = state.next(on: .failed, now: Date())
            pill.hide()
            return
        }

        pill.showTranscribing()

        Task { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: clip.url) }

            do {
                let text = try await transcriber.transcribe(fileURL: clip.url)
                await MainActor.run { self.handle(.transcriptReady) }

                let pasted = await Inserter.insert(text)
                await MainActor.run {
                    self.pill.hide()
                    self.handle(.inserted)
                    if !pasted {
                        self.notify("Copied to clipboard — press ⌘V to paste (Accessibility is off)")
                    }
                }
            } catch let error as XFlowError {
                await MainActor.run {
                    self.fail(error.userMessage)
                    if error == .noAPIKey || error == .invalidKey {
                        self.permissionsWindow.show()
                    }
                }
            } catch {
                await MainActor.run { self.fail("Transcription failed") }
            }
        }
    }

    // MARK: - Notifications

    // UNUserNotificationCenter traps when the process has no bundle, which is
    // what `swift run XFlow` produces. Always launch the built .app instead.
    private var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    private func requestNotificationAuthorization() {
        guard isBundled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func notify(_ body: String) {
        guard isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = "XFlow"
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
