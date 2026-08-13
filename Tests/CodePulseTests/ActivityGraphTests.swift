import Foundation
import XCTest
@testable import CodePulse

final class ActivityGraphTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testModelsRoundTripAndKeepStableIdentity() throws {
        let root = WorkspaceRoot(path: "/tmp/demo", addedAt: start)
        let workspace = Workspace(name: "Demo", roots: [root], createdAt: start, source: .manual)
        let activity = Activity(workspaceID: workspace.id, title: "Ship", workType: .review, domain: .documentation, createdAt: start)
        let run = Run(activityID: activity.id, kind: .manual, startedAt: start, intervals: [Interval(state: .active, startedAt: start)])
        let graph = ActivityGraph(workspaces: [workspace], activities: [activity], runs: [run])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertEqual(try decoder.decode(ActivityGraph.self, from: encoder.encode(graph)), graph)
        XCTAssertEqual(graph.activities.first?.workspaceID, workspace.id)
        XCTAssertEqual(graph.runs.first?.activityID, activity.id)
    }

    func testRepositoryEnforcesOneOpenIntervalAndImmutableClosedIntervals() throws {
        var graph = ActivityGraph()
        let workspace = Workspace(name: "Demo", createdAt: start, source: .manual)
        graph.workspaces = [workspace]
        let activity = try ActivityGraphRepository.createActivity(in: &graph, workspaceID: workspace.id, title: "Ship", workType: .coding, domain: .development, at: start)
        let run = try ActivityGraphRepository.startRun(in: &graph, activityID: activity.id, kind: .manual, at: start)

        XCTAssertThrowsError(try ActivityGraphRepository.beginInterval(in: &graph, runID: run.id, state: .waiting, at: start.addingTimeInterval(1))) { error in
            XCTAssertEqual(error as? ActivityGraphError, .openIntervalExists)
        }
        try ActivityGraphRepository.closeOpenInterval(in: &graph, runID: run.id, at: start.addingTimeInterval(60))
        let closed = try XCTUnwrap(graph.runs.first?.intervals.first)
        XCTAssertEqual(closed.endedAt, start.addingTimeInterval(60))
        try ActivityGraphRepository.beginInterval(in: &graph, runID: run.id, state: .waiting, at: start.addingTimeInterval(60))
        try ActivityGraphRepository.endRun(in: &graph, runID: run.id, at: start.addingTimeInterval(120))
        XCTAssertEqual(graph.runs.first?.intervals.first, closed)
        XCTAssertTrue(graph.runs.first?.intervals.allSatisfy { !$0.isOpen } == true)
        XCTAssertThrowsError(try ActivityGraphRepository.endRun(in: &graph, runID: run.id, at: start.addingTimeInterval(121))) { error in
            XCTAssertEqual(error as? ActivityGraphError, .runAlreadyEnded)
        }
    }

    func testRepositoryQueriesRunsWithoutCrossWorkspaceAttachment() throws {
        var graph = ActivityGraph()
        let first = Workspace(name: "First", createdAt: start, source: .manual)
        let second = Workspace(name: "Second", createdAt: start, source: .manual)
        graph.workspaces = [first, second]
        let activity = try ActivityGraphRepository.createActivity(in: &graph, workspaceID: first.id, title: "First task", workType: .coding, domain: .development, at: start)
        let run = try ActivityGraphRepository.startRun(in: &graph, activityID: activity.id, kind: .manual, at: start)

        XCTAssertEqual(ActivityGraphRepository.runs(in: graph, workspaceID: first.id), [run])
        XCTAssertTrue(ActivityGraphRepository.runs(in: graph, workspaceID: second.id).isEmpty)
        XCTAssertThrowsError(try ActivityGraphRepository.createActivity(in: &graph, workspaceID: UUID(), title: "Invalid", workType: .coding, domain: .development, at: start)) { error in
            XCTAssertEqual(error as? ActivityGraphError, .workspaceNotFound)
        }
    }

    func testLegacySessionsMigrateToManualActivityRunsAndPreserveCompatibilityState() throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("state.json")
        let project = ProjectRecord(id: UUID(), name: "Demo", folderPath: "/tmp/demo", createdAt: start)
        let completed = CompletedSession(
            id: UUID(), projectID: project.id, projectName: project.name, type: .debugging,
            goal: "Repair", outcome: "Done", startedAt: start, endedAt: start.addingTimeInterval(120),
            pauseIntervals: [PauseInterval(startedAt: start.addingTimeInterval(30), endedAt: start.addingTimeInterval(60))]
        )
        let active = ActiveSession(id: UUID(), projectID: project.id, projectName: project.name, type: .planning, goal: "Next", startedAt: start.addingTimeInterval(180))
        var pausedActive = active
        XCTAssertTrue(pausedActive.pause(at: start.addingTimeInterval(200)))
        let legacyPayload = AppState(projects: [project], completedSessions: [completed], activeSession: pausedActive)
        let legacyEnvelope = StatePersistenceEnvelope(schemaVersion: 2, createdAt: start, migrationHistory: [], payload: legacyPayload)
        try encode(legacyEnvelope).write(to: fileURL)

        let state = JSONFilePersistence(fileURL: fileURL, now: { self.start }).load()

        XCTAssertEqual(state.projects, [project])
        XCTAssertEqual(state.completedSessions, [completed])
        XCTAssertEqual(state.activeSession, pausedActive)
        XCTAssertEqual(state.activityGraph.workspaces.count, 1)
        XCTAssertEqual(state.activityGraph.activities.count, 2)
        XCTAssertEqual(state.activityGraph.runs.count, 2)
        XCTAssertEqual(state.activityGraph.activities.map(\.legacySessionID).compactMap { $0 }.sorted(by: { $0.uuidString < $1.uuidString }), [completed.id, pausedActive.id].sorted(by: { $0.uuidString < $1.uuidString }))
        XCTAssertTrue(state.activityGraph.runs.allSatisfy { $0.kind == .manual })
        XCTAssertTrue(state.activityGraph.runs.flatMap(\.intervals).allSatisfy { interval in
            interval.endedAt == nil || interval.endedAt! >= interval.startedAt
        })
    }

    func testDiagnosticsRedactWorkspaceRootsAndLegacySessionText() throws {
        let workspace = Workspace(name: "Demo", roots: [WorkspaceRoot(path: "/Users/example/private", addedAt: start)], createdAt: start, source: .manual)
        let activity = Activity(workspaceID: workspace.id, title: "Sensitive task", createdAt: start)
        let run = Run(activityID: activity.id, kind: .manual, startedAt: start, intervals: [Interval(state: .active, startedAt: start)])
        let diagnostics = ActivityGraphDiagnostics(graph: ActivityGraph(workspaces: [workspace], activities: [activity], runs: [run]))
        let data = try JSONEncoder().encode(diagnostics)
        let rendered = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(rendered.contains("/Users/example/private"))
        XCTAssertFalse(rendered.contains("Sensitive task"))
        XCTAssertTrue(rendered.contains("rootCount"))
    }

    func testMalformedLegacyTimelineDoesNotCreateNegativeIntervals() {
        let malformed = CompletedSession(
            id: UUID(), projectID: nil, projectName: nil, goal: nil, outcome: nil,
            startedAt: start, endedAt: start.addingTimeInterval(-10),
            pauseIntervals: [PauseInterval(startedAt: start.addingTimeInterval(20), endedAt: start.addingTimeInterval(5))]
        )
        let graph = ActivityGraph.migratedLegacyState(AppState(completedSessions: [malformed]))

        XCTAssertEqual(graph.runs.first?.endedAt, start)
        XCTAssertTrue(graph.runs.flatMap(\.intervals).allSatisfy { interval in
            interval.endedAt == nil || interval.endedAt! >= interval.startedAt
        })
    }

    private func encode(_ envelope: StatePersistenceEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodePulseActivityGraphTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
