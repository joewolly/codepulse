import CodePulseIntegration
import Foundation
import XCTest
@testable import CodePulse

private final class ClassificationPersistence: StatePersisting {
    var state: AppState

    init(_ state: AppState = AppState()) {
        self.state = state
    }

    func load() -> AppState { state }
    func save(_ state: AppState) { self.state = state }
}

@MainActor
final class ActivityClassificationTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testClassificationRecordRoundTripsAndRejectsInvalidValues() throws {
        let record = try XCTUnwrap(ActivityClassification(
            dimension: .workType,
            value: SessionType.review.rawValue,
            source: .metadata,
            confidence: .high,
            classifiedAt: date,
            evidenceCategory: .toolMetadata
        ))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(ActivityClassification.self, from: encoder.encode(record)), record)
        XCTAssertNil(ActivityClassification(
            dimension: .workType,
            value: ActivityDomain.documentation.rawValue,
            source: .metadata,
            confidence: .high,
            classifiedAt: date,
            evidenceCategory: .toolMetadata
        ))

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any])
        object["value"] = ActivityDomain.documentation.rawValue
        XCTAssertThrowsError(try decoder.decode(ActivityClassification.self, from: JSONSerialization.data(withJSONObject: object)))
    }

    func testExistingActivitiesAndSettingsDecodeWithSafeClassificationDefaults() throws {
        let activity = Activity(workspaceID: UUID(), title: "Existing", createdAt: date)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var activityObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(activity)) as? [String: Any])
        activityObject.removeValue(forKey: "classifications")
        XCTAssertTrue(try decoder.decode(Activity.self, from: JSONSerialization.data(withJSONObject: activityObject)).classifications.isEmpty)

        var settingsObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(CodePulseSettings())) as? [String: Any])
        settingsObject.removeValue(forKey: "enhancedPromptClassificationEnabled")
        XCTAssertFalse(try decoder.decode(CodePulseSettings.self, from: JSONSerialization.data(withJSONObject: settingsObject)).enhancedPromptClassificationEnabled)
    }

    func testMetadataFixtureMatrixKeepsWorkTypeAndDomainIndependent() {
        let workspace = Workspace(name: "Demo", createdAt: date, source: .manual)
        let cases: [(String, SessionType, ActivityDomain)] = [
            ("debug test", .debugging, .development),
            ("architecture plan", .planning, .development),
            ("review docs", .review, .documentation),
            ("research automation", .research, .automation),
            ("organize files", .coding, .fileOrganization)
        ]

        for (sourceKind, expectedType, expectedDomain) in cases {
            let records = ActivityClassificationRuleEngine.metadataClassifications(
                event: event(sourceKind: sourceKind), workspace: workspace
            )
            XCTAssertEqual(records.first(where: { $0.dimension == .workType })?.workType, expectedType, sourceKind)
            XCTAssertEqual(records.first(where: { $0.dimension == .activityDomain })?.domain, expectedDomain, sourceKind)
        }

        let localTask = Workspace(name: "Loose file", createdAt: date, source: .transientLocalTask)
        let records = ActivityClassificationRuleEngine.metadataClassifications(event: event(sourceKind: "activity"), workspace: localTask)
        XCTAssertEqual(records.first(where: { $0.dimension == .activityDomain })?.domain, .localTask)
    }

    func testLifecycleCoordinatorAppliesMetadataClassificationToAgentActivity() {
        let workspace = Workspace(
            name: "Demo",
            roots: [WorkspaceRoot(path: "/tmp/classification", addedAt: date)],
            createdAt: date,
            source: .manual
        )
        var state = AppState(activityGraph: ActivityGraph(workspaces: [workspace]))
        let coordinator = DeveloperToolLifecycleCoordinator()

        XCTAssertTrue(coordinator.apply(
            event(sourceKind: "debug documentation"),
            sessionFingerprint: "classification-fingerprint",
            parentSessionFingerprint: nil,
            to: &state
        ))
        XCTAssertEqual(state.activityGraph.activities.first?.workType, .debugging)
        XCTAssertEqual(state.activityGraph.activities.first?.domain, .documentation)
        XCTAssertEqual(state.activityGraph.activities.first?.classifications.map(\.source), [.metadata, .metadata])
    }

    func testPromptClassificationRequiresConsentAndDoesNotPersistPromptText() throws {
        let persistence = ClassificationPersistence()
        let store = SessionStore(persistence: persistence, automaticallyRefresh: false)
        let workspaceID = try XCTUnwrap(store.addWorkspace(name: "Demo", at: date))
        let activityID = try XCTUnwrap(store.createActivity(workspaceID: workspaceID, title: "Classify", at: date))
        let prompt = "confidential narwhal plan that must not persist"

        XCTAssertFalse(store.classifyActivityFromEphemeralPrompt(prompt, id: activityID, at: date))
        store.updateSettings { $0.enhancedPromptClassificationEnabled = true }
        XCTAssertTrue(store.classifyActivityFromEphemeralPrompt(prompt, id: activityID, at: date))
        XCTAssertEqual(store.activityGraph.activities.first?.workType, .planning)
        XCTAssertEqual(store.activityGraph.activities.first?.effectiveClassification(for: .workType)?.source, .ephemeralPrompt)

        let encoded = try JSONEncoder().encode(store.state)
        XCTAssertFalse(try XCTUnwrap(String(data: encoded, encoding: .utf8)).contains(prompt))
        let backup = try CodePulseBackupCodec.encode(state: store.state, exportedAt: date)
        XCTAssertFalse(try XCTUnwrap(String(data: backup, encoding: .utf8)).contains(prompt))
    }

    func testManualOverrideTakesPrecedenceAndUndoRestoresAutomaticValue() throws {
        let persistence = ClassificationPersistence()
        let store = SessionStore(persistence: persistence, automaticallyRefresh: false)
        let workspaceID = try XCTUnwrap(store.addWorkspace(name: "Demo", at: date))
        let activityID = try XCTUnwrap(store.createActivity(workspaceID: workspaceID, title: "Classify", at: date))
        store.updateSettings { $0.enhancedPromptClassificationEnabled = true }
        XCTAssertTrue(store.classifyActivityFromEphemeralPrompt("research a subject", id: activityID, at: date))
        XCTAssertTrue(store.overrideActivityClassification(id: activityID, dimension: .workType, value: SessionType.review.rawValue, at: date.addingTimeInterval(1)))
        XCTAssertEqual(store.activityGraph.activities.first?.workType, .review)
        XCTAssertEqual(store.activityGraph.activities.first?.effectiveClassification(for: .workType)?.source, .userOverride)
        XCTAssertTrue(store.undoActivityClassificationOverride(id: activityID, dimension: .workType, at: date.addingTimeInterval(2)))
        XCTAssertEqual(store.activityGraph.activities.first?.workType, .research)
        XCTAssertEqual(store.activityGraph.activities.first?.effectiveClassification(for: .workType)?.source, .ephemeralPrompt)
    }

    private func event(sourceKind: String) -> DeveloperEventV2 {
        DeveloperEventV2(
            integration: .codex,
            eventKind: .activityObserved,
            observedAt: date,
            idempotencyKey: "classification-\(sourceKind.replacingOccurrences(of: " ", with: "-"))",
            externalSessionKey: "classification-session",
            workingDirectory: "/tmp/classification",
            parserVersion: "test",
            integrationVersion: "test",
            metadata: DeveloperEventMetadataV2(sourceKind: sourceKind)
        )
    }
}
