import AVFoundation
import XFlowCore

/// Records continuously while handing completed segments to the caller mid-
/// dictation, so transcription overlaps with speaking.
///
/// This is the upgrade the `ponytail:` note in Recorder.swift predicted:
/// AVAudioRecorder cannot surface audio before it stops, so the engine is now
/// justified. Recorder.swift stays for the single-shot kill switch.
final class SegmentingRecorder {
    var onLevel: (Float) -> Void = { _ in }
    /// Called on the main queue with a finished segment file and its index.
    /// The caller owns the file and must delete it once uploaded.
    var onSegment: (URL, Int) -> Void = { _, _ in }
    var onAutoStop: () -> Void = {}

    private let engine = AVAudioEngine()

    /// Guards everything the audio tap touches. The tap runs on a real-time
    /// thread while start/stop run on main, so without this, stopping mid-buffer
    /// could tear down a file a write is already inside — a crash that costs the
    /// user their words.
    ///
    /// ponytail: one lock for all of the state rather than per-field atomics. The
    /// tap already does AAC encoding and disk I/O on that thread, so an
    /// uncontended lock is not what makes it slow. Move the writes to a serial
    /// queue only if buffer drops ever show up.
    private let lock = NSLock()

    private var detector = SilenceDetector()
    private var segmentFile: AVAudioFile?
    private var segmentIndex = 0
    private var segmentStart: TimeInterval = 0
    private var elapsed: TimeInterval = 0
    private var startedAt: Date?
    private var capTimer: Timer?

    /// The whole session, written to its own file alongside the segments, so a
    /// segment that failed to transcribe can be recovered by re-sending
    /// everything.
    ///
    /// ponytail: a second AAC encode rather than retaining PCM in memory. Tap
    /// buffers are reused by the engine, so keeping them would mean copying every
    /// one — ~11MB resident for a 120s session — where a parallel 32kbps file
    /// costs ~0.5MB on disk and no copies at all.
    private var fullFile: AVAudioFile?
    private var fullURL: URL?

    /// 24kHz mono would be smaller, but `AVAudioFile.write(from:)` rejects any
    /// buffer whose format differs from the file's processing format, and the tap
    /// hands us the input device's own rate. Matching it is what keeps the write
    /// legal; at 32kbps the size difference never matters.
    private func outputSettings(for format: AVAudioFormat) -> [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderBitRateKey: 32_000,
        ]
    }

    func start() throws {
        reset()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        lock.lock()
        do {
            segmentFile = try makeFile(prefix: "seg", format: format)
            let full = try makeFile(prefix: "full", format: format)
            fullFile = full
            fullURL = full.url
        } catch {
            segmentFile = nil
            fullFile = nil
            lock.unlock()
            throw error
        }
        lock.unlock()

        startedAt = Date()

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer, format: format)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            discardFiles()
            startedAt = nil
            throw error
        }

        capTimer = Timer.scheduledTimer(
            withTimeInterval: RecordingPolicy.maximumDuration, repeats: false
        ) { [weak self] _ in
            self?.onAutoStop()
        }
    }

    /// Stops the engine and returns the still-unsent tail segment.
    func stop() -> (tail: URL?, tailIndex: Int, duration: TimeInterval)? {
        guard let startedAt else { return nil }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        capTimer?.invalidate()
        capTimer = nil

        lock.lock()
        let tailURL = segmentFile?.url
        let index = segmentIndex
        // Releasing the file handles is what flushes and finalises the AAC
        // containers, so nothing may read either file before this.
        segmentFile = nil
        fullFile = nil
        lock.unlock()

        self.startedAt = nil

        return (tailURL, index, Date().timeIntervalSince(startedAt))
    }

    /// The whole session as one file, for the fallback when a segment failed.
    /// Only valid after `stop()` has finalised it. The caller owns the file and
    /// must delete it.
    func rebuildFullAudio() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard fullFile == nil, let url = fullURL else { return nil }
        fullURL = nil
        return url
    }

    // MARK: - Internals

    private func handle(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        var sum: Float = 0
        for i in 0..<frames { sum += channel[i] * channel[i] }
        let rms = (sum / Float(frames)).squareRoot()

        lock.lock()
        elapsed += Double(frames) / format.sampleRate

        try? segmentFile?.write(from: buffer)
        try? fullFile?.write(from: buffer)

        let pause = detector.feed(rms: rms, at: elapsed)
        let duration = elapsed - segmentStart

        let finished = SegmentPolicy.shouldClose(segmentDuration: duration, pauseDetected: pause)
            ? closeSegmentLocked(format: format)
            : nil
        lock.unlock()

        DispatchQueue.main.async {
            self.onLevel(min(1, rms * 6))
            if let finished { self.onSegment(finished.url, finished.index) }
        }
    }

    /// Caller must hold `lock`.
    private func closeSegmentLocked(format: AVAudioFormat) -> (url: URL, index: Int)? {
        guard let finished = segmentFile?.url else { return nil }
        let index = segmentIndex

        // Dropping the reference finalises the file before anyone reads it.
        segmentFile = nil
        segmentIndex += 1
        segmentStart = elapsed
        segmentFile = try? makeFile(prefix: "seg", format: format)

        return (finished, index)
    }

    private func makeFile(prefix: String, format: AVAudioFormat) throws -> AVAudioFile {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("xflow-\(prefix)-\(UUID().uuidString).m4a")
        return try AVAudioFile(
            forWriting: url, settings: outputSettings(for: format),
            commonFormat: format.commonFormat, interleaved: format.isInterleaved
        )
    }

    private func discardFiles() {
        lock.lock()
        let leftovers = [segmentFile?.url, fullURL].compactMap { $0 }
        segmentFile = nil
        fullFile = nil
        fullURL = nil
        lock.unlock()
        for url in leftovers { try? FileManager.default.removeItem(at: url) }
    }

    private func reset() {
        // A session whose fallback was never needed leaves its full file behind;
        // clear it here so at most one ever sits in the temp directory.
        discardFiles()

        lock.lock()
        detector = SilenceDetector()
        segmentIndex = 0
        segmentStart = 0
        elapsed = 0
        lock.unlock()
    }

    deinit {
        capTimer?.invalidate()
    }
}
