import Foundation

/// Request construction and response decoding only. No URLSession here, so all
/// of it is checkable without a network or a mock server.
///
/// Groq handles the cleanup pass only; transcription lives in Transcription.swift
/// because only OpenAI's model keeps Hindi and English intact in one sentence.
public enum Groq {
    public static let chatURL =
        URL(string: "https://api.groq.com/openai/v1/chat/completions")!

    /// NOT a reasoning model, on purpose. `openai/gpt-oss-20b` reasoned until it
    /// exhausted its budget and returned empty content with HTTP 200.
    /// `llama-3.1-8b-instant` appended meta-commentary about its own edits and
    /// translated English into Hinglish. 70b returned exactly the input word
    /// count, verbatim English, in 0.73s.
    public static let defaultCleanupModel = "llama-3.3-70b-versatile"

    public static func cleanupRequest(
        apiKey: String, model: String, transcript: String, vocabulary: String = ""
    ) -> URLRequest {
        let payload: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": CleanupPrompt.system(vocabulary: vocabulary)],
                // Delimited, so the model can tell speech from instructions.
                ["role": "user", "content": CleanupPrompt.wrap(transcript)],
            ],
        ]

        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        return request
    }

    /// Sent when the first cleanup left non-Latin script behind. Continuing the
    /// same conversation (rather than starting a fresh one) is what makes it
    /// work: the model sees its own output and corrects it. Measured to fix the
    /// input that failed 6 of 6 times on the first pass.
    public static let retryInstruction = """
    The text still contains non-Latin script. Rewrite it so that EVERY word is \
    written in Latin letters. Transliterate, do not translate: keep the same \
    words, only change the alphabet. Output only the rewritten text.
    """

    public static func cleanupRetryRequest(
        apiKey: String, model: String, transcript: String,
        firstAttempt: String, vocabulary: String = ""
    ) -> URLRequest {
        let payload: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": CleanupPrompt.system(vocabulary: vocabulary)],
                ["role": "user", "content": CleanupPrompt.wrap(transcript)],
                ["role": "assistant", "content": firstAttempt],
                ["role": "user", "content": retryInstruction],
            ],
        ]

        var request = URLRequest(url: chatURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        return request
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

        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // An empty completion is a FAILURE, never a valid formatting result.
        // A reasoning model can return 200 with empty content after spending its
        // budget thinking; treating that as success made whole segments vanish
        // from the assembled transcript, because empty pieces are filtered out.
        // Throwing here makes the caller fall back to the raw transcript.
        guard !text.isEmpty else { throw XFlowError.decoding }
        return text
    }
}
