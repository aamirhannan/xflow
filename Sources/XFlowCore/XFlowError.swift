import Foundation

public enum XFlowError: Error, Equatable, Sendable {
    case noAPIKey
    case invalidKey
    case rateLimited
    case server(String)
    case emptyTranscript
    case decoding
    case network

    /// Maps an HTTP response to an error, or nil when the response succeeded.
    public static func from(status: Int, body: Data) -> XFlowError? {
        switch status {
        case 200..<300: return nil
        case 401, 403:  return .invalidKey
        case 429:       return .rateLimited
        default:        return .server(serverMessage(body) ?? "HTTP \(status)")
        }
    }

    private static func serverMessage(_ body: Data) -> String? {
        struct Envelope: Decodable {
            struct Payload: Decodable { let message: String }
            let error: Payload
        }
        return try? JSONDecoder().decode(Envelope.self, from: body).error.message
    }

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .network, .server: return true
        case .noAPIKey, .invalidKey, .emptyTranscript, .decoding: return false
        }
    }

    /// Short enough to fit on the overlay pill.
    public var userMessage: String {
        switch self {
        case .noAPIKey:        return "No API key set"
        case .invalidKey:      return "API key rejected"
        case .rateLimited:     return "Rate limited, try again"
        case .server(let msg): return msg
        case .emptyTranscript: return "Nothing heard"
        case .decoding:        return "Unexpected API response"
        case .network:         return "No network"
        }
    }
}
