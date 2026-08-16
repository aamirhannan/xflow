import Foundation

/// UserDefaults-backed preferences. Never store the API key here — it goes in
/// the Keychain. See Keychain.swift.
enum Settings {
    private static let defaults = UserDefaults.standard

    static var sttModel: String {
        get { defaults.string(forKey: "sttModel") ?? "gpt-4o-transcribe" }
        set { defaults.set(newValue, forKey: "sttModel") }
    }

    static var cleanupModel: String {
        get { defaults.string(forKey: "cleanupModel") ?? "gpt-4o-mini" }
        set { defaults.set(newValue, forKey: "cleanupModel") }
    }

    static var cleanupEnabled: Bool {
        get { defaults.object(forKey: "cleanupEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "cleanupEnabled") }
    }
}
