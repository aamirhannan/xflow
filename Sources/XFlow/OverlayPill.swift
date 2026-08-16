import AppKit

/// A non-activating floating capsule showing recording state.
///
/// The non-activating behaviour is not cosmetic: if this panel takes key focus,
/// the synthetic Cmd-V lands here instead of in the user's text field. That is
/// the single most common way a tool like this breaks.
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Draws a row of bars from a rolling window of recent audio levels.
private final class WaveformView: NSView {
    private var levels: [Float] = Array(repeating: 0, count: 24)
    var label: String?

    func push(_ level: Float) {
        levels.removeFirst()
        levels.append(level)
        needsDisplay = true
    }

    func reset() {
        levels = Array(repeating: 0, count: levels.count)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.withAlphaComponent(0.9).setFill()

        if let label {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                withAttributes: attributes
            )
            return
        }

        let barWidth: CGFloat = 3
        let gap: CGFloat = 3
        let totalWidth = CGFloat(levels.count) * barWidth + CGFloat(levels.count - 1) * gap
        var x = (bounds.width - totalWidth) / 2

        for level in levels {
            let height = max(3, CGFloat(level) * (bounds.height - 12))
            let rect = NSRect(x: x, y: (bounds.height - height) / 2, width: barWidth, height: height)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + gap
        }
    }
}

final class OverlayPill {
    private let panel: NonActivatingPanel
    private let waveform = WaveformView()
    private var hideWorkItem: DispatchWorkItem?

    init() {
        panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 48),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        let background = NSVisualEffectView(frame: panel.contentView!.bounds)
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 24
        background.layer?.masksToBounds = true
        background.autoresizingMask = [.width, .height]

        waveform.frame = background.bounds
        waveform.autoresizingMask = [.width, .height]
        background.addSubview(waveform)

        panel.contentView = background
    }

    func showRecording() {
        waveform.label = nil
        waveform.reset()
        present()
    }

    func update(level: Float) {
        waveform.push(level)
    }

    func showTranscribing() {
        waveform.label = "Transcribing…"
        waveform.needsDisplay = true
        present()
    }

    /// Errors and refusals. Auto-hides so a failure never leaves a stuck pill.
    func showMessage(_ text: String) {
        waveform.label = text
        waveform.needsDisplay = true
        present()
        scheduleHide(after: 2.5)
    }

    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        panel.orderOut(nil)
    }

    private func present() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        positionAboveBottomEdge()
        // orderFrontRegardless keeps the pill visible without activating the app.
        panel.orderFrontRegardless()
    }

    private func scheduleHide(after seconds: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func positionAboveBottomEdge() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 120
        ))
    }
}
