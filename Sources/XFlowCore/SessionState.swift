import Foundation

public enum SessionState: Equatable, Sendable {
    case idle
    case recording(startedAt: Date)
    case transcribing
    case inserting
}

public enum SessionEvent: Equatable, Sendable {
    case hotkeyDown
    case hotkeyUp
    case transcriptReady
    case inserted
    case failed
}

extension SessionState {
    /// Every transition in the app. Anything not listed here is a stray event
    /// and leaves the state untouched — the OS can deliver a key-up we never
    /// saw the key-down for, and that must not corrupt the session.
    public func next(on event: SessionEvent, now: Date) -> SessionState {
        if event == .failed { return .idle }

        switch (self, event) {
        case (.idle, .hotkeyDown):              return .recording(startedAt: now)
        case (.recording, .hotkeyUp):           return .transcribing
        case (.transcribing, .transcriptReady): return .inserting
        case (.inserting, .inserted):           return .idle
        default:                                return self
        }
    }
}

public enum RecordingPolicy {
    /// Below this, the user tapped fn by accident. Discard without an API call.
    public static let minimumDuration: TimeInterval = 0.4
    /// Hard stop, in case a key-up event is ever missed and recording sticks on.
    public static let maximumDuration: TimeInterval = 120

    public static func shouldTranscribe(duration: TimeInterval) -> Bool {
        duration >= minimumDuration
    }
}
