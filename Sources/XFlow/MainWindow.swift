import AppKit
import SwiftUI
import XFlowCore

enum Page: String, CaseIterable, Identifiable {
    case home = "Home"
    case settings = "Settings"
    var id: String { rawValue }
}

/// Shared between AppKit, which needs to switch pages from a menu item, and
/// SwiftUI, which needs to react when it does.
final class WindowModel: ObservableObject {
    @Published var page: Page = .home
    @Published var showingOnboarding = false
    let store: HistoryStore

    init(store: HistoryStore) { self.store = store }
}

struct RootView: View {
    @ObservedObject var model: WindowModel

    var body: some View {
        if model.showingOnboarding {
            OnboardingView(onFinish: { model.showingOnboarding = false })
        } else {
            VStack(spacing: 0) {
                Picker("", selection: $model.page) {
                    ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .padding(12)

                Divider()

                switch model.page {
                case .home:
                    HomeView(store: model.store)
                case .settings:
                    SettingsView(
                        store: model.store,
                        onRerunSetup: { model.showingOnboarding = true }
                    )
                }
            }
        }
    }
}

/// The app's only window. AppKit owns the frame; everything inside is SwiftUI.
///
/// It replaces the old setup window, which was 210 lines of hand-rolled
/// NSStackView for a form. The deployment target is macOS 14, so there is no
/// reason to keep laying out views by hand.
final class MainWindow: NSObject {
    private let window: NSWindow
    private let model: WindowModel

    init(store: HistoryStore) {
        model = WindowModel(store: store)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "XFlow"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 720, height: 480)
        window.setFrameAutosaveName("XFlowMainWindow")
        window.contentView = NSHostingView(rootView: RootView(model: model))
    }

    func show(_ page: Page = .home) {
        model.page = page
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showSettings() { show(.settings) }

    func showOnboarding() {
        model.showingOnboarding = true
        show(.home)
    }
}
