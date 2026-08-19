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
        var settingsInvocationCount = 0
        delegate.configureSettingsAction {
            settingsInvocationCount += 1
        }
        delegate.installApplicationMenu()

        guard let appMenu = application.mainMenu?.items.first?.submenu else {
            XCTFail("CodePulse did not install an application menu")
            return
        }
        guard let editMenu = application.mainMenu?.item(withTitle: "Edit")?.submenu else {
            XCTFail("CodePulse did not install an Edit menu")
            return
        }
        guard editMenu.items.count == 8 else {
            XCTFail("CodePulse Edit menu has unexpected item count")
            return
        }

        let editItems = editMenu.items
        XCTAssertEqual(editItems[0].title, "Undo")
        XCTAssertEqual(editItems[0].action, NSSelectorFromString("undo:"))
        XCTAssertEqual(editItems[0].keyEquivalent, "z")
        XCTAssertEqual(editItems[0].keyEquivalentModifierMask, [.command])
        XCTAssertNil(editItems[0].target)
        XCTAssertEqual(editItems[1].title, "Redo")
        XCTAssertEqual(editItems[1].action, NSSelectorFromString("redo:"))
        XCTAssertEqual(editItems[1].keyEquivalent, "z")
        XCTAssertEqual(editItems[1].keyEquivalentModifierMask, [.command, .shift])
        XCTAssertNil(editItems[1].target)
        XCTAssertTrue(editItems[2].isSeparatorItem)
        XCTAssertEqual(editItems[3].title, "Cut")
        XCTAssertEqual(editItems[3].action, NSSelectorFromString("cut:"))
        XCTAssertEqual(editItems[3].keyEquivalent, "x")
        XCTAssertEqual(editItems[3].keyEquivalentModifierMask, [.command])
        XCTAssertNil(editItems[3].target)
        XCTAssertEqual(editItems[4].title, "Copy")
        XCTAssertEqual(editItems[4].action, NSSelectorFromString("copy:"))
        XCTAssertEqual(editItems[4].keyEquivalent, "c")
        XCTAssertEqual(editItems[4].keyEquivalentModifierMask, [.command])
        XCTAssertNil(editItems[4].target)
        XCTAssertEqual(editItems[5].title, "Paste")
        XCTAssertEqual(editItems[5].action, NSSelectorFromString("paste:"))
        XCTAssertEqual(editItems[5].keyEquivalent, "v")
        XCTAssertEqual(editItems[5].keyEquivalentModifierMask, [.command])
        XCTAssertNil(editItems[5].target)
        XCTAssertTrue(editItems[6].isSeparatorItem)
        XCTAssertEqual(editItems[7].title, "Select All")
        XCTAssertEqual(editItems[7].action, NSSelectorFromString("selectAll:"))
        XCTAssertEqual(editItems[7].keyEquivalent, "a")
        XCTAssertEqual(editItems[7].keyEquivalentModifierMask, [.command])
        XCTAssertNil(editItems[7].target)

        let settingsItem = appMenu.item(withTitle: "Settings…")
        let quitItem = appMenu.item(withTitle: "Quit CodePulse")

        XCTAssertNotNil(settingsItem)
        XCTAssertEqual(settingsItem?.keyEquivalent, ",")
        XCTAssertEqual(settingsItem?.keyEquivalentModifierMask, [.command])
        XCTAssertTrue(settingsItem?.target === delegate)
        if let settingsItem, let action = settingsItem.action {
            XCTAssertTrue(application.sendAction(action, to: settingsItem.target, from: settingsItem))
        } else {
            XCTFail("CodePulse Settings menu item is missing its action")
        }
        XCTAssertEqual(settingsInvocationCount, 1)
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
        XCTAssertEqual(firstWindow?.toolbarStyle, .unified)
        XCTAssertEqual(firstWindow?.contentView?.bounds.size, NSSize(width: 560, height: 520))
        XCTAssertEqual(firstWindow?.contentMinSize, NSSize(width: 540, height: 480))

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

    func testOnboardingWindowUsesUnclippedContentSize() {
        _ = NSApplication.shared
        for window in NSApp.windows where window.title == "Getting Started with CodePulse" {
            window.close()
            window.title = "Closed test window"
        }

        let store = SessionStore(
            persistence: CoordinatorTestPersistence(),
            clock: CoordinatorTestClock(),
            automaticallyRefresh: false
        )
        let coordinator = AppWindowCoordinator(store: store)

        coordinator.showOnboarding()
        let onboardingWindow = NSApp.windows.first(where: { $0.title == "Getting Started with CodePulse" })
        XCTAssertNotNil(onboardingWindow)
        XCTAssertTrue(onboardingWindow?.isVisible == true)
        XCTAssertEqual(onboardingWindow?.contentView?.bounds.size, NSSize(width: 540, height: 490))
        XCTAssertEqual(onboardingWindow?.contentMinSize, NSSize(width: 540, height: 490))
        onboardingWindow?.close()
    }

    func testInsightsAndHistoryWindowsAreExplicitAndReusable() {
        let application = NSApplication.shared
        for window in application.windows where ["Insights", "History"].contains(window.title) {
            window.close()
            window.title = "Closed test window"
        }
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
        XCTAssertEqual(insightsWindow?.contentMinSize, NSSize(width: 740, height: 540))
        XCTAssertEqual(insightsWindow?.contentView?.bounds.size, NSSize(width: 880, height: 640))

        coordinator.showInsights()
        XCTAssertEqual(application.windows.filter { $0.title == "Insights" }.count, 1)
        insightsWindow?.close()
        XCTAssertFalse(insightsWindow?.isVisible == true)
        coordinator.showInsights()
        XCTAssertTrue(insightsWindow?.isVisible == true)
        insightsWindow?.close()

        coordinator.showHistory()
        let historyWindow = application.windows.first(where: { $0.title == "History" })
        XCTAssertNotNil(historyWindow)
        XCTAssertTrue(historyWindow?.isVisible == true)
        XCTAssertEqual(historyWindow?.contentMinSize, NSSize(width: 740, height: 520))
        XCTAssertEqual(historyWindow?.contentView?.bounds.size, NSSize(width: 880, height: 600))

        coordinator.showHistory()
        let historyWindows = application.windows.filter { $0.title == "History" }
        XCTAssertEqual(historyWindows.count, 1)
        XCTAssertTrue(historyWindows.first === historyWindow)
        historyWindow?.close()
        XCTAssertFalse(historyWindow?.isVisible == true)
    }
}
