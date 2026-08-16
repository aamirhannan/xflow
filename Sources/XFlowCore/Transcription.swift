import Foundation

/// Speech-to-text request construction.
///
/// Both legs now run on Groq: transcription here, formatting in `Groq`. That
/// means one API key for the whole app rather than two.
///
/// This is a **deliberate trade, not an upgrade**. Tested on three recordings —
/// pure Hindi, pure English, and code-switched:
///
///   groq whisper-large-v3-turbo   correct on single-language speech. On mixed
///                                 speech it translated the Hindi away entirely,
///                                 0 of 6 runs preserved. Read pure Hindi as Urdu
///   groq whisper-large-v3         dropped most of the content
///   gpt-4o-transcribe             dropped most of the content
///   gpt-4o-mini-transcribe        correct on all three, 6 of 6 on mixed
///
/// Whisper picks a single language for a whole clip, so code-switched speech
/// loses whichever language does not win: English dominant means the Hindi gets
/// translated, Hindi dominant means the English gets written in Devanagari.
/// `gpt-4o-mini-transcribe` keeps both and is the only model measured to do so.
///
/// It was the default through V3 for exactly that reason. It is not the default
/// now because this app's own history says 19 of 20 real dictations are English,
/// and keeping it cost 4.5x per hour — ₹16 against ₹3.5 — to protect the
/// twentieth. Switch `Settings.sttModel` back to `gpt-4o-mini-transcribe` if you
/// dictate in more than one language; `endpoint(for:)` routes it to OpenAI and
/// the second key becomes required again.
public enum Transcription {
    public static let openAIURL =
        URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    public static let groqURL =
        URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!

    /// ~9x cheaper and ~2x faster than the OpenAI model, correct on
    /// single-language speech, wrong on mixed. See the note above.
    public static let defaultModel = "whisper-large-v3-turbo"

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
