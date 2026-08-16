import Foundation
import OSLog

private let log = Logger(subsystem: "com.aamirhannan.xflow", category: "history")

/// Append-only dictation history, one JSON object per line.
///
/// Every operation is non-throwing on purpose. History must never be able to
/// break dictation: by the time `record` runs, the text has already been pasted,
/// so a full disk or a bad permission is worth a log line and nothing more.
///
/// ponytail: no in-memory cache and no change notifications. `all()` reads the
/// whole file, which is milliseconds at the scale this reaches (roughly 18MB
/// after a year of heavy use). Add a cache when the dashboard has to update
/// while it is open.
public final class HistoryStore {
    public static let defaultFileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("XFlow", isDirectory: true)
            .appendingPathComponent("history.jsonl")
    }()

    private let fileURL: URL

    /// Serialises every access. Writes are async so the caller never waits on
    /// disk; reads are sync and therefore always see the writes queued ahead.
    private let queue = DispatchQueue(label: "com.aamirhannan.xflow.history")

    public init(fileURL: URL = HistoryStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    public func record(_ record: DictationRecord) {
        queue.async { [fileURL] in
            do {
                let line = try HistoryLog.line(for: record) + "\n"
                try Self.createIfMissing(at: fileURL)
                let handle = try FileHandle(forWritingTo: fileURL)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } catch {
                log.error("history append failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Newest first, which is the order every screen wants.
    public func all() -> [DictationRecord] {
        queue.sync { Array(Self.read(from: fileURL).reversed()) }
    }

    public func delete(id: UUID) {
        queue.sync {
            let kept = Self.read(from: fileURL).filter { $0.id != id }
            Self.overwrite(fileURL, with: kept)
        }
    }

    public func deleteAll() {
        queue.sync {
            do {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
            } catch {
                log.error("history delete-all failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Disk

    private static func read(from url: URL) -> [DictationRecord] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return HistoryLog.records(from: contents)
    }

    private static func overwrite(_ url: URL, with records: [DictationRecord]) {
        let body = records.compactMap { try? HistoryLog.line(for: $0) }.joined(separator: "\n")
        let text = body.isEmpty ? "" : body + "\n"
        do {
            try createIfMissing(at: url)
            try text.write(to: url, atomically: true, encoding: .utf8)
            // An atomic write replaces the file rather than editing it, and the
            // replacement is created with the process umask — so without this the
            // history would quietly become world-readable on its first rewrite.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            log.error("history rewrite failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func createIfMissing(at url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        if !manager.fileExists(atPath: url.path) {
            manager.createFile(
                atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]
            )
        }
    }
}
