import Foundation
import Security

/// The API key lives here and nowhere else. This repository is public: it must
/// never reach UserDefaults, a file, a log line, or a commit.
enum Keychain {
    private static let service = "com.aamirhannan.xflow"
    // Two providers, two keys: transcription runs on OpenAI because it is the
    // only model that keeps Hindi and English both intact in one sentence;
    // cleanup runs on Groq because it is far faster and cheaper for formatting.
    static var openAIKey: String? {
        get { read(account: "openai") }
        set { newValue.map { write($0, account: "openai") } ?? delete(account: "openai") }
    }

    static var groqKey: String? {
        get { read(account: "groq") }
        set { newValue.map { write($0, account: "groq") } ?? delete(account: "groq") }
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
