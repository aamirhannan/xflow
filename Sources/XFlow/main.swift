import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// .accessory matches LSUIElement in Info.plist: no Dock icon, and the app never
// becomes frontmost, which is what lets the synthetic paste reach the real target.
app.setActivationPolicy(.accessory)
app.run()
