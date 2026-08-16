import Foundation
import OSLog
import XFlowCore

/// Read with: log show --last 30m --predicate 'subsystem == "com.aamirhannan.xflow"'
private let log = Logger(subsystem: "com.aamirhannan.xflow", category: "transcriber")

/// Audio file in, finished text out. Owns both API calls and the retry policy.
struct Transcriber {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    func transcribe(fileURL: URL) async throws -> String {
        guard let apiKey = Keychain.apiKey else { throw XFlowError.noAPIKey }
        let audio = try Data(contentsOf: fileURL)

        let transcript = try await send(
            OpenAI.transcriptionRequest(
                apiKey: apiKey,
                model: Settings.sttModel,
                audio: audio,
                filename: fileURL.lastPathComponent
            ),
            decode: OpenAI.decodeTranscript
        )

        guard Settings.cleanupEnabled else { return transcript }

        // A failed cleanup must not lose the transcript. Devanagari beats nothing.
        do {
            return try await send(
                OpenAI.cleanupRequest(
                    apiKey: apiKey,
                    model: Settings.cleanupModel,
                    transcript: transcript
                ),
                decode: OpenAI.decodeCleanup
            )
        } catch {
            return transcript
        }
    }

    /// One retry on transient failures, then give up. Backoff is a flat 800ms —
    /// this is a single interactive request, not a queue worth exponential care.
    private func send(_ request: URLRequest, decode: (Data) throws -> String) async throws -> String {
        do {
            return try await attempt(request, decode: decode)
        } catch let error as XFlowError where error.isRetryable {
            try? await Task.sleep(nanoseconds: 800_000_000)
            return try await attempt(request, decode: decode)
        }
    }

    private func attempt(_ request: URLRequest, decode: (Data) throws -> String) async throws -> String {
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
        log.info("""
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
