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
    @StateObject private var updateController: SparkleUpdateController
    @StateObject private var integrationManager: DeveloperToolIntegrationManager

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
        let updateController = SparkleUpdateController()
        let integrationManager = DeveloperToolIntegrationManager.live()
        shortcutController.start(store: store) { [weak windowCoordinator] in
            windowCoordinator?.showHistoryIfEnabled()
        }
        _store = StateObject(wrappedValue: store)
        _windowCoordinator = StateObject(wrappedValue: windowCoordinator)
        _shortcutController = StateObject(wrappedValue: shortcutController)
        _menuBarStatusItem = StateObject(wrappedValue: menuBarStatusItem)
        _updateController = StateObject(wrappedValue: updateController)
        _integrationManager = StateObject(wrappedValue: integrationManager)
        menuBarItemInserted = true

        // SessionStore has completed state recovery before this deferred
        // informational window is considered. The status item is also
        // installed on the next run-loop turn, so onboarding cannot become an
        // authority over lifecycle recovery or menu-bar availability.
        DispatchQueue.main.async { [weak windowCoordinator] in
            guard let windowCoordinator else { return }
            if store.isInRecoveryMode {
                windowCoordinator.showRecoveryIfNeeded()
            } else {
                windowCoordinator.showOnboardingIfNeeded()
            }
        }
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
                .environmentObject(windowCoordinator)
                .environmentObject(menuBarStatusItem)
                .environmentObject(updateController)
                .environmentObject(integrationManager)
        }
    }
}
