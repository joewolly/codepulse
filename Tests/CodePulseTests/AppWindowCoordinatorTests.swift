import AppKit
import SwiftUI
import XCTest
@testable import CodePulse

private final class CoordinatorTestClock: SessionClock {
    let now = Date(timeIntervalSince1970: 1_750_000_000)
}

private final class CoordinatorTestPersistence: StatePersisting {
    var state = AppState()

    func load() -> AppState { state }

    func save(_ state: AppState) {
        self.state = state
    }
}

@MainActor
final class AppWindowCoordinatorTests: XCTestCase {
    func testApplicationMenuContainsSettingsAndQuitCommands() {
        let application = NSApplication.shared
        let originalMenu = application.mainMenu
        defer { application.mainMenu = originalMenu }

        let delegate = CodePulseApplicationDelegate()
        delegate.installApplicationMenu()

        guard let appMenu = application.mainMenu?.items.first?.submenu else {
            XCTFail("CodePulse did not install an application menu")
            return
        }
        let settingsItem = appMenu.item(withTitle: "Settings…")
        let quitItem = appMenu.item(withTitle: "Quit CodePulse")

        XCTAssertNotNil(settingsItem)
        XCTAssertEqual(settingsItem?.keyEquivalent, ",")
        XCTAssertEqual(settingsItem?.keyEquivalentModifierMask, [.command])
        XCTAssertTrue(settingsItem?.target === delegate)
        XCTAssertNotNil(quitItem)
        XCTAssertEqual(quitItem?.keyEquivalent, "q")
        XCTAssertEqual(quitItem?.keyEquivalentModifierMask, [.command])
        XCTAssertTrue(quitItem?.target === application)
        XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(application))
    }

    func testSettingsWindowIsExplicitlyCreatedReusedAndReopened() {
        _ = NSApplication.shared
        let store = SessionStore(
            persistence: CoordinatorTestPersistence(),
            clock: CoordinatorTestClock(),
            automaticallyRefresh: false
        )
        let coordinator = AppWindowCoordinator(store: store)
        coordinator.configureSettingsWindow {
            NSHostingController(rootView: Text("Settings test content"))
        }

        coordinator.showSettings()
        let firstWindow = NSApp.windows.first(where: { $0.title == "Settings" })
        XCTAssertNotNil(firstWindow)
        XCTAssertTrue(firstWindow?.isVisible == true)

        coordinator.showSettings()
        let settingsWindows = NSApp.windows.filter { $0.title == "Settings" }
        XCTAssertEqual(settingsWindows.count, 1)
        XCTAssertTrue(settingsWindows.first === firstWindow)

        firstWindow?.close()
        XCTAssertFalse(firstWindow?.isVisible == true)

        coordinator.showSettings()
        XCTAssertTrue(firstWindow?.isVisible == true)
        firstWindow?.close()
    }

    func testInsightsAndHistoryWindowsAreExplicitAndReusable() {
        let application = NSApplication.shared
        let store = SessionStore(
            persistence: CoordinatorTestPersistence(),
            clock: CoordinatorTestClock(),
            automaticallyRefresh: false
        )
        let coordinator = AppWindowCoordinator(store: store)

        XCTAssertNil(application.windows.first(where: { $0.title == "Insights" }))
        XCTAssertNil(application.windows.first(where: { $0.title == "History" }))

        coordinator.showInsights()
        let insightsWindow = application.windows.first(where: { $0.title == "Insights" })
        XCTAssertNotNil(insightsWindow)
        XCTAssertTrue(insightsWindow?.isVisible == true)

        coordinator.showInsights()
        XCTAssertEqual(application.windows.filter { $0.title == "Insights" }.count, 1)
        insightsWindow?.close()
        XCTAssertFalse(insightsWindow?.isVisible == true)

        coordinator.showHistory()
        let historyWindow = application.windows.first(where: { $0.title == "History" })
        XCTAssertNotNil(historyWindow)
        XCTAssertTrue(historyWindow?.isVisible == true)
        historyWindow?.close()
        XCTAssertFalse(historyWindow?.isVisible == true)
    }
}
