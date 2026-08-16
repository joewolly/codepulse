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
}
