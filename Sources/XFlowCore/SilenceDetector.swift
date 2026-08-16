import Foundation

/// Decides when the speaker has paused, from the same RMS values that drive the
/// waveform. Cutting segments at pauses rather than at fixed intervals is what
/// keeps a word from being sliced in half — the accuracy objection that ruled
/// out naive time-based chunking.
public struct SilenceDetector {
    /// How long the level must stay down before it counts as a pause.
    public let pauseDuration: TimeInterval
    /// Silence threshold as a multiple of the observed noise floor.
    public let sensitivity: Float

    /// ponytail: the floor tracks a decaying minimum rather than running a real
    /// noise estimator. Room tone, mic gain and background chatter all move the
    /// true floor, and a fixed dB threshold is wrong on every machine. Replace
    /// with a proper VAD only if this misfires in practice.
    public private(set) var noiseFloor: Float

    private var quietSince: TimeInterval?
    private var alreadyReported = false

    public init(
        pauseDuration: TimeInterval = 0.6,
        sensitivity: Float = 3,
        initialFloor: Float = 0.01
    ) {
        self.pauseDuration = pauseDuration
        self.sensitivity = sensitivity
        self.noiseFloor = initialFloor
    }

    /// Feed one RMS sample. Returns true on the single sample where a pause
    /// becomes confirmed, and false everywhere else — including for the rest of
    /// that same pause, so a caller cannot close two segments on one silence.
    public mutating func feed(rms: Float, at time: TimeInterval) -> Bool {
        // Drift up slowly so a room that gets noisier is tracked; snap down
        // immediately so a room that goes quiet is tracked at once.
        noiseFloor = max(0.0005, min(noiseFloor * 1.0005, max(rms, 0.0005)))

        guard rms < noiseFloor * sensitivity else {
            quietSince = nil
            alreadyReported = false
            return false
        }

        guard let start = quietSince else {
            quietSince = time
            return false
        }

        guard !alreadyReported, time - start >= pauseDuration else { return false }
        alreadyReported = true
        return true
    }
}
