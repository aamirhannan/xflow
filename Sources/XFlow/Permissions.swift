import AppKit
import ApplicationServices
import AVFoundation
import IOKit.hid

enum Permissions {
    // Checked directly rather than through Recorder, so the setup interface and
    // the audio pipeline never reference each other.
    static var microphone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// Required to post the synthetic Cmd-V and to observe keys globally.
    static var accessibility: Bool { AXIsProcessTrusted() }

    /// Some macOS versions require this separately from Accessibility.
    static var inputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static var allGranted: Bool { microphone && accessibility && inputMonitoring }

    static func openSettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }
}
