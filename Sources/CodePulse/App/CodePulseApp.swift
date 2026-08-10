import AppKit
import SwiftUI

@main
struct CodePulseApp: App {
    @NSApplicationDelegateAdaptor(CodePulseApplicationDelegate.self)
    private var appDelegate
    @AppStorage(MenuBarInsertionState.preferenceKey)
    private var menuBarItemInserted = MenuBarInsertionState.defaultInserted
    @StateObject private var store: SessionStore
    @StateObject private var windowCoordinator: AppWindowCoordinator
    @StateObject private var shortcutController: GlobalShortcutController
    @StateObject private var menuBarStatusItem: MenuBarStatusItemController

    init() {
        MenuBarInsertionState.restoreOnLaunch()

        let store = SessionStore.live()
        let windowCoordinator = AppWindowCoordinator(store: store)
        let shortcutController = GlobalShortcutController()
        let menuBarStatusItem = MenuBarStatusItemController(
            store: store,
            windowCoordinator: windowCoordinator,
            isInserted: MenuBarInsertionState.isInserted()
        )
        shortcutController.start(store: store) { [weak windowCoordinator] in
            windowCoordinator?.showHistoryIfEnabled()
        }
        _store = StateObject(wrappedValue: store)
        _windowCoordinator = StateObject(wrappedValue: windowCoordinator)
        _shortcutController = StateObject(wrappedValue: shortcutController)
        _menuBarStatusItem = StateObject(wrappedValue: menuBarStatusItem)
        menuBarItemInserted = true
    }

    var body: some Scene {
        Window("Insights", id: "insights") {
            InsightsView()
                .environmentObject(store)
                .environmentObject(menuBarStatusItem)
        }
        .defaultSize(width: 760, height: 620)

        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(menuBarStatusItem)
        }
    }
}
