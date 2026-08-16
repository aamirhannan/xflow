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
    private let segmentingRecorder = SegmentingRecorder()

    private var state: SessionState = .idle
    private var assembler = TranscriptAssembler()
    private var segmentTasks: [Task<Void, Never>] = []

    /// Must be retained: releasing the token ends the activity and lets macOS
    /// nap the app again.
    private var activityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.migrateFromV1()
        preventAppNap()
        installEditMenu()
        menuBar.onOpenSettings = { [weak self] in self?.permissionsWindow.show() }

        hotkey.onDown = { [weak self] in self?.handle(.hotkeyDown) }
        hotkey.onUp = { [weak self] in self?.handle(.hotkeyUp) }
        hotkey.start()

        recorder.onLevel = { [weak self] level in self?.pill.update(level: level) }
        recorder.onAutoStop = { [weak self] in self?.handle(.hotkeyUp) }

        segmentingRecorder.onLevel = { [weak self] level in self?.pill.update(level: level) }
        segmentingRecorder.onAutoStop = { [weak self] in self?.handle(.hotkeyUp) }
        segmentingRecorder.onSegment = { [weak self] url, index in
            self?.transcribeSegment(url, index: index)
        }

        requestNotificationAuthorization()

        Task {
            _ = await Recorder.requestMicrophoneAccess()
            if !Permissions.allGranted || Keychain.openAIKey == nil || Keychain.groqKey == nil {
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

        assembler = TranscriptAssembler()
        segmentTasks.forEach { $0.cancel() }
        segmentTasks.removeAll()

        do {
            if Settings.segmentingEnabled {
                try segmentingRecorder.start()
            } else {
                try recorder.start()
            }
            pill.showRecording()
            menuBar.setRecording(true)
        } catch {
            fail("Microphone unavailable")
        }
    }

    /// Fires as soon as a segment closes, so its round trip overlaps with the
    /// rest of the dictation. Failures are recorded rather than thrown: the
    /// whole-audio fallback in finishSegmentedRecording recovers them.
    private func transcribeSegment(_ url: URL, index: Int) {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
        log.notice("SEGMENT \(index, privacy: .public) closed mid-dictation, \(bytes ?? -1, privacy: .public)B")
        let task = Task { [weak self] in
            guard let self else { return }
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let text = try await transcriber.transcribe(fileURL: url)
                await MainActor.run { self.assembler.store(text, at: index) }
            } catch {
                log.error("segment \(index, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                await MainActor.run { self.assembler.markFailed(at: index) }
            }
        }
        segmentTasks.append(task)
    }

    private func finishRecording() {
        menuBar.setRecording(false)
        if Settings.segmentingEnabled {
            finishSegmentedRecording()
        } else {
            finishSingleShotRecording()
        }
    }

    private func finishSingleShotRecording() {
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

    private func finishSegmentedRecording() {
        guard let result = segmentingRecorder.stop() else {
            state = state.next(on: .failed, now: Date())
            pill.hide()
            return
        }

        guard RecordingPolicy.shouldTranscribe(duration: result.duration) else {
            // An accidental fn tap. No API call, no message, no cost.
            result.tail.map { try? FileManager.default.removeItem(at: $0) }
            state = state.next(on: .failed, now: Date())
            pill.hide()
            return
        }

        let releasedAt = Date()
        log.notice("""
        RELEASE after \(String(format: "%.1f", result.duration), privacy: .public)s, \
        tail index \(result.tailIndex, privacy: .public) \
        (\(result.tailIndex, privacy: .public) segments already sent)
        """)
        pill.showTranscribing()

        Task { [weak self] in
            guard let self else { return }

            // The tail is the only unprocessed audio, which is why the wait no
            // longer grows with how long the user spoke.
            if let tail = result.tail {
                do {
                    let text = try await transcriber.transcribe(fileURL: tail)
                    await MainActor.run { self.assembler.store(text, at: result.tailIndex) }
                } catch {
                    await MainActor.run { self.assembler.markFailed(at: result.tailIndex) }
                }
                try? FileManager.default.removeItem(at: tail)
            }

            // Earlier segments are usually done; this waits only for stragglers.
            for task in self.segmentTasks { _ = await task.value }

            let failures = await MainActor.run { self.assembler.failedIndices }
            var text = await MainActor.run { self.assembler.assembled() }

            if !failures.isEmpty {
                log.notice("\(failures.count, privacy: .public) segments failed, falling back to whole audio")
                if let recovered = await self.wholeAudioFallback() { text = recovered }
            }

            guard !text.isEmpty else {
                await MainActor.run { self.fail("Nothing heard") }
                return
            }

            // The only latency number that matters: fn release to text on screen.
            log.notice("PERCEIVED WAIT \(String(format: "%.2f", Date().timeIntervalSince(releasedAt)), privacy: .public)s")
            await MainActor.run { self.handle(.transcriptReady) }
            let pasted = await Inserter.insert(text)
            await MainActor.run {
                self.pill.hide()
                self.handle(.inserted)
                if !pasted {
                    self.notify("Copied to clipboard — press ⌘V to paste (Accessibility is off)")
                }
            }
        }
    }

    /// Last resort when a segment could not be transcribed: send the entire
    /// recording as one request. Slower, but no words are lost.
    private func wholeAudioFallback() async -> String? {
        guard let url = segmentingRecorder.rebuildFullAudio() else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        return try? await transcriber.transcribe(fileURL: url)
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
