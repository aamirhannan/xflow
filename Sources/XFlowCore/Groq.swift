import Foundation

/// Request construction and response decoding only. No URLSession here, so all
/// of it is checkable without a network or a mock server.
///
/// Groq's endpoints are OpenAI-compatible in shape, which is why the request
/// bodies look familiar. `openai/gpt-oss-20b` is a Groq-hosted model whose ID
/// carries an `openai/` prefix — it is not a call to OpenAI.
public enum Groq {
    public static let transcriptionURL =
        URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    public static let chatURL =
        URL(string: "https://api.groq.com/openai/v1/chat/completions")!

    /// Benchmarked on real Hinglish speech: turbo beat both whisper-large-v3 and
    /// gpt-4o-transcribe on accuracy, at 15x the speed of the latter.
    /// whisper-large-v3 also returned HTTP 500 repeatedly on a 983KB file.
    public static let defaultSTTModel = "whisper-large-v3-turbo"
    /// 1000 tokens/sec, which turns a 4.11s cleanup into roughly 0.4s.
    public static let defaultCleanupModel = "openai/gpt-oss-20b"

    public static func transcriptionRequest(
        apiKey: String,
        model: String,
        audio: Data,
        filename: String,
        vocabulary: String,
        boundary: String = "xflow-\(UUID().uuidString)"
    ) -> URLRequest {
        var body = MultipartBody(boundary: boundary)
        body.addField(name: "model", value: model)

        // The vocabulary prompt is what makes Groq win: without it "risk owner"
        // came back as "response और" and SOX as "शॉक्स". Sent only when it has
        // content — an empty prompt field is worse than no prompt field.
        let terms = vocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !terms.isEmpty { body.addField(name: "prompt", value: terms) }

        // NO `language` FIELD. EVER. With language=en, Whisper stopped
        // transcribing and started translating and summarising, destroying most
        // of the content. Auto-detection is the only correct setting here.

        body.addFile(name: "file", filename: filename, contentType: "audio/m4a", data: audio)

        var request = URLRequest(url: transcriptionURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.finished
        return request
    }

    public static func cleanupRequest(apiKey: String, model: String, transcript: String) -> URLRequest {
        let payload: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": CleanupPrompt.system],
                ["role": "user", "content": transcript],
            ],
        ]

        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        return request
    }

    public static func decodeTranscript(_ data: Data) throws -> String {
        struct Response: Decodable { let text: String }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw XFlowError.decoding
        }
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw XFlowError.emptyTranscript }
        return text
    }

    public static func decodeCleanup(_ data: Data) throws -> String {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let content = response.choices.first?.message.content
        else { throw XFlowError.decoding }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
