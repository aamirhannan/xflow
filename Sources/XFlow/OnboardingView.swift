import AppKit
import SwiftUI

/// First-run setup, one requirement per screen.
///
/// Separate from the Settings checklist on purpose: someone with nothing granted
/// and someone fixing one broken permission a month later need different screens.
/// The checklist is needed either way, so this wizard is the only extra.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var step = 0
    @State private var openAIKey = Keychain.openAIKey ?? ""
    @State private var groqKey = Keychain.groqKey ?? ""
    @State private var tick = 0

    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()
    private let lastStep = 6

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            content.frame(maxWidth: 460)
            Spacer()
            controls.frame(maxWidth: 460)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(poll) { _ in
            tick += 1
            advanceIfGranted()
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0:
            screen(
                "Welcome to XFlow",
                "Hold fn anywhere, speak, and let go. The text appears in whatever you "
                + "were typing in.\n\nEverything stays on this Mac. There is no account "
                + "and nothing is synced."
            )
        case 1:
            permissionScreen(
                "Microphone",
                granted: Permissions.microphone,
                why: "XFlow needs to hear you.",
                pane: "security?Privacy_Microphone"
            )
        case 2:
            permissionScreen(
                "Accessibility",
                granted: Permissions.accessibility,
                why: "Needed to paste the text for you, by posting ⌘V.",
                pane: "security?Privacy_Accessibility"
            )
        case 3:
            permissionScreen(
                "Input Monitoring",
                granted: Permissions.inputMonitoring,
                why: "Needed to notice the fn key while another app is focused.",
                pane: "security?Privacy_ListenEvent"
            )
        case 4:
            VStack(alignment: .leading, spacing: 12) {
                Text("One keyboard setting").font(.title2)
                Text(
                    "Set Keyboard → \"Press 🌐 key to\" → Do Nothing.\n\nWithout it, holding "
                    + "fn also opens the emoji picker."
                )
                .foregroundStyle(.secondary)
                Button("Open Keyboard settings") { Permissions.openSettings("keyboard") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case 5:
            VStack(alignment: .leading, spacing: 12) {
                Text("Your Groq API key").font(.title2)
                Text(
                    "Groq runs both the transcription and the formatting, so this is the "
                    + "only key XFlow needs. Get one at console.groq.com/keys. It is stored "
                    + "in your Keychain, never on disk."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                SecureField("gsk_…", text: $groqKey).textFieldStyle(.roundedBorder)

                Text("OpenAI key — optional").font(.subheadline)
                Text(
                    "Only needed if you mix two languages inside one sentence. Groq's model "
                    + "translates the other language away; OpenAI's keeps both, at about "
                    + "4.5x the cost per hour. You can add this later in Settings."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                SecureField("sk-…", text: $openAIKey).textFieldStyle(.roundedBorder)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            screen("You are set up", "Hold fn anywhere and start talking.")
        }
    }

    private func screen(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2)
            Text(body).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionScreen(
        _ title: String, granted: Bool, why: String, pane: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.title2)
                Text(granted ? "✅" : "⚠️")
            }
            Text(why).foregroundStyle(.secondary)
            Button("Open System Settings") { Permissions.openSettings(pane) }
            if granted {
                Text("Granted. Moving on…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id("\(title)-\(granted)-\(tick)")
    }

    private var controls: some View {
        HStack {
            if step > 0 { Button("Back") { step -= 1 } }
            Spacer()
            if step < lastStep {
                Button("Continue") { advance() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Relaunch XFlow") { relaunch() }
                Button("Finish") { finish() }.keyboardShortcut(.defaultAction)
            }
        }
    }

    private func advance() {
        if step == 5 { saveKeys() }
        step = min(step + 1, lastStep)
    }

    /// A permission screen moves on by itself once the grant lands, so the user
    /// does not come back from System Settings to a screen still asking for what
    /// they just gave.
    private func advanceIfGranted() {
        switch step {
        case 1 where Permissions.microphone,
             2 where Permissions.accessibility,
             3 where Permissions.inputMonitoring:
            step += 1
        default:
            break
        }
    }

    private func saveKeys() {
        let openAI = openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let groq = groqKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.openAIKey = openAI.isEmpty ? nil : openAI
        Keychain.groqKey = groq.isEmpty ? nil : groq
    }

    private func finish() {
        saveKeys()
        Settings.hasCompletedOnboarding = true
        onFinish()
    }

    /// Accessibility and Input Monitoring grants do not always take effect in a
    /// process that was already running. Without this the user ends the wizard
    /// looking at a green checklist and a dead fn key.
    private func relaunch() {
        finish()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: configuration
        )
        NSApp.terminate(nil)
    }
}
