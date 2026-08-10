import XCTest
@testable import CodePulse

final class MenuBarInsertionStateTests: XCTestCase {
    private let suiteName = "CodePulse.MenuBarInsertionStateTests.\(UUID().uuidString)"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testMissingPreferenceDefaultsToVisible() {
        XCTAssertNil(defaults.object(forKey: MenuBarInsertionState.preferenceKey))
        XCTAssertTrue(MenuBarInsertionState.isInserted(in: defaults))
    }

    func testHiddenPreferenceIsRecoveredOnLaunch() {
        defaults.set(false, forKey: MenuBarInsertionState.preferenceKey)

        MenuBarInsertionState.restoreOnLaunch(in: defaults)

        XCTAssertTrue(MenuBarInsertionState.isInserted(in: defaults))
        XCTAssertTrue(defaults.bool(forKey: MenuBarInsertionState.preferenceKey))
    }

    func testCorruptPreferenceIsRecoveredOnLaunch() {
        defaults.set("not a Boolean", forKey: MenuBarInsertionState.preferenceKey)

        MenuBarInsertionState.restoreOnLaunch(in: defaults)

        XCTAssertTrue(MenuBarInsertionState.isInserted(in: defaults))
        XCTAssertTrue(defaults.bool(forKey: MenuBarInsertionState.preferenceKey))
    }

    func testRecoveryPreservesUnrelatedPreferences() {
        defaults.set(false, forKey: MenuBarInsertionState.preferenceKey)
        defaults.set("preserved", forKey: "unrelatedSetting")

        MenuBarInsertionState.restoreOnLaunch(in: defaults)

        XCTAssertEqual(defaults.string(forKey: "unrelatedSetting"), "preserved")
    }
}
