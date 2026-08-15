import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarStatusItemController: NSObject, ObservableObject {
    private let store: SessionStore
    private let windowCoordinator: AppWindowCoordinator
    private let shouldBeInserted: Bool
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var displayCancellable: AnyCancellable?

    init(store: SessionStore, windowCoordinator: AppWindowCoordinator, isInserted: Bool) {
        self.store = store
        self.windowCoordinator = windowCoordinator
        shouldBeInserted = isInserted
        super.init()

        displayCancellable = Publishers.CombineLatest(store.$state, store.$now)
            .sink { [weak self] _, _ in
                self?.updateButton()
            }

        // Create the AppKit status item after the application has entered its run loop.
        // Creating it during SwiftUI App initialization can register the scene without
        // producing a visible item on macOS.
        DispatchQueue.main.async { [weak self] in
            self?.installStatusItem()
        }
    }

    private func installStatusItem() {
        guard statusItem == nil else { return }

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = shouldBeInserted
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.toolTip = "CodePulse"
        self.statusItem = statusItem
        updateButton()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(
                onDismiss: { [weak self] in self?.closePopover() },
                onOpenInsights: { [weak self] in self?.openInsights() }
            )
            .environmentObject(store)
            .environmentObject(windowCoordinator)
        )
        self.popover = popover

        guard let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func closePopover() {
        popover?.performClose(nil)
    }

    private func openInsights() {
        windowCoordinator.showInsights()
    }

    private func updateButton() {
        guard let button = statusItem?.button else { return }

        let symbol = store.phase == .paused
            ? "pause.fill"
            : (store.phase == .idle ? "circle" : "circle.fill")
        let accessibilityText = store.menuBarAccessibilityText

        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityText)
        button.title = menuBarTitle
        button.imagePosition = .imageLeading
        button.setAccessibilityLabel(accessibilityText)
        button.toolTip = accessibilityText
    }

    private var menuBarTitle: String {
        switch store.phase {
        case .idle:
            return store.state.settings.idleAppearance == .code ? "Code" : ""
        case .running, .paused, .finishing:
            let duration = CodePulseFormatting.menuBarDuration(store.elapsedDuration)
            switch store.state.settings.menuBarDisplay {
            case .projectAndTimer:
                if let projectName = store.activeSession?.projectName, !projectName.isEmpty {
                    return "\(compactProjectName(projectName)) · \(duration)"
                }
                return duration
            case .timerOnly:
                return duration
            case .iconOnly:
                return ""
            }
        }
    }

    private func compactProjectName(_ projectName: String) -> String {
        let maximumLength = 20
        guard projectName.count > maximumLength else { return projectName }
        return String(projectName.prefix(maximumLength - 1)) + "…"
    }
}
