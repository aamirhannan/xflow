import Foundation
import XFlowCore

func checkGroq() {
    let audio = Data([0xDE, 0xAD, 0xBE, 0xEF])
    let request = Transcription.request(
        apiKey: "gsk-test", model: Transcription.defaultModel,
        audio: audio, filename: "clip.m4a", boundary: "B"
    )

    Checks.equal(request.url?.absoluteString,
                 "https://api.openai.com/v1/audio/transcriptions",
                 "transcription targets openai, the only model that keeps hindi and english both")
    Checks.equal(Transcription.defaultModel, "gpt-4o-mini-transcribe", "stt model is 4o-mini-transcribe")
    // Whisper model ids must still route to Groq, so switching back is one setting.
    Checks.equal(Transcription.endpoint(for: "whisper-large-v3-turbo").absoluteString,
                 "https://api.groq.com/openai/v1/audio/transcriptions",
                 "whisper models still route to groq")
    Checks.equal(request.httpMethod, "POST", "transcription is a POST")
    Checks.equal(request.value(forHTTPHeaderField: "Authorization"), "Bearer gsk-test",
                 "transcription carries the bearer token")
    Checks.equal(Groq.defaultCleanupModel, "llama-3.3-70b-versatile", "cleanup model is llama 70b")

    let body = String(data: request.httpBody!, encoding: .isoLatin1)!
    Checks.check(request.httpBody!.range(of: audio) != nil, "body carries the audio bytes")
    Checks.check(body.contains("gpt-4o-mini-transcribe"), "body names the model")
    // Regression guard, three measured harms behind it. The `prompt` field is not
    // a vocabulary list to the API — it is previous context, and the model
    // continues from it. Sending those 14 English terms on the audio request:
    //   1. biased language detection: mixed hindi survived 3 of 6 runs, not 6 of 6
    //   2. leaked verbatim into the transcript on near-silent audio, pasting
    //      "RBAC, SOX, RACM, risk owner, ..." into the user's document
    //   3. pushed gpt-4o-transcribe into romanizing everything into devanagari
    // Vocabulary belongs on the cleanup call, where it can reach neither.
    Checks.check(!body.contains("name=\"prompt\""),
                 "the audio request never carries a vocabulary prompt")
    Checks.check(!body.contains("RBAC"),
                 "no vocabulary term can reach the audio request by any route")

    // Regression guard. With language=en, Whisper translated and summarised
    // instead of transcribing and lost most of the content. It must never be sent.
    Checks.check(!body.contains("name=\"language\""), "transcription never sends a language field")

    // Vocabulary now rides on the cleanup system prompt instead.
    let withVocab = CleanupPrompt.system(vocabulary: "RBAC, SOX")
    Checks.check(withVocab.contains("RBAC, SOX"), "cleanup prompt carries the vocabulary terms")
    Checks.check(withVocab.contains("restore its correct spelling"),
                 "cleanup prompt explains what to do with them")
    Checks.equal(CleanupPrompt.system(vocabulary: "   "), CleanupPrompt.system,
                 "blank vocabulary leaves the cleanup prompt untouched")

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
    Checks.equal(messages[1]["content"], CleanupPrompt.wrap("hello there"),
                 "user message is the transcript, wrapped in the delimiter")

    Checks.equal(try? Transcription.decode(Data(#"{"text":"  mujhe yeh chahiye  "}"#.utf8)),
                 "mujhe yeh chahiye", "transcript is decoded and trimmed")
    Checks.throwsError(XFlowError.emptyTranscript, "blank transcript is an empty transcript error") {
        _ = try Transcription.decode(Data(#"{"text":"   "}"#.utf8))
    }
    Checks.throwsError(XFlowError.decoding, "malformed transcript body is a decoding error") {
        _ = try Transcription.decode(Data("not json".utf8))
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

func checkScript() {
    // The guard that makes transliteration a guarantee rather than a hope.
    Checks.equal(Script.containsNonLatin("Yahan pe to bhai, mujhe consistency chahiye."), false,
                 "fully romanized text is accepted")
    Checks.equal(Script.containsNonLatin("यहाँ पे तो भई, मुझे consistency चाहिए"), true,
                 "the exact input that survived cleanup 6 of 6 times is caught")
    Checks.equal(Script.containsNonLatin("hello there"), false, "plain english is accepted")
    Checks.equal(Script.containsNonLatin("mixed मुझे english"), true,
                 "a single devanagari word anywhere is caught")
    Checks.equal(Script.containsNonLatin("یہ اردو ہے"), true, "urdu is caught too")
    Checks.equal(Script.containsNonLatin(""), false, "empty text has nothing to catch")

    // The retry continues the same conversation so the model sees its own output.
    let retry = Groq.cleanupRetryRequest(
        apiKey: "gsk-test", model: Groq.defaultCleanupModel,
        transcript: "मुझे यह चाहिए", firstAttempt: "मुझे यह चाहिए."
    )
    let json = try! JSONSerialization.jsonObject(with: retry.httpBody!) as! [String: Any]
    let messages = json["messages"] as! [[String: String]]
    Checks.equal(messages.count, 4, "the retry replays system, user, assistant, then the correction")
    Checks.equal(messages[2]["role"], "assistant", "the failed attempt is replayed back to the model")
    Checks.equal(messages[2]["content"], "मुझे यह चाहिए.", "the retry shows the model its own output")
    Checks.equal(messages[3]["content"], Groq.retryInstruction, "the correction is the last turn")
}

func checkTranslationDetection() {
    // Measured separation on real sentences: transliteration 0.653-0.889,
    // translation 0.061-0.476. The threshold sits in the empty band.
    Checks.check(Script.translationThreshold > 0.476 && Script.translationThreshold < 0.653,
                 "the threshold sits between the measured translation and transliteration bands")

    // Transliteration must pass.
    Checks.equal(Script.looksTranslated(original: "मुझे यह चाहिए", output: "Mujhe yeh chahiye."),
                 false, "romanized output is not flagged as translated")
    Checks.equal(Script.looksTranslated(original: "तुम कहाँ जा रहे हो", output: "Tum kahan ja rahe ho?"),
                 false, "another romanized sentence is not flagged")

    // Translation must be caught — the failure the script check alone missed,
    // because translated text is perfectly clean Latin.
    Checks.equal(Script.looksTranslated(original: "मुझे यह चाहिए", output: "I want this."),
                 true, "translation to english is caught")
    Checks.equal(Script.looksTranslated(original: "आप क्या कर रहे हैं", output: "What are you doing?"),
                 true, "another translation is caught")
    Checks.equal(Script.looksTranslated(original: "हमें इसको ठीक करना है", output: "We need to fix this."),
                 true, "a third translation is caught")

    // English in, English out is not a translation.
    Checks.equal(Script.looksTranslated(original: "hello there", output: "Hello there."),
                 false, "pure english is never flagged as translated")

    // The deterministic floor: always Latin, never empty.
    let floorText = Script.romanize("यहाँ पे तो भई, मुझे consistency चाहिए")
    Checks.equal(Script.containsNonLatin(floorText), false,
                 "icu romanization leaves no script behind")
    Checks.check(floorText.contains("mujhe"), "icu romanization keeps the speaker's words")
}
