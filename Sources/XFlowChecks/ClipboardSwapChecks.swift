import AppKit
import XFlowCore

func checkClipboardSwap() {
    // A private named pasteboard, so the checks never touch the real clipboard.
    func makeTestPasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.aamirhannan.xflow.checks"))
        pasteboard.clearContents()
        return pasteboard
    }

    Checks.equal(ClipboardSwap(pasteboard: makeTestPasteboard()).snapshot(), nil,
                 "snapshot is nil when the clipboard is empty")

    let roundTrip = ClipboardSwap(pasteboard: makeTestPasteboard())
    roundTrip.write("mujhe yeh chahiye")
    Checks.equal(roundTrip.snapshot(), "mujhe yeh chahiye", "write then snapshot round-trips")

    let swap = ClipboardSwap(pasteboard: makeTestPasteboard())
    swap.write("original")
    let saved = swap.snapshot()
    swap.write("transcript")
    Checks.equal(swap.snapshot(), "transcript", "the transcript overwrites the clipboard")
    swap.restore(saved)
    Checks.equal(swap.snapshot(), "original", "restore puts the previous text back")

    let clearing = ClipboardSwap(pasteboard: makeTestPasteboard())
    clearing.write("transcript")
    clearing.restore(nil)
    Checks.equal(clearing.snapshot(), nil, "restoring nil clears the clipboard")
}
