import Foundation
import XFlowCore

func checkSilenceDetector() {
    // Speech at 0.5 RMS, then quiet at 0.005. A pause is confirmed only after
    // 600ms of continuous quiet, and only reported once.
    var detector = SilenceDetector(pauseDuration: 0.6, sensitivity: 3, initialFloor: 0.01)

    var firedDuringSpeech = false
    for i in 0..<20 {
        if detector.feed(rms: 0.5, at: Double(i) * 0.05) { firedDuringSpeech = true }
    }
    Checks.equal(firedDuringSpeech, false, "speech never reports a pause")

    var fireTimes: [Double] = []
    for i in 20..<60 {
        let t = Double(i) * 0.05
        if detector.feed(rms: 0.005, at: t) { fireTimes.append(t) }
    }
    Checks.equal(fireTimes.count, 1, "a pause is reported exactly once, not every sample")
    if let first = fireTimes.first {
        // Quiet began at 1.00s, so confirmation lands at 1.60s give or take a sample.
        Checks.check(first >= 1.55 && first <= 1.70,
                     "pause confirms after the configured 600ms, not sooner")
    }

    // A short gap between words must not be mistaken for a pause.
    var shortGap = SilenceDetector(pauseDuration: 0.6, sensitivity: 3, initialFloor: 0.01)
    for i in 0..<20 { _ = shortGap.feed(rms: 0.5, at: Double(i) * 0.05) }
    var firedOnShortGap = false
    for i in 20..<26 {  // 300ms of quiet only
        if shortGap.feed(rms: 0.005, at: Double(i) * 0.05) { firedOnShortGap = true }
    }
    Checks.equal(firedOnShortGap, false, "a 300ms gap is not a pause")

    // Resuming speech re-arms the detector for the next pause.
    for i in 26..<40 { _ = shortGap.feed(rms: 0.5, at: Double(i) * 0.05) }
    var firedAfterResume = false
    for i in 40..<70 {
        if shortGap.feed(rms: 0.005, at: Double(i) * 0.05) { firedAfterResume = true }
    }
    Checks.equal(firedAfterResume, true, "the detector re-arms after speech resumes")

    // Regression guard for the bug that made segmentation fall back on its
    // 30-second safety net. Speech contains near-silent gaps between syllables.
    // If the noise floor is allowed to snap down to those gaps, it collapses to
    // the global minimum and the threshold lands BELOW the level of a real
    // pause — so genuine pauses read as loud and never close a segment.
    // Here the pause (0.02) is deliberately louder than the inter-syllable
    // gaps (0.004): the old snap-down floor found zero pauses in this sequence.
    var syllables = SilenceDetector(pauseDuration: 0.6, sensitivity: 3, initialFloor: 0.01)
    for i in 0..<60 {
        _ = syllables.feed(rms: i % 2 == 0 ? 0.15 : 0.004, at: Double(i) * 0.05)
    }
    var foundRealPause = false
    for i in 60..<90 {
        if syllables.feed(rms: 0.02, at: Double(i) * 0.05) { foundRealPause = true }
    }
    Checks.equal(foundRealPause, true,
                 "a real pause is detected even when speech has quieter gaps between syllables")

    // In a noisy room the floor rises, so absolute thresholds would never fire.
    var noisy = SilenceDetector(pauseDuration: 0.6, sensitivity: 3, initialFloor: 0.01)
    for i in 0..<40 { _ = noisy.feed(rms: 0.30, at: Double(i) * 0.05) }
    for i in 40..<80 { _ = noisy.feed(rms: 0.08, at: Double(i) * 0.05) }
    Checks.check(noisy.noiseFloor >= 0.01, "the noise floor adapts upward in a noisy room")
}

func checkSegmentPolicy() {
    // Groq bills a 10-second minimum per request, so closing earlier than that
    // pays for silence. This constant is a billing fact, not a preference.
    Checks.equal(SegmentPolicy.minimumDuration, 10, "minimum segment matches groq billing floor")
    Checks.equal(SegmentPolicy.forceCloseAfter, 30, "a segment is force-closed at 30s")

    Checks.equal(SegmentPolicy.shouldClose(segmentDuration: 12, pauseDetected: true), true,
                 "a pause past the floor closes the segment")
    Checks.equal(SegmentPolicy.shouldClose(segmentDuration: 4, pauseDetected: true), false,
                 "a pause below the floor does not close the segment")
    Checks.equal(SegmentPolicy.shouldClose(segmentDuration: 12, pauseDetected: false), false,
                 "no pause means no close while under the force limit")
    Checks.equal(SegmentPolicy.shouldClose(segmentDuration: 30, pauseDetected: false), true,
                 "a segment with no pause is force-closed at the limit")
    Checks.equal(SegmentPolicy.shouldClose(segmentDuration: 45, pauseDetected: false), true,
                 "past the force limit it still closes")
}

func checkTranscriptAssembler() {
    // Segments finish out of order because they run concurrently. Order in the
    // output must follow the index, never completion time.
    var assembler = TranscriptAssembler()
    assembler.store(Transcript(raw: "doosra bhag", cleaned: "second part"), at: 1)
    assembler.store(Transcript(raw: "pehla bhag", cleaned: "first part"), at: 0)
    assembler.store(Transcript(raw: "teesra bhag", cleaned: "third part"), at: 2)
    Checks.equal(assembler.assembled().cleaned, "first part second part third part",
                 "segments assemble in index order, not completion order")
    // Both sides are joined independently, so the raw text stays usable as a
    // fallback even when it reads nothing like the cleaned output.
    Checks.equal(assembler.assembled().raw, "pehla bhag doosra bhag teesra bhag",
                 "the raw side assembles in index order too")

    let empty = TranscriptAssembler()
    Checks.equal(empty.assembled(), Transcript(raw: "", cleaned: ""),
                 "nothing stored assembles to empty on both sides")
    Checks.equal(empty.failedIndices, [], "nothing stored has no failures")

    var withGap = TranscriptAssembler()
    withGap.store(Transcript(raw: "zero", cleaned: "zero"), at: 0)
    withGap.store(Transcript(raw: "two", cleaned: "two"), at: 2)
    Checks.equal(withGap.assembled().cleaned, "zero two", "a missing index is skipped, not padded")

    var failing = TranscriptAssembler()
    failing.store(Transcript(raw: "zero", cleaned: "zero"), at: 0)
    failing.markFailed(at: 1)
    failing.store(Transcript(raw: "two", cleaned: "two"), at: 2)
    Checks.equal(failing.failedIndices, [1], "a failed segment is tracked by index")

    // A segment that failed and was later retried successfully is no longer failed.
    failing.store(Transcript(raw: "one", cleaned: "one"), at: 1)
    Checks.equal(failing.failedIndices, [], "a recovered segment clears its failure")
    Checks.equal(failing.assembled().cleaned, "zero one two", "recovered text lands in the right place")

    // Blank results must not produce double spaces.
    var blanks = TranscriptAssembler()
    blanks.store(Transcript(raw: "zero", cleaned: "zero"), at: 0)
    blanks.store(Transcript(raw: "   ", cleaned: "   "), at: 1)
    blanks.store(Transcript(raw: "two", cleaned: "two"), at: 2)
    Checks.equal(blanks.assembled().cleaned, "zero two",
                 "blank segments do not leave gaps in the text")

    // One side blank and the other not is normal: cleanup can return nothing
    // useful for a segment whose raw transcript is fine.
    var lopsided = TranscriptAssembler()
    lopsided.store(Transcript(raw: "kuch to hai", cleaned: ""), at: 0)
    lopsided.store(Transcript(raw: "aur bhi", cleaned: "and more"), at: 1)
    Checks.equal(lopsided.assembled().raw, "kuch to hai aur bhi", "a blank cleaned side does not drop the raw text")
    Checks.equal(lopsided.assembled().cleaned, "and more", "a blank cleaned piece is skipped on its own side only")
}
