import Foundation
import XFlowCore

/// UserDefaults-backed preferences. Never store the API key here — it goes in
/// the Keychain. See Keychain.swift.
enum Settings {
    private static let defaults = UserDefaults.standard

    /// One-time migration: v1 stored OpenAI model names, which Groq does not
    /// host. Clearing them lets the new defaults apply.
    static func migrateFromV1() {
        guard defaults.object(forKey: "didMigrateToSplitProviders") == nil else { return }
        defaults.removeObject(forKey: "sttModel")
        defaults.removeObject(forKey: "cleanupModel")
        defaults.set(true, forKey: "didMigrateToSplitProviders")
    }

    static var sttModel: String {
        get { defaults.string(forKey: "sttModel") ?? Transcription.defaultModel }
        set { defaults.set(newValue, forKey: "sttModel") }
    }

    static var cleanupModel: String {
        get { defaults.string(forKey: "cleanupModel") ?? Groq.defaultCleanupModel }
        set { defaults.set(newValue, forKey: "cleanupModel") }
    }

    /// Terms biased into the transcription request. Editable in settings, and
    /// the single highest-leverage accuracy knob in the app.
    static var vocabulary: String {
        get { defaults.string(forKey: "vocabulary") ?? VocabularyPrompt.default }
        set { defaults.set(newValue, forKey: "vocabulary") }
    }

    static var cleanupEnabled: Bool {
        get { defaults.object(forKey: "cleanupEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "cleanupEnabled") }
    }

    /// Kill switch. v1's single-shot path stays in the code because a
    /// segmentation bug must never leave the user without dictation.
    static var segmentingEnabled: Bool {
        get { defaults.object(forKey: "segmentingEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "segmentingEnabled") }
    }

    /// Off means new dictations are not written to history. Reading and deleting
    /// still work, so pausing never hides or strands what is already stored.
    static var historyEnabled: Bool {
        get { defaults.object(forKey: "historyEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "historyEnabled") }
    }
}
