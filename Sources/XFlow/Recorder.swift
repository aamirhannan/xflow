import AVFoundation
import XFlowCore

/// Records to a temporary m4a and reports a normalised level for the waveform.
///
/// ponytail: AVAudioRecorder, not AVAudioEngine. The recorder encodes to a file
/// and hands us metering for free; the engine would mean owning buffers, format
/// conversion, and WAV encoding by hand. Switch only if streaming partial
/// transcripts is ever wanted.
final class Recorder {
    var onLevel: (Float) -> Void = { _ in }
    var onAutoStop: () -> Void = {}

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var capTimer: Timer?
    private var startedAt: Date?

    static func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        stopTimers()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xflow-\(UUID().uuidString).m4a")

        // 24kHz mono AAC: speech-grade, and small enough that upload time is
        // never the bottleneck.
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 24_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32_000,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.record()

        self.recorder = recorder
        self.startedAt = Date()

        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            self?.sampleLevel()
        }
        capTimer = Timer.scheduledTimer(
            withTimeInterval: RecordingPolicy.maximumDuration, repeats: false
        ) { [weak self] _ in
            self?.onAutoStop()
        }
    }

    /// Returns nil if nothing was recording. The caller owns the file and must
    /// delete it once uploaded.
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let recorder, let startedAt else { return nil }
        let url = recorder.url
        let duration = Date().timeIntervalSince(startedAt)

        recorder.stop()
        self.recorder = nil
        self.startedAt = nil
        stopTimers()

        return (url, duration)
    }

    private func sampleLevel() {
        guard let recorder else { return }
        recorder.updateMeters()

        // averagePower is dBFS, roughly -60 (silence) to 0 (clipping).
        let decibels = recorder.averagePower(forChannel: 0)
        let normalised = max(0, min(1, (decibels + 60) / 60))
        onLevel(normalised)
    }

    private func stopTimers() {
        meterTimer?.invalidate()
        capTimer?.invalidate()
        meterTimer = nil
        capTimer = nil
    }

    deinit { stopTimers() }
}
