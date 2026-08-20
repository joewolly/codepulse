import AppKit
import SwiftUI

@MainActor
final class AppWindowCoordinator: ObservableObject {
    private static let insightsMinimumContentSize = NSSize(width: 740, height: 540)
    static let settingsDefaultContentSize = NSSize(width: 560, height: 520)
    static let settingsMinimumContentSize = NSSize(width: 540, height: 480)
    static let onboardingContentSize = NSSize(width: 540, height: 490)

    private let store: SessionStore
    private var historyWindow: NSWindow?
    private var insightsWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var recoveryWindow: NSWindow?
    private var settingsContentFactory: (() -> NSViewController)?
    private var settingsWindowMinimumDelegate: SettingsWindowMinimumDelegate?

    init(store: SessionStore) {
        self.store = store
    }

    func configureSettingsWindow(contentFactory: @escaping () -> NSViewController) {
        settingsContentFactory = contentFactory
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
            newWindow.contentMinSize = NSSize(width: 740, height: 520)
            newWindow.setContentSize(NSSize(width: 880, height: 600))
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
            newWindow.toolbarStyle = .unified
            newWindow.setContentSize(NSSize(width: 880, height: 640))
            newWindow.contentMinSize = Self.insightsMinimumContentSize
            newWindow.isReleasedWhenClosed = false
            newWindow.center()
            insightsWindow = newWindow
            window = newWindow
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // Reapply the minimum for reused or pre-existing Insights windows.
        window.contentMinSize = Self.insightsMinimumContentSize
    }

    func showSettings() {
        let window: NSWindow
        if let settingsWindow {
            window = settingsWindow
        } else if let existingWindow = NSApp.windows.first(where: { $0.title == "Settings" }) {
            settingsWindow = existingWindow
            window = existingWindow
        } else {
            guard let settingsContentFactory else { return }
            let newWindow = NSWindow(contentViewController: settingsContentFactory())
            newWindow.title = "Settings"
            newWindow.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            newWindow.toolbarStyle = .unified
            newWindow.setContentSize(Self.settingsDefaultContentSize)
            newWindow.contentMinSize = Self.settingsMinimumContentSize
            newWindow.isReleasedWhenClosed = false
            newWindow.isRestorable = false
            newWindow.center()
            settingsWindow = newWindow
            window = newWindow
        }

        // Keep the Settings selector in the same native chrome layer when a
        // previously created or externally supplied Settings window is reused.
        window.toolbarStyle = .unified
        configureSettingsMinimumDelegate(for: window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        applySettingsMinimumSize(to: window)
    }

    private func configureSettingsMinimumDelegate(for window: NSWindow) {
        if settingsWindowMinimumDelegate == nil {
            settingsWindowMinimumDelegate = SettingsWindowMinimumDelegate(
                contentMinimumSize: Self.settingsMinimumContentSize
            )
        }
        if window.delegate == nil {
            window.delegate = settingsWindowMinimumDelegate
        }
    }

    private func applySettingsMinimumSize(to window: NSWindow) {
        let contentMinimumSize = Self.settingsMinimumContentSize
        window.contentMinSize = contentMinimumSize
        window.minSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: contentMinimumSize)
        ).size
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
            newWindow.setContentSize(Self.onboardingContentSize)
            newWindow.contentMinSize = Self.onboardingContentSize
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

private final class SettingsWindowMinimumDelegate: NSObject, NSWindowDelegate {
    private let contentMinimumSize: NSSize

    init(contentMinimumSize: NSSize) {
        self.contentMinimumSize = contentMinimumSize
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        applyMinimum(to: window)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minimumFrameSize = applyMinimum(to: sender)
        return NSSize(
            width: max(frameSize.width, minimumFrameSize.width),
            height: max(frameSize.height, minimumFrameSize.height)
        )
    }

    @discardableResult
    private func applyMinimum(to window: NSWindow) -> NSSize {
        window.contentMinSize = contentMinimumSize
        let minimumFrameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: contentMinimumSize)
        ).size
        window.minSize = minimumFrameSize
        return minimumFrameSize
    }
}
