import AppKit
import SwiftUI

@main
struct CodePulseApp: App {
    @AppStorage(MenuBarInsertionState.preferenceKey)
    private var menuBarExtraInserted = MenuBarInsertionState.defaultInserted
    @StateObject private var store: SessionStore
    @StateObject private var windowCoordinator: AppWindowCoordinator
    @StateObject private var shortcutController: GlobalShortcutController

    init() {
        MenuBarInsertionState.restoreOnLaunch()

        let store = SessionStore.live()
        let windowCoordinator = AppWindowCoordinator(store: store)
        let shortcutController = GlobalShortcutController()
        shortcutController.start(store: store) { [weak windowCoordinator] in
            windowCoordinator?.showHistoryIfEnabled()
        }
        _store = StateObject(wrappedValue: store)
        _windowCoordinator = StateObject(wrappedValue: windowCoordinator)
        _shortcutController = StateObject(wrappedValue: shortcutController)
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $menuBarExtraInserted) {
            MenuBarPopoverView()
                .environmentObject(store)
                .environmentObject(windowCoordinator)
        } label: {
            MenuBarLabel()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Window("Insights", id: "insights") {
            InsightsView()
                .environmentObject(store)
        }
        .defaultSize(width: 760, height: 620)

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
