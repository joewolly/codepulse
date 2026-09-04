import AppKit
import SwiftUI

/// Strongly owns the application-lifetime services that were previously
/// retained by SwiftUI's StateObject wrappers.
@MainActor
final class CodePulseRuntime {
    let store: SessionStore
    let windowCoordinator: AppWindowCoordinator
    let shortcutController: GlobalShortcutController
    let menuBarStatusItem: MenuBarStatusItemController
    let updateController: SparkleUpdateController
    let integrationManager: DeveloperToolIntegrationManager
    let digestCoordinator: DigestNotificationCoordinator

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

        self.store = store
        self.windowCoordinator = windowCoordinator
        self.shortcutController = shortcutController
        self.menuBarStatusItem = menuBarStatusItem
        self.updateController = updateController
        self.integrationManager = integrationManager
        self.digestCoordinator = digestCoordinator

        windowCoordinator.configureUpdateAction { [weak updateController] in
            updateController?.checkForUpdates()
        }

        digestCoordinator.start()
        shortcutController.start(store: store) { [weak windowCoordinator] in
            windowCoordinator?.showHistoryIfEnabled()
        }

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
    }

    func start() {
        // SessionStore has completed state recovery before this deferred
        // informational window is considered. Recovery remains authoritative
        // over onboarding, and healthy existing-user launches stay menu-bar
        // only.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.store.isInRecoveryMode {
                self.windowCoordinator.showRecoveryIfNeeded()
            } else {
                self.windowCoordinator.showOnboardingIfNeeded()
            }
        }
    }

    func showSettings() {
        windowCoordinator.showSettings()
    }
}
