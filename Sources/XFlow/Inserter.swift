import AppKit
import XFlowCore

enum Inserter {
    private static let commandVKeyCode: CGKeyCode = 9

    /// Writes the text to the clipboard, sends Cmd-V to the frontmost app, then
    /// restores the previous clipboard. Returns false when the paste could not
    /// be sent — in that case the text is left on the clipboard on purpose, so
    /// the user can paste it themselves and never loses a transcript.
    @discardableResult
    static func insert(_ text: String) async -> Bool {
        let swap = ClipboardSwap()

        guard Permissions.accessibility else {
            swap.write(text)
            return false
        }

        let previous = swap.snapshot()
        swap.write(text)

        // Give the target app a moment to observe the new pasteboard generation
        // before it is asked to read from it.
        try? await Task.sleep(nanoseconds: 80_000_000)
        postCommandV()

        // And a moment to actually read it before the clipboard is put back.
        try? await Task.sleep(nanoseconds: 150_000_000)
        swap.restore(previous)
        return true
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: commandVKeyCode, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: commandVKeyCode, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
