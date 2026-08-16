import AppKit

public struct ClipboardSwap {
    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    // ponytail: plain text only. Copy an image, dictate, and the image is gone
    // from the clipboard. Full multi-type restore means walking pasteboardItems
    // and re-adding every type — roughly 30 more lines. Add it if this bites.
    public func snapshot() -> String? {
        pasteboard.string(forType: .string)
    }

    public func write(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    public func restore(_ snapshot: String?) {
        pasteboard.clearContents()
        if let snapshot { pasteboard.setString(snapshot, forType: .string) }
    }
}
