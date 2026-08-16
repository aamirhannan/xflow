import Foundation
import OSLog
import XFlowCore

/// Read with: /usr/bin/log show --last 30m --predicate 'subsystem == "com.aamirhannan.xflow"'
private let log = Logger(subsystem: "com.aamirhannan.xflow", category: "transcriber")

/// Reports where a request actually spent its time. The same upload succeeds
/// from a command-line process and stalls from inside this app, so knowing
/// whether it dies during connect, send, or wait is the whole question.
private final class MetricsLogger: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        guard let t = metrics.transactionMetrics.last else { return }

        func ms(_ from: Date?, _ to: Date?) -> String {
            guard let from, let to else { return "-" }
            return String(format: "%.0f", to.timeIntervalSince(from) * 1000)
        }

        let line = """
        metrics reused=\(t.isReusedConnection) proto=\(t.networkProtocolName ?? "?") \
        cellular=\(t.isCellular) \
        dns=\(ms(t.domainLookupStartDate, t.domainLookupEndDate)) \
        connect=\(ms(t.connectStartDate, t.connectEndDate)) \
        tls=\(ms(t.secureConnectionStartDate, t.secureConnectionEndDate)) \
        send=\(ms(t.requestStartDate, t.requestEndDate)) \
        wait=\(ms(t.requestEndDate, t.responseStartDate)) \
        recv=\(ms(t.responseStartDate, t.responseEndDate)) \
        bodySent=\(t.countOfRequestBodyBytesSent)
        """
        log.notice("\(line, privacy: .public)")
    }
}

/// Audio file in, finished text out. Owns both API calls and the retry policy.
struct Transcriber {
    /// A fresh session per dictation, never one shared for the app's lifetime.
    ///
    /// URLSession talks to OpenAI over HTTP/3, which is QUIC over UDP, and it
    /// pools those connections. NAT tables drop idle UDP mappings after roughly
    /// 30 seconds, and unlike TCP there is no reset packet to announce the death
    /// — so a reused QUIC connection looks alive and simply never transmits.
    /// Metrics on every failure showed exactly that: reused=true, bodySent=0,
    /// and every phase timestamp missing, until the inactivity timeout fired.
    ///
    /// Both API legs share this session, so the second call reuses a connection
    /// that is seconds old and provably alive. The cost is one extra handshake
    /// per dictation: dns 14ms + connect 48ms + tls 47ms, measured.
    private func makeSession() -> (URLSession, MetricsLogger) {
        let config = URLSessionConfiguration.default
        // Inactivity budget. Measured latency is ~1.5s for a 15s clip and ~13s
        // for a 4-minute one, so 15s of no data movement means something is
        // wrong, not slow. Paired with a hard ceiling on the whole transfer.
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 60
        let metrics = MetricsLogger()
        return (URLSession(configuration: config, delegate: metrics, delegateQueue: nil), metrics)
    }

    func transcribe(fileURL: URL) async throws -> String {
        guard let sttKey = Keychain.openAIKey, let cleanupKey = Keychain.groqKey else {
            throw XFlowError.noAPIKey
        }
        let (session, _) = makeSession()
        defer { session.finishTasksAndInvalidate() }
        let audio = try Data(contentsOf: fileURL)

        // Catches a truncated clip: AVAudioRecorder.stop() closing the file is
        // not obviously synchronous, and a half-written m4a would look like a
        // network problem from the outside.
        let onDisk = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? nil
        log.notice("clip read: inMemory=\(audio.count, privacy: .public)B onDisk=\(onDisk ?? -1, privacy: .public)B")

        let transcript = try await send(
            Transcription.request(
                apiKey: sttKey,
                model: Settings.sttModel,
                audio: audio,
                filename: fileURL.lastPathComponent
            ),
            on: session,
            decode: Transcription.decode
        )

        guard Settings.cleanupEnabled else { return transcript }

        // A failed cleanup must not lose the transcript. Devanagari beats nothing.
        do {
            let cleaned = try await send(
                Groq.cleanupRequest(
                    apiKey: cleanupKey,
                    model: Settings.cleanupModel,
                    transcript: transcript,
                    vocabulary: Settings.vocabulary
                ),
                on: session,
                decode: Groq.decodeCleanup
            )

            // Verify mechanically rather than trusting the prompt. Segments are
            // cleaned by independent calls, so one can come back romanized and
            // the next left in Devanagari or translated outright — the same
            // dictation, three different behaviours. Two failure modes:
            //   - script survived: output still has Devanagari or Arabic
            //   - translated: output no longer resembles the speaker's words
            func isWrong(_ text: String) -> String? {
                if Script.containsNonLatin(text) { return "script survived" }
                if Script.looksTranslated(original: transcript, output: text) { return "translated" }
                return nil
            }

            guard let problem = isWrong(cleaned) else { return cleaned }

            log.notice("cleanup \(problem, privacy: .public), retrying once")
            let retried = try await send(
                Groq.cleanupRetryRequest(
                    apiKey: cleanupKey,
                    model: Settings.cleanupModel,
                    transcript: transcript,
                    firstAttempt: cleaned,
                    vocabulary: Settings.vocabulary
                ),
                on: session,
                decode: Groq.decodeCleanup
            )
            if isWrong(retried) == nil { return retried }

            // Both attempts were wrong. ICU transliteration is less natural than
            // the model at its best, but it is deterministic: it can never
            // translate and can never leave script behind. Consistency beats
            // prettiness when the alternative is a transcript that is half
            // romanized and half Devanagari.
            log.notice("cleanup unreliable twice, falling back to deterministic transliteration")
            return Script.romanize(transcript)
        } catch {
            return transcript
        }
    }

    /// One retry on transient failures, then give up. Backoff is a flat 800ms —
    /// this is a single interactive request, not a queue worth exponential care.
    private func send(
        _ request: URLRequest, on session: URLSession, decode: (Data) throws -> String
    ) async throws -> String {
        do {
            return try await attempt(request, on: session, decode: decode)
        } catch let error as XFlowError where error.isRetryable {
            try? await Task.sleep(nanoseconds: 800_000_000)
            return try await attempt(request, on: session, decode: decode)
        }
    }

    private func attempt(
        _ request: URLRequest, on session: URLSession, decode: (Data) throws -> String
    ) async throws -> String {
        let leg = request.url?.lastPathComponent ?? "?"
        let sent = request.httpBody?.count ?? 0
        let start = Date()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // Never collapse this to one error again. Knowing whether the socket
            // timed out, was dropped mid-flight, or never had a route is the
            // whole difference between a slow API and a broken app.
            let code = (error as? URLError)?.code
            log.error("""
            \(leg, privacy: .public) FAILED after \(Self.seconds(since: start), privacy: .public)s \
            sent=\(sent, privacy: .public)B code=\(String(describing: code), privacy: .public)
            """)
            throw code == .timedOut ? XFlowError.timedOut : XFlowError.network
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        log.notice("""
        \(leg, privacy: .public) \(status, privacy: .public) in \
        \(Self.seconds(since: start), privacy: .public)s sent=\(sent, privacy: .public)B
        """)

        if let error = XFlowError.from(status: status, body: data) { throw error }
        return try decode(data)
    }

    private static func seconds(since start: Date) -> String {
        String(format: "%.2f", Date().timeIntervalSince(start))
    }
}
