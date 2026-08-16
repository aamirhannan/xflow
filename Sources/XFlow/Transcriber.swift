import Foundation
import XFlowCore

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
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw XFlowError.network
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if let error = XFlowError.from(status: status, body: data) { throw error }
        return try decode(data)
    }
}
