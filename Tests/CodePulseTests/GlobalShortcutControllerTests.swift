import XCTest
@testable import CodePulse

private final class ShortcutTestRegistrar: GlobalHotKeyRegistering {
    var shouldRegister = true
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var lastKeyCode: UInt32?
    private(set) var lastModifiers: UInt32?
    private(set) var registeredAction: (() -> Void)?

    @discardableResult
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        action: @escaping () -> Void
    ) -> Bool {
        registerCallCount += 1
        lastKeyCode = keyCode
        lastModifiers = modifiers
        guard shouldRegister else { return false }
        registeredAction = action
        return true
    }

    func unregister() {
        unregisterCallCount += 1
        registeredAction = nil
    }
}

private final class ShortcutTestPersistence: StatePersisting {
    var state: AppState

    init(_ state: AppState = AppState()) {
        self.state = state
    }

    func load() -> AppState { state }
    func save(_ state: AppState) { self.state = state }
}

@MainActor
final class GlobalShortcutControllerTests: XCTestCase {
    func testDisabledSettingDoesNotRegisterShortcut() {
        let registrar = ShortcutTestRegistrar()
        let controller = GlobalShortcutController(registrar: registrar)

        controller.start(isEnabled: false) {}

        XCTAssertFalse(controller.isRegistered)
        XCTAssertEqual(registrar.registerCallCount, 0)
    }

    func testEnabledSettingRegistersHistoryShortcutOnce() {
        let registrar = ShortcutTestRegistrar()
        let controller = GlobalShortcutController(registrar: registrar)

        controller.start(isEnabled: true) {}

        XCTAssertTrue(controller.isRegistered)
        XCTAssertEqual(registrar.registerCallCount, 1)
        XCTAssertEqual(registrar.lastKeyCode, GlobalShortcutController.historyKeyCode)
        XCTAssertEqual(registrar.lastModifiers, GlobalShortcutController.historyModifiers)
    }

    func testRepeatedEnableDoesNotDuplicateRegistration() {
        let registrar = ShortcutTestRegistrar()
        let controller = GlobalShortcutController(registrar: registrar)

        controller.start(isEnabled: true) {}
        controller.setEnabled(true)
        controller.setEnabled(true)

        XCTAssertEqual(registrar.registerCallCount, 1)
        XCTAssertEqual(registrar.unregisterCallCount, 0)
    }

    func testDisablingUnregistersShortcut() {
        let registrar = ShortcutTestRegistrar()
        let controller = GlobalShortcutController(registrar: registrar)

        controller.start(isEnabled: true) {}
        controller.setEnabled(false)

        XCTAssertFalse(controller.isRegistered)
        XCTAssertEqual(registrar.unregisterCallCount, 1)
        XCTAssertNil(registrar.registeredAction)
    }

    func testReenablingRegistersShortcutAgain() {
        let registrar = ShortcutTestRegistrar()
        let controller = GlobalShortcutController(registrar: registrar)

        controller.start(isEnabled: true) {}
        controller.setEnabled(false)
        controller.setEnabled(true)

        XCTAssertTrue(controller.isRegistered)
        XCTAssertEqual(registrar.registerCallCount, 2)
        XCTAssertEqual(registrar.unregisterCallCount, 1)
    }

    func testRegistrationFailureIsNonFatal() {
        let registrar = ShortcutTestRegistrar()
        registrar.shouldRegister = false
        let controller = GlobalShortcutController(registrar: registrar)

        controller.start(isEnabled: true) {}
        controller.setEnabled(false)

        XCTAssertFalse(controller.isRegistered)
        XCTAssertEqual(registrar.registerCallCount, 1)
        XCTAssertEqual(registrar.unregisterCallCount, 0)
    }

    func testStoppingUnregistersAndStopsFollowingSettingChanges() {
        let store = SessionStore(
            persistence: ShortcutTestPersistence(),
            automaticallyRefresh: false
        )
        let registrar = ShortcutTestRegistrar()
        let controller = GlobalShortcutController(registrar: registrar)

        controller.start(store: store) {}
        XCTAssertTrue(controller.isRegistered)

        controller.stop()
        store.updateSettings { $0.globalShortcutEnabled = false }
        store.updateSettings { $0.globalShortcutEnabled = true }

        XCTAssertFalse(controller.isRegistered)
        XCTAssertEqual(registrar.registerCallCount, 1)
        XCTAssertEqual(registrar.unregisterCallCount, 1)
    }

    func testStoreSettingChangesUpdateRegistrationImmediately() {
        var state = AppState()
        state.settings.globalShortcutEnabled = false
        let store = SessionStore(
            persistence: ShortcutTestPersistence(state),
            automaticallyRefresh: false
        )
        let registrar = ShortcutTestRegistrar()
        let controller = GlobalShortcutController(registrar: registrar)

        controller.start(store: store) {}
        XCTAssertFalse(controller.isRegistered)
        XCTAssertEqual(registrar.registerCallCount, 0)

        store.updateSettings { $0.globalShortcutEnabled = true }
        XCTAssertTrue(controller.isRegistered)
        XCTAssertEqual(registrar.registerCallCount, 1)

        store.updateSettings { $0.globalShortcutEnabled = false }
        XCTAssertFalse(controller.isRegistered)
        XCTAssertEqual(registrar.unregisterCallCount, 1)
    }

    func testSessionStoreWorksWhenShortcutRegistrationFails() {
        let store = SessionStore(
            persistence: ShortcutTestPersistence(),
            automaticallyRefresh: false
        )
        let registrar = ShortcutTestRegistrar()
        registrar.shouldRegister = false
        let controller = GlobalShortcutController(registrar: registrar)

        controller.start(store: store) {}

        XCTAssertFalse(controller.isRegistered)
        XCTAssertTrue(store.startSession(projectID: nil, goal: "Keep timing independent"))
        XCTAssertTrue(store.finish())
        XCTAssertTrue(store.saveFinishedSession(outcome: "Shortcut unavailable"))
        XCTAssertEqual(store.state.completedSessions.count, 1)
    }
}
