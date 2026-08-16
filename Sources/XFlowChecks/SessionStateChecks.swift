import Foundation
import XFlowCore

func checkSessionState() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    Checks.equal(SessionState.idle.next(on: .hotkeyDown, now: t0),
                 .recording(startedAt: t0),
                 "hotkey down starts recording")

    Checks.equal(SessionState.recording(startedAt: t0).next(on: .hotkeyUp, now: t0),
                 .transcribing,
                 "hotkey up moves to transcribing")

    Checks.equal(SessionState.transcribing.next(on: .transcriptReady, now: t0),
                 .inserting,
                 "transcript ready moves to inserting")

    Checks.equal(SessionState.inserting.next(on: .inserted, now: t0),
                 .idle,
                 "inserted returns to idle")

    for state in [SessionState.idle, .recording(startedAt: t0), .transcribing, .inserting] {
        Checks.equal(state.next(on: .failed, now: t0), .idle,
                     "failure from \(state) returns to idle")
    }

    // A second hotkeyDown while already recording must not restart the clock.
    let recording = SessionState.recording(startedAt: t0)
    Checks.equal(recording.next(on: .hotkeyDown, now: t0.addingTimeInterval(5)), recording,
                 "duplicate hotkey down is ignored")
    // A hotkeyUp with no recording in progress must do nothing.
    Checks.equal(SessionState.idle.next(on: .hotkeyUp, now: t0), .idle,
                 "stray hotkey up is ignored")

    Checks.equal(RecordingPolicy.shouldTranscribe(duration: 0.39), false, "0.39s is too short")
    Checks.equal(RecordingPolicy.shouldTranscribe(duration: 0.4), true, "0.4s is long enough")
    Checks.equal(RecordingPolicy.shouldTranscribe(duration: 3.0), true, "3s is long enough")

    Checks.equal(RecordingPolicy.minimumDuration, 0.4, "minimum duration matches the spec")
    Checks.equal(RecordingPolicy.maximumDuration, 120, "maximum duration matches the spec")
}
