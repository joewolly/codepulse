import XCTest
@testable import CodePulse

final class SettingsIntegrationsConfigurationTests: XCTestCase {
    func testLifecycleAndCostSectionsContainEachDeveloperToolOnce() {
        let lifecycleTools = IntegrationsSettingsConfiguration.lifecycleRows.map(\.tool)
        let costTools = IntegrationsSettingsConfiguration.costDisplayRows.map(\.tool)
        let tokenTools = IntegrationsSettingsConfiguration.tokenUsageRows.map(\.tool)

        XCTAssertEqual(lifecycleTools.count, 3)
        XCTAssertEqual(costTools.count, 3)
        XCTAssertEqual(tokenTools.count, 3)
        XCTAssertEqual(lifecycleTools, [.codex, .claudeCode, .opencode])
        XCTAssertEqual(costTools, [.codex, .claudeCode, .opencode])
        XCTAssertEqual(tokenTools, [.codex, .claudeCode, .opencode])
    }

    func testNamespacedIdentifiersRemainDistinctPerSection() {
        let lifecycleIDs = IntegrationsSettingsConfiguration.lifecycleRows.map(\.id)
        let tokenIDs = IntegrationsSettingsConfiguration.tokenUsageRows.map(\.id)
        let costIDs = IntegrationsSettingsConfiguration.costDisplayRows.map(\.id)

        let allIDs = lifecycleIDs + tokenIDs + costIDs
        XCTAssertEqual(allIDs.count, Set(allIDs).count)
        XCTAssertEqual(allIDs, [
            "lifecycle:codex",
            "lifecycle:claude-code",
            "lifecycle:opencode",
            "token-usage:codex",
            "token-usage:claude-code",
            "token-usage:opencode",
            "cost-display:codex",
            "cost-display:claude-code",
            "cost-display:opencode"
        ])
    }

    func testCostDisplayAccessibilityIdentifiersMatchExpectedNaming() {
        let accessibilityIdentifiers = IntegrationsSettingsConfiguration.costDisplayRows.map(\.accessibilityIdentifier)
        XCTAssertEqual(accessibilityIdentifiers, [
            "cost-display-codex",
            "cost-display-claude-code",
            "cost-display-opencode"
        ])
    }

    func testTokenUsageAccessibilityIdentifiersExist() {
        let accessibilityIdentifiers = IntegrationsSettingsConfiguration.tokenUsageRows.map(\.accessibilityIdentifier)
        XCTAssertEqual(accessibilityIdentifiers, [
            "token-usage-codex",
            "token-usage-claude-code",
            "token-usage-opencode"
        ])
    }
}
