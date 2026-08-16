import Foundation

/// What one transcription produced: the model's own words, and the formatted
/// text the user receives. Both sides are kept because cleanup is verified
/// mechanically and can still be wrong — the raw side is the only record of
/// what was actually heard.
public struct Transcript: Equatable {
    public let raw: String
    public let cleaned: String

    public init(raw: String, cleaned: String) {
        self.raw = raw
        self.cleaned = cleaned
    }
}

/// Collects segment transcripts that complete in any order and joins them by
/// index. Concurrency means segment 3 can land before segment 1; the reader
/// must never see that.
public struct TranscriptAssembler {
    private var pieces: [Int: Transcript] = [:]
    private var failed: Set<Int> = []

    public init() {}

    public mutating func store(_ transcript: Transcript, at index: Int) {
        pieces[index] = transcript
        failed.remove(index)
    }

    public mutating func markFailed(at index: Int) {
        failed.insert(index)
    }

    /// Sorted so the caller can retry deterministically.
    public var failedIndices: [Int] { failed.sorted() }

    /// Each side is joined independently: a segment whose cleanup came back
    /// empty must not remove its raw text from the other side.
    public func assembled() -> Transcript {
        Transcript(raw: join { $0.raw }, cleaned: join { $0.cleaned })
    }

    private func join(_ side: (Transcript) -> String) -> String {
        pieces.keys.sorted()
            .compactMap { pieces[$0].map(side)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
