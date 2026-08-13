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

    }

    func testMetadataFixtureMatrixKeepsWorkTypeAndDomainIndependent() {
        let workspace = Workspace(name: "Demo", createdAt: date, source: .manual)
        let cases: [(DeveloperEventActionCategory?, DeveloperEventFileType?, SessionType, ActivityDomain)] = [
            (.debugging, nil, .debugging, .development),
            (.planning, nil, .planning, .development),
            (.review, .documentation, .review, .documentation),
            (.research, .automation, .research, .automation),
            (.fileOrganization, nil, .coding, .fileOrganization),
            (nil, .configuration, .coding, .administration)
        ]

        for (actionCategory, fileType, expectedType, expectedDomain) in cases {
            let records = ActivityClassificationRuleEngine.metadataClassifications(
                event: event(actionCategory: actionCategory, fileType: fileType), workspace: workspace
            )
            XCTAssertEqual(records.first(where: { $0.dimension == .workType })?.workType, expectedType)
            XCTAssertEqual(records.first(where: { $0.dimension == .activityDomain })?.domain, expectedDomain)
        }

        let localTask = Workspace(name: "Loose file", createdAt: date, source: .transientLocalTask)
        let records = ActivityClassificationRuleEngine.metadataClassifications(event: event(), workspace: localTask)
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
            event(actionCategory: .debugging, fileType: .documentation),
            sessionFingerprint: "classification-fingerprint",
            parentSessionFingerprint: nil,
            to: &state
        ))
        XCTAssertEqual(state.activityGraph.activities.first?.workType, .debugging)
        XCTAssertEqual(state.activityGraph.activities.first?.domain, .documentation)
        XCTAssertEqual(state.activityGraph.activities.first?.classifications.map(\.source), [.metadata, .metadata])
    }

    func testManualOverrideTakesPrecedenceAndUndoRestoresAutomaticValue() throws {
        let persistence = ClassificationPersistence()
        let store = SessionStore(persistence: persistence, automaticallyRefresh: false)
        let workspaceID = try XCTUnwrap(store.addWorkspace(name: "Demo", at: date))
        let activityID = try XCTUnwrap(store.createActivity(workspaceID: workspaceID, title: "Classify", at: date))
        let automatic = try XCTUnwrap(ActivityClassification(
            dimension: .workType,
            value: SessionType.research.rawValue,
            source: .metadata,
            confidence: .high,
            classifiedAt: date,
            evidenceCategory: .actionCategory
        ))
        var graph = store.state.activityGraph
        graph.activities[0].applyClassifications([automatic])
        persistence.state.activityGraph = graph
        let restoredStore = SessionStore(persistence: persistence, automaticallyRefresh: false)
        XCTAssertTrue(restoredStore.overrideActivityClassification(id: activityID, dimension: .workType, value: SessionType.review.rawValue, at: date.addingTimeInterval(1)))
        XCTAssertEqual(restoredStore.activityGraph.activities.first?.workType, .review)
        XCTAssertEqual(restoredStore.activityGraph.activities.first?.effectiveClassification(for: .workType)?.source, .userOverride)
        XCTAssertTrue(restoredStore.undoActivityClassificationOverride(id: activityID, dimension: .workType, at: date.addingTimeInterval(2)))
        XCTAssertEqual(restoredStore.activityGraph.activities.first?.workType, .research)
        XCTAssertEqual(restoredStore.activityGraph.activities.first?.effectiveClassification(for: .workType)?.source, .metadata)
    }

    func testClassificationDoesNotPersistRawSourceKindInStateBackupOrDiagnostics() throws {
        let rawSourceKind = "confidential-tool-payload"
        let workspace = Workspace(name: "Demo", createdAt: date, source: .manual)
        var activity = Activity(workspaceID: workspace.id, title: "Classify", createdAt: date)
        activity.applyClassifications(ActivityClassificationRuleEngine.metadataClassifications(
            event: event(sourceKind: rawSourceKind, actionCategory: .review), workspace: workspace
        ))
        let state = AppState(activityGraph: ActivityGraph(workspaces: [workspace], activities: [activity]))
        let stateText = try XCTUnwrap(String(data: JSONEncoder().encode(state), encoding: .utf8))
        let backupText = try XCTUnwrap(String(data: CodePulseBackupCodec.encode(state: state, exportedAt: date), encoding: .utf8))
        let diagnosticsText = try XCTUnwrap(String(data: JSONEncoder().encode(ActivityGraphDiagnostics(graph: state.activityGraph)), encoding: .utf8))
        XCTAssertFalse(stateText.contains(rawSourceKind))
        XCTAssertFalse(backupText.contains(rawSourceKind))
        XCTAssertFalse(diagnosticsText.contains(rawSourceKind))
    }

    private func event(
        sourceKind: String = "test",
        actionCategory: DeveloperEventActionCategory? = nil,
        fileType: DeveloperEventFileType? = nil
    ) -> DeveloperEventV2 {
        DeveloperEventV2(
            integration: .codex,
            eventKind: .activityObserved,
            observedAt: date,
            idempotencyKey: "classification-event-key-0001",
            externalSessionKey: "classification-session",
            workingDirectory: "/tmp/classification",
            parserVersion: "test",
            integrationVersion: "test",
            metadata: DeveloperEventMetadataV2(
                sourceKind: sourceKind,
                actionCategory: actionCategory,
                fileType: fileType
            )
        )
    }
}
