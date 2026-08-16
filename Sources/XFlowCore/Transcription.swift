import Foundation

/// Speech-to-text request construction.
///
/// The provider is split from cleanup on purpose: transcription runs on OpenAI,
/// formatting runs on Groq. That is not tidiness, it is measurement.
///
/// Tested on three recordings — pure Hindi, pure English, and code-switched:
///
///   groq whisper-large-v3-turbo   translated the Hindi away entirely on mixed
///                                 speech, and read pure Hindi as Urdu
///   groq whisper-large-v3         dropped most of the content
///   gpt-4o-transcribe             dropped most of the content
///   gpt-4o-mini-transcribe        correct on all three
///
/// Whisper picks a single language for a whole clip, so code-switched speech
/// loses whichever language does not win: English dominant means the Hindi gets
/// translated, Hindi dominant means the English gets written in Devanagari.
/// gpt-4o-mini-transcribe keeps both, which is the entire point of this app.
public enum Transcription {
    public static let openAIURL =
        URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    /// Kept so the Groq models remain one setting away: ~9x cheaper and ~2x
    /// faster, correct on single-language speech, wrong on mixed.
    public static let groqURL =
        URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

    public static let defaultModel = "gpt-4o-mini-transcribe"

    /// Models that must be sent to Groq rather than OpenAI.
    public static func endpoint(for model: String) -> URL {
        model.hasPrefix("whisper-") ? groqURL : openAIURL
    }

    public static func request(
        apiKey: String,
        model: String,
        audio: Data,
        filename: String,
        boundary: String = "xflow-\(UUID().uuidString)"
    ) -> URLRequest {
        var body = MultipartBody(boundary: boundary)
        body.addField(name: "model", value: model)

        // NO `prompt` FIELD. The vocabulary belongs on the cleanup call.
        // Measured: sending those 14 English words here biased language
        // detection and the model translated the Hindi away in 3 of 6 runs on
        // code-switched speech. Without them it kept the Hindi in 6 of 6.
        // The terms are still restored later, at the text stage, where they
        // cannot affect what language the audio is heard as.

        // NO `language` FIELD. EVER. With language=en, Whisper stopped
        // transcribing and started translating and summarising. With language=hi
        // it wrote the speaker's English in Devanagari. Auto-detection only.

        body.addFile(name: "file", filename: filename, contentType: "audio/m4a", data: audio)

        var request = URLRequest(url: endpoint(for: model))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body.finished
        return request
    }

    public static func decode(_ data: Data) throws -> String {
        struct Response: Decodable { let text: String }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw XFlowError.decoding
        }
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw XFlowError.emptyTranscript }
        return text
    }
}
