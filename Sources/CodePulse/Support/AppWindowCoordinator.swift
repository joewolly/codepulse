import AppKit
import SwiftUI

@MainActor
final class AppWindowCoordinator: ObservableObject {
    private let store: SessionStore
    private var historyWindow: NSWindow?
    private var insightsWindow: NSWindow?

    init(store: SessionStore) {
        self.store = store
    }

    func showHistoryIfEnabled() {
        guard store.state.settings.globalShortcutEnabled else { return }
        showHistory()
    }

    func showHistory() {
        let window: NSWindow
        if let historyWindow {
            window = historyWindow
        } else {
            let content = HistoryView()
                .environmentObject(store)
            let hostingController = NSHostingController(rootView: content)
            let newWindow = NSWindow(contentViewController: hostingController)
            newWindow.title = "History"
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            newWindow.setContentSize(NSSize(width: 680, height: 540))
            newWindow.minSize = NSSize(width: 620, height: 460)
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            historyWindow = newWindow
            window = newWindow
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showInsights() {
        let window: NSWindow
        if let insightsWindow {
            window = insightsWindow
        } else if let existingWindow = NSApp.windows.first(where: { $0.title == "Insights" }) {
            insightsWindow = existingWindow
            window = existingWindow
        } else {
            let content = InsightsView()
                .environmentObject(store)
            let hostingController = NSHostingController(rootView: content)
            let newWindow = NSWindow(contentViewController: hostingController)
            newWindow.title = "Insights"
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            newWindow.setContentSize(NSSize(width: 760, height: 620))
            newWindow.minSize = NSSize(width: 640, height: 520)
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            insightsWindow = newWindow
            window = newWindow
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
