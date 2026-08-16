import AppKit
import SwiftUI
import XFlowCore

/// Everything the old hand-rolled setup window did, plus the toggles that used
/// to live only in the menu bar and the destructive history control.
struct SettingsView: View {
    let store: HistoryStore
    let onRerunSetup: () -> Void

    init(store: HistoryStore, onRerunSetup: @escaping () -> Void = {}) {
        self.store = store
        self.onRerunSetup = onRerunSetup
    }

    @State private var openAIKey = Keychain.openAIKey ?? ""
    @State private var groqKey = Keychain.groqKey ?? ""
    @State private var vocabulary = Settings.vocabulary
    @State private var cleanupEnabled = Settings.cleanupEnabled
    @State private var segmentingEnabled = Settings.segmentingEnabled
    @State private var historyEnabled = Settings.historyEnabled

    // Grants are made in System Settings, outside this app, and nothing notifies
    // us. Polling is the only way to notice, so the view re-reads on every tick.
    @State private var tick = 0
    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                permissionsSection
                Divider()
                keysSection
                Divider()
                vocabularySection
                Divider()
                behaviourSection
                Divider()
                dangerSection
            }
            .padding(24)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .onReceive(poll) { _ in tick += 1 }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permissions").font(.headline)
            permissionRow("Microphone", granted: Permissions.microphone, pane: "security?Privacy_Microphone")
            permissionRow("Accessibility", granted: Permissions.accessibility, pane: "security?Privacy_Accessibility")
            permissionRow("Input Monitoring", granted: Permissions.inputMonitoring, pane: "security?Privacy_ListenEvent")

            HStack(spacing: 8) {
                Text("•").frame(width: 20)
                Text("Set Keyboard → \"Press 🌐 key to\" → Do Nothing")
                Spacer()
                Button("Open") { Permissions.openSettings("keyboard") }
            }
            Text("Without that last step, fn also opens the emoji picker.")
                .font(.caption).foregroundStyle(.secondary)

            Button("Run setup again…") { onRerunSetup() }
        }
    }

    private func permissionRow(_ title: String, granted: Bool, pane: String) -> some View {
        HStack(spacing: 8) {
            Text(granted ? "✅" : "⚠️").frame(width: 20)
            Text(title)
            Spacer()
            Button("Open") { Permissions.openSettings(pane) }
        }
        // tick is read so the row recomputes on every poll.
        .id("\(title)-\(granted)-\(tick)")
    }

    private var keysSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("API keys").font(.headline)

            Text("Groq — required").font(.subheadline)
            SecureField("gsk_…", text: $groqKey)
                .onSubmit { Keychain.groqKey = trimmed(groqKey) }

            Text("OpenAI — optional").font(.subheadline)
            SecureField("sk-…", text: $openAIKey)
                .onSubmit { Keychain.openAIKey = trimmed(openAIKey) }

            Button("Save keys") {
                Keychain.openAIKey = trimmed(openAIKey)
                Keychain.groqKey = trimmed(groqKey)
            }
            Text("Both stored in your macOS Keychain, never on disk. Groq runs both "
                 + "transcription and formatting, so its key is the only one you need. "
                 + "Add an OpenAI key only if you dictate in more than one language in a "
                 + "single sentence — Groq's model translates the other language away, and "
                 + "OpenAI's costs about 4.5x more per hour to keep it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var vocabularySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Vocabulary").font(.headline)
            TextField("RBAC, SOX, …", text: $vocabulary)
                .onSubmit { Settings.vocabulary = vocabulary }
            Button("Save vocabulary") { Settings.vocabulary = vocabulary }
            Text("Names and acronyms you say often. This is the biggest accuracy lever in "
                 + "the app: without it, RBAC came back as आरबैक and \"risk owner\" as "
                 + "\"response और\".")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var behaviourSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Behaviour").font(.headline)
            Toggle("Clean up transcripts", isOn: $cleanupEnabled)
                .onChange(of: cleanupEnabled) { _, new in Settings.cleanupEnabled = new }
            Toggle("Transcribe while speaking", isOn: $segmentingEnabled)
                .onChange(of: segmentingEnabled) { _, new in Settings.segmentingEnabled = new }
            Toggle("Save history", isOn: $historyEnabled)
                .onChange(of: historyEnabled) { _, new in Settings.historyEnabled = new }
        }
    }

    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button("Delete all history…") { confirmDeleteAll() }
            Text("Removes every stored transcript from this Mac. Dictation is unaffected.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func confirmDeleteAll() {
        let alert = NSAlert()
        alert.messageText = "Delete all dictation history?"
        alert.informativeText =
            "Every transcript stored on this Mac will be removed. This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.deleteAll()
    }

    private func trimmed(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }
}
