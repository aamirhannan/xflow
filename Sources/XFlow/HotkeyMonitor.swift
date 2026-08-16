import AppKit

/// Watches the fn / Globe key and reports press and release.
///
/// ponytail: NSEvent monitors, not a CGEventTap. A tap needs a run-loop source
/// and gets silently disabled by the OS on timeout, for one benefit we do not
/// need — swallowing the keystroke. Instead the user sets System Settings >
/// Keyboard > "Press Globe key to" > Do Nothing. Upgrade to CGEventTap only if
/// the keystroke ever has to be consumed.
///
/// Requires Accessibility (and on some macOS versions Input Monitoring) to be
/// granted. Without it, start() silently succeeds and no events ever arrive —
/// which is why Settings checks the grants explicitly.
final class HotkeyMonitor {
    var onDown: () -> Void = {}
    var onUp: () -> Void = {}

    private static let fnKeyCode: UInt16 = 63

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isDown = false

    func start() {
        stop()
        // Global fires only when another app is frontmost; local covers the case
        // where our own settings window has focus.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        [globalMonitor, localMonitor].compactMap { $0 }.forEach(NSEvent.removeMonitor)
        globalMonitor = nil
        localMonitor = nil
        isDown = false
    }

    private func handle(_ event: NSEvent) {
        // .function is also set by arrow and F-keys, so the key code check is
        // what actually isolates the Globe key.
        guard event.keyCode == Self.fnKeyCode else { return }

        let down = event.modifierFlags.contains(.function)
        guard down != isDown else { return }
        isDown = down

        if down { onDown() } else { onUp() }
    }

    deinit { stop() }
}
