import Foundation
import XFlowCore

func checkGroq() {
    let audio = Data([0xDE, 0xAD, 0xBE, 0xEF])
    let request = Groq.transcriptionRequest(
        apiKey: "gsk-test", model: Groq.defaultSTTModel,
        audio: audio, filename: "clip.m4a",
        vocabulary: "RBAC, SOX", boundary: "B"
    )

    Checks.equal(request.url?.absoluteString,
                 "https://api.groq.com/openai/v1/audio/transcriptions",
                 "transcription targets the groq endpoint")
    Checks.equal(request.httpMethod, "POST", "transcription is a POST")
    Checks.equal(request.value(forHTTPHeaderField: "Authorization"), "Bearer gsk-test",
                 "transcription carries the bearer token")
    Checks.equal(Groq.defaultSTTModel, "whisper-large-v3-turbo", "stt model is turbo")
    Checks.equal(Groq.defaultCleanupModel, "llama-3.3-70b-versatile", "cleanup model is llama 70b")

    let body = String(data: request.httpBody!, encoding: .isoLatin1)!
    Checks.check(request.httpBody!.range(of: audio) != nil, "body carries the audio bytes")
    Checks.check(body.contains("whisper-large-v3-turbo"), "body names the model")
    Checks.check(body.contains("name=\"prompt\""), "body carries the vocabulary prompt")
    Checks.check(body.contains("RBAC, SOX"), "body carries the vocabulary terms")

    // Regression guard. With language=en, Whisper translated and summarised
    // instead of transcribing and lost most of the content. It must never be sent.
    Checks.check(!body.contains("name=\"language\""), "transcription never sends a language field")

    let noVocab = Groq.transcriptionRequest(
        apiKey: "gsk-test", model: Groq.defaultSTTModel,
        audio: audio, filename: "clip.m4a", vocabulary: "   ", boundary: "B"
    )
    let noVocabBody = String(data: noVocab.httpBody!, encoding: .isoLatin1)!
    Checks.check(!noVocabBody.contains("name=\"prompt\""),
                 "blank vocabulary omits the prompt field entirely")

    let cleanup = Groq.cleanupRequest(
        apiKey: "gsk-test", model: Groq.defaultCleanupModel, transcript: "hello there"
    )
    Checks.equal(cleanup.url?.absoluteString,
                 "https://api.groq.com/openai/v1/chat/completions",
                 "cleanup targets the groq chat endpoint")

    let json = try! JSONSerialization.jsonObject(with: cleanup.httpBody!) as! [String: Any]
    Checks.equal(json["model"] as? String, "llama-3.3-70b-versatile", "cleanup names the model")
    Checks.equal(json["temperature"] as? Double, 0, "cleanup runs at temperature zero")
    let messages = json["messages"] as! [[String: String]]
    Checks.equal(messages.count, 2, "cleanup sends exactly two messages")
    Checks.equal(messages[0]["content"], CleanupPrompt.system, "system message is the cleanup prompt")
    Checks.equal(messages[1]["content"], "hello there", "user message is the transcript")

    Checks.equal(try? Groq.decodeTranscript(Data(#"{"text":"  mujhe yeh chahiye  "}"#.utf8)),
                 "mujhe yeh chahiye", "transcript is decoded and trimmed")
    Checks.throwsError(XFlowError.emptyTranscript, "blank transcript is an empty transcript error") {
        _ = try Groq.decodeTranscript(Data(#"{"text":"   "}"#.utf8))
    }
    Checks.throwsError(XFlowError.decoding, "malformed transcript body is a decoding error") {
        _ = try Groq.decodeTranscript(Data("not json".utf8))
    }
    Checks.equal(try? Groq.decodeCleanup(Data(#"{"choices":[{"message":{"content":"Mujhe yeh chahiye.\n"}}]}"#.utf8)),
                 "Mujhe yeh chahiye.", "cleanup response is decoded and trimmed")
    Checks.throwsError(XFlowError.decoding, "cleanup with no choices is a decoding error") {
        _ = try Groq.decodeCleanup(Data(#"{"choices":[]}"#.utf8))
    }

    // A reasoning model can return 200 with empty content after exhausting its
    // budget on reasoning. Treating that as a valid result made whole segments
    // disappear from the transcript, since empty pieces are filtered on assembly.
    Checks.throwsError(XFlowError.decoding, "empty cleanup content is a failure, not a result") {
        _ = try Groq.decodeCleanup(Data(#"{"choices":[{"message":{"content":""}}]}"#.utf8))
    }
    Checks.throwsError(XFlowError.decoding, "whitespace-only cleanup content is a failure") {
        _ = try Groq.decodeCleanup(Data(#"{"choices":[{"message":{"content":"  \n "}}]}"#.utf8))
    }
}

func checkVocabularyPrompt() {
    let terms = VocabularyPrompt.default

    Checks.check(!terms.isEmpty, "a default vocabulary ships with the app")
    // These are the exact terms the benchmark showed being mangled without it.
    Checks.check(terms.contains("RBAC"), "default vocabulary includes RBAC")
    Checks.check(terms.contains("SOX"), "default vocabulary includes SOX")
    Checks.check(terms.contains("risk owner"), "default vocabulary includes risk owner")
    // A prompt is a bias, not a dictionary — an enormous one degrades results.
    Checks.check(terms.count < 900, "default vocabulary stays short enough to bias, not dominate")
}
