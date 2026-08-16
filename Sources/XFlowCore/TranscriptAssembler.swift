import Foundation

/// Collects segment transcripts that complete in any order and joins them by
/// index. Concurrency means segment 3 can land before segment 1; the reader
/// must never see that.
public struct TranscriptAssembler {
    private var pieces: [Int: String] = [:]
    private var failed: Set<Int> = []

    public init() {}

    public mutating func store(_ text: String, at index: Int) {
        pieces[index] = text
        failed.remove(index)
    }

    public mutating func markFailed(at index: Int) {
        failed.insert(index)
    }

    /// Sorted so the caller can retry deterministically.
    public var failedIndices: [Int] { failed.sorted() }

    public func assembled() -> String {
        pieces.keys.sorted()
            .compactMap { pieces[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
