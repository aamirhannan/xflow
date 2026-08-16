import Foundation
import Security
import XFlowCore

/// The API key lives here and nowhere else. This repository is public: it must
/// never reach UserDefaults, a file, a log line, or a commit.
enum Keychain {
    private static let service = "com.aamirhannan.xflow"

    /// Optional. Only needed when `Settings.sttModel` is an OpenAI model, which
    /// is the multilingual path — see `Transcription`. On the default Groq model
    /// the app never reads this.
    static var openAIKey: String? {
        get { read(account: "openai") }
        set { newValue.map { write($0, account: "openai") } ?? delete(account: "openai") }
    }

    /// Always required: cleanup runs on Groq, and so does transcription by
    /// default.
    static var groqKey: String? {
        get { read(account: "groq") }
        set { newValue.map { write($0, account: "groq") } ?? delete(account: "groq") }
    }

    /// Whether the keys on hand cover the model currently selected. An OpenAI
    /// model needs both; the default Groq one needs only the Groq key.
    static var hasKeysForSelectedModel: Bool {
        guard groqKey != nil else { return false }
        let usesGroq = Transcription.endpoint(for: Settings.sttModel) == Transcription.groqURL
        return usesGroq || openAIKey != nil
    }

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let key = String(data: data, encoding: .utf8),
              !key.isEmpty
        else { return nil }
        return key
    }

    private static func write(_ key: String, account: String) {
        delete(account: account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(key.utf8),
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
