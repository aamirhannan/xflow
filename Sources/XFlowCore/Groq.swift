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
    /// NOT a reasoning model, on purpose. `openai/gpt-oss-20b` reasons before
    /// answering and, on real transcripts, burned its entire completion budget
    /// on reasoning and returned empty content with finish_reason=length —
    /// still HTTP 200. Raising max_completion_tokens to 8000 did not help.
    /// `llama-3.1-8b-instant` answered but appended meta-commentary about what
    /// it had done and translated English phrases into Hinglish. 70b returned
    /// exactly the input word count, verbatim English, in the same 0.73s.
    public static let defaultCleanupModel = "llama-3.3-70b-versatile"

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
        apiKey: String, model: String, transcript: String, firstAttempt: String
    ) -> URLRequest {
        let payload: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": CleanupPrompt.system],
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
