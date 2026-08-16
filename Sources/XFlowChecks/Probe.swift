import Foundation
import XFlowCore

/// Runs the real pipeline over an audio file and prints every stage, so the
/// cleanup behaviour can be iterated on without dictating into the app by hand.
///
///   GROQ_API_KEY=... swift run XFlowChecks --probe path/to/clip.m4a [...]
///
/// This exercises the shipped Groq request builders and the shipped Script
/// verification. A reimplementation in another language would prove nothing.
enum Probe {
    static func run(paths: [String]) {
        let env = ProcessInfo.processInfo.environment
        guard let groq = env["GROQ_API_KEY"], let openai = env["OPENAI_API_KEY"],
              !groq.isEmpty, !openai.isEmpty else {
            print("set GROQ_API_KEY and OPENAI_API_KEY"); exit(2)
        }
        for path in paths { probe(path: path, sttKey: openai, cleanupKey: groq) }
    }

    private static func probe(path: String, sttKey: String, cleanupKey: String) {
        let name = (path as NSString).lastPathComponent
        print("\n" + String(repeating: "=", count: 72))
        print("FILE: \(name)")
        print(String(repeating: "=", count: 72))

        guard let audio = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            print("  cannot read"); return
        }

        guard let transcript = call(
            Transcription.request(
                apiKey: sttKey, model: Transcription.defaultModel, audio: audio,
                filename: name
            ), decode: Transcription.decode
        ) else { print("  transcription failed"); return }

        print("\n[1] RAW TRANSCRIPT  (devanagari: \(Script.containsNonLatin(transcript)))")
        print("    \(transcript.prefix(300))")

        guard let cleaned = call(
            Groq.cleanupRequest(apiKey: cleanupKey, model: Groq.defaultCleanupModel, transcript: transcript, vocabulary: VocabularyPrompt.default),
            decode: Groq.decodeCleanup
        ) else { print("  cleanup failed"); return }

        let survived = Script.containsNonLatin(cleaned)
        let score = Script.similarity(Script.romanize(transcript), cleaned)
        let translated = Script.looksTranslated(original: transcript, output: cleaned)

        print("\n[2] CLEANUP ATTEMPT 1")
        print("    \(cleaned.prefix(300))")
        print("    script survived : \(survived)")
        print("    similarity      : \(String(format: "%.3f", score))  (threshold \(Script.translationThreshold))")
        print("    verdict         : \(survived ? "SCRIPT SURVIVED" : translated ? "TRANSLATED" : "OK")")

        guard survived || translated else {
            print("\n[FINAL] accepted on first attempt"); return
        }

        guard let retried = call(
            Groq.cleanupRetryRequest(
                apiKey: cleanupKey, model: Groq.defaultCleanupModel,
                transcript: transcript, firstAttempt: cleaned
            ), decode: Groq.decodeCleanup
        ) else { print("  retry failed"); return }

        let survived2 = Script.containsNonLatin(retried)
        let translated2 = Script.looksTranslated(original: transcript, output: retried)
        print("\n[3] RETRY")
        print("    \(retried.prefix(300))")
        print("    similarity      : \(String(format: "%.3f", Script.similarity(Script.romanize(transcript), retried)))")
        print("    verdict         : \(survived2 ? "SCRIPT SURVIVED" : translated2 ? "TRANSLATED" : "OK")")

        if survived2 || translated2 {
            print("\n[FINAL] fell back to ICU: \(Script.romanize(transcript).prefix(200))")
        } else {
            print("\n[FINAL] accepted on retry")
        }
    }

    private static func call(_ request: URLRequest, decode: @escaping (Data) throws -> String) -> String? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: String?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { result = try? decode(data) }
            semaphore.signal()
        }.resume()
        semaphore.wait()
        return result
    }
}
