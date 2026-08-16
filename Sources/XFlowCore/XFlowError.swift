import Foundation

public enum XFlowError: Error, Equatable, Sendable {
    case noAPIKey
    case invalidKey
    case rateLimited
    case server(String)
    case emptyTranscript
    case decoding
    case network
    /// Distinct from `.network` on purpose: a timeout means the request was
    /// accepted and then went quiet, which is a different failure from having no
    /// route at all — and collapsing the two makes the bug undiagnosable.
    case timedOut

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
        // Deliberately NOT retryable. A timeout has already waited the full
        // budget; retrying it doubles the silence the user sits through, which
        // is what turned a 30-second stall into a 62-second one.
        case .timedOut: return false
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
        case .timedOut:        return "Timed out"
        }
    }
}
