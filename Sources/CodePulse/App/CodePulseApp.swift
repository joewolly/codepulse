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
    @StateObject private var digestCoordinator: DigestNotificationCoordinator

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
        let digestCoordinator = DigestNotificationCoordinator(
            stateProvider: store,
            notifications: SystemLocalNotificationScheduler(),
            ledger: UserDefaultsDigestDeliveryLedger(),
            clock: store.clock
        )
        digestCoordinator.start()
        shortcutController.start(store: store) { [weak windowCoordinator] in
            windowCoordinator?.showHistoryIfEnabled()
        }
        _store = StateObject(wrappedValue: store)
        _windowCoordinator = StateObject(wrappedValue: windowCoordinator)
        _shortcutController = StateObject(wrappedValue: shortcutController)
        _menuBarStatusItem = StateObject(wrappedValue: menuBarStatusItem)
        _updateController = StateObject(wrappedValue: updateController)
        _integrationManager = StateObject(wrappedValue: integrationManager)
        _digestCoordinator = StateObject(wrappedValue: digestCoordinator)
        menuBarItemInserted = true

        windowCoordinator.configureSettingsWindow { [weak store, weak windowCoordinator, weak menuBarStatusItem, weak updateController, weak integrationManager, weak digestCoordinator] in
            guard let store,
                  let windowCoordinator,
                  let menuBarStatusItem,
                  let updateController,
                  let integrationManager,
                  let digestCoordinator else {
                return NSHostingController(rootView: EmptyView())
            }

            let content = SettingsView()
                .environmentObject(store)
                .environmentObject(windowCoordinator)
                .environmentObject(menuBarStatusItem)
                .environmentObject(updateController)
                .environmentObject(integrationManager)
                .environmentObject(digestCoordinator)
            return NSHostingController(rootView: content)
        }
        appDelegate.configureSettingsAction { [weak windowCoordinator] in
            windowCoordinator?.showSettings()
        }

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
        // CodePulse owns every user-facing window through AppWindowCoordinator.
        // Keep SwiftUI's App lifecycle without registering a launchable scene
        // on macOS 13, where a lone Settings scene is presented automatically.
        if #available(macOS 999, *) {
            Settings { EmptyView() }
        }
    }
}
