import Foundation
import XFlowCore

func checkOpenAI() {
    let transcription = OpenAI.transcriptionRequest(
        apiKey: "sk-test", model: "gpt-4o-transcribe",
        audio: Data([0xDE, 0xAD, 0xBE, 0xEF]), filename: "clip.m4a", boundary: "B"
    )
    Checks.equal(transcription.url?.absoluteString,
                 "https://api.openai.com/v1/audio/transcriptions",
                 "transcription request targets the audio endpoint")
    Checks.equal(transcription.httpMethod, "POST", "transcription request is a POST")
    Checks.equal(transcription.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test",
                 "transcription request carries the bearer token")
    Checks.equal(transcription.value(forHTTPHeaderField: "Content-Type"),
                 "multipart/form-data; boundary=B",
                 "transcription request declares the multipart boundary")

    let transcriptionBody = transcription.httpBody!
    Checks.check(transcriptionBody.range(of: Data([0xDE, 0xAD, 0xBE, 0xEF])) != nil,
                 "transcription body carries the audio bytes")
    Checks.check(String(data: transcriptionBody, encoding: .isoLatin1)!.contains("gpt-4o-transcribe"),
                 "transcription body carries the model name")

    let cleanup = OpenAI.cleanupRequest(apiKey: "sk-test", model: "gpt-4o-mini", transcript: "hello there")
    Checks.equal(cleanup.url?.absoluteString, "https://api.openai.com/v1/chat/completions",
                 "cleanup request targets the chat endpoint")
    Checks.equal(cleanup.value(forHTTPHeaderField: "Content-Type"), "application/json",
                 "cleanup request is json")

    let json = try! JSONSerialization.jsonObject(with: cleanup.httpBody!) as! [String: Any]
    Checks.equal(json["model"] as? String, "gpt-4o-mini", "cleanup request names the model")
    Checks.equal(json["temperature"] as? Double, 0, "cleanup runs at temperature zero")

    let messages = json["messages"] as! [[String: String]]
    Checks.equal(messages.count, 2, "cleanup sends exactly two messages")
    Checks.equal(messages[0]["role"], "system", "first message is the system prompt")
    Checks.equal(messages[0]["content"], CleanupPrompt.system, "system message is the cleanup prompt")
    Checks.equal(messages[1]["role"], "user", "second message is the user turn")
    Checks.equal(messages[1]["content"], "hello there", "user message is the transcript")

    Checks.equal(try? OpenAI.decodeTranscript(Data(#"{"text":"  mujhe yeh chahiye  "}"#.utf8)),
                 "mujhe yeh chahiye",
                 "transcript is decoded and trimmed")

    Checks.throwsError(XFlowError.emptyTranscript, "blank transcript is an empty transcript error") {
        _ = try OpenAI.decodeTranscript(Data(#"{"text":"   "}"#.utf8))
    }

    Checks.throwsError(XFlowError.decoding, "malformed transcript body is a decoding error") {
        _ = try OpenAI.decodeTranscript(Data("not json".utf8))
    }

    Checks.equal(try? OpenAI.decodeCleanup(Data(#"{"choices":[{"message":{"content":"Mujhe yeh chahiye.\n"}}]}"#.utf8)),
                 "Mujhe yeh chahiye.",
                 "cleanup response is decoded and trimmed")

    Checks.throwsError(XFlowError.decoding, "cleanup response with no choices is a decoding error") {
        _ = try OpenAI.decodeCleanup(Data(#"{"choices":[]}"#.utf8))
    }
}
