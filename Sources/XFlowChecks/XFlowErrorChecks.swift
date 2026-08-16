import Foundation
import XFlowCore

func checkXFlowError() {
    Checks.equal(XFlowError.from(status: 200, body: Data()), nil, "2xx produces no error")
    Checks.equal(XFlowError.from(status: 401, body: Data()), .invalidKey, "401 is an invalid key")
    Checks.equal(XFlowError.from(status: 429, body: Data()), .rateLimited, "429 is rate limited")

    Checks.equal(XFlowError.from(status: 404, body: Data(#"{"error":{"message":"model not found"}}"#.utf8)),
                 .server("model not found"),
                 "other errors carry the server message")

    Checks.equal(XFlowError.from(status: 500, body: Data("<html>oops</html>".utf8)),
                 .server("HTTP 500"),
                 "unparseable error body still produces an error")

    Checks.equal(XFlowError.rateLimited.isRetryable, true, "rate limit is retryable")
    Checks.equal(XFlowError.network.isRetryable, true, "network failure is retryable")
    Checks.equal(XFlowError.server("boom").isRetryable, true, "server error is retryable")
    Checks.equal(XFlowError.invalidKey.isRetryable, false, "invalid key is not retryable")
    Checks.equal(XFlowError.noAPIKey.isRetryable, false, "missing key is not retryable")
    Checks.equal(XFlowError.emptyTranscript.isRetryable, false, "empty transcript is not retryable")

    // A timeout must stay distinct from "no network" — collapsing them is what
    // made the 60-second hang undiagnosable in the first place.
    Checks.check(XFlowError.timedOut != XFlowError.network, "timeout is not the same error as no network")

    let all: [XFlowError] = [
        .noAPIKey, .invalidKey, .rateLimited, .server("x"), .emptyTranscript, .decoding, .network, .timedOut,
    ]
    for error in all {
        Checks.check(!error.userMessage.isEmpty, "\(error) has a user message")
    }
}
