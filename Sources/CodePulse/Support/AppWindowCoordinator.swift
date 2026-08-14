import AppKit
import SwiftUI

@MainActor
final class AppWindowCoordinator: ObservableObject {
    private let store: SessionStore
    private var historyWindow: NSWindow?
    private var insightsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var recoveryWindow: NSWindow?

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

    func showOnboardingIfNeeded() {
        guard !store.isInRecoveryMode, store.shouldPresentOnboarding else { return }
        showOnboarding()
    }

    func showOnboarding() {
        let window: NSWindow
        if let onboardingWindow, onboardingWindow.isVisible {
            window = onboardingWindow
        } else {
            let content = OnboardingView { [weak self] in
                self?.onboardingWindow?.close()
            }
            .environmentObject(store)
            let hostingController = NSHostingController(rootView: content)
            let newWindow = NSWindow(contentViewController: hostingController)
            newWindow.title = "Getting Started with CodePulse"
            newWindow.styleMask = [.titled, .closable]
            newWindow.setContentSize(NSSize(width: 540, height: 470))
            newWindow.minSize = NSSize(width: 540, height: 470)
            newWindow.isReleasedWhenClosed = false
            newWindow.isRestorable = false
            newWindow.center()
            onboardingWindow = newWindow
            window = newWindow
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showRecoveryIfNeeded() {
        guard store.isInRecoveryMode else { return }
        showRecovery()
    }

    func showRecovery() {
        let window: NSWindow
        if let recoveryWindow, recoveryWindow.isVisible {
            window = recoveryWindow
        } else {
            let closeRecovery: () -> Void = { [weak self] in
                self?.recoveryWindow?.close()
            }
            let content = RecoveryView(
                onRecovered: closeRecovery,
                onDismiss: closeRecovery
            )
            .environmentObject(store)
            let hostingController = NSHostingController(rootView: content)
            let newWindow = NSWindow(contentViewController: hostingController)
            newWindow.title = "CodePulse Recovery"
            newWindow.styleMask = [.titled, .closable, .resizable]
            newWindow.setContentSize(NSSize(width: 620, height: 300))
            newWindow.minSize = NSSize(width: 620, height: 300)
            newWindow.isReleasedWhenClosed = false
            newWindow.isRestorable = false
            newWindow.center()
            recoveryWindow = newWindow
            window = newWindow
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
