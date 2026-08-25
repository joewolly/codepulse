import Foundation
import XCTest
@testable import CodePulse

final class WorkspacePersistenceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testWorkspaceAndProjectRelationshipsRoundTrip() throws {
        let firstID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let first = WorkspaceRecord(
            id: firstID,
            name: "Personal",
            createdAt: start,
            updatedAt: start.addingTimeInterval(10)
        )
        let second = WorkspaceRecord(
            id: secondID,
            name: "Infrastructure",
            createdAt: start.addingTimeInterval(20),
            updatedAt: start.addingTimeInterval(30)
        )
        let firstProject = ProjectRecord(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!,
            workspaceID: firstID,
            name: "CodePulse",
            createdAt: start
        )
        let archivedProject = ProjectRecord(
            id: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!,
            workspaceID: secondID,
            name: "Archived",
            createdAt: start,
            archivedAt: start.addingTimeInterval(60)
        )
        let state = AppState(
            workspaces: [first, second],
            projects: [firstProject, archivedProject],
            settings: CodePulseSettings(selectedWorkspaceID: secondID)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(
            try decoder.decode(WorkspaceRecord.self, from: encoder.encode(first)),
            first
        )
        let roundTripped = try decoder.decode(AppState.self, from: encoder.encode(state))

        XCTAssertEqual(roundTripped, state)
        XCTAssertEqual(roundTripped.schemaVersion, CodePulseStateSchema.currentVersion)
        XCTAssertEqual(roundTripped.projects.map(\.workspaceID), [firstID, secondID])
        try AppStateIntegrityValidator.validate(roundTripped)
    }

    func testLegacyStateMigratesArchivedProjectsAndIsIdempotent() throws {
        let active = ProjectRecord(
            id: UUID(uuidString: "50000000-0000-0000-0000-000000000005")!,
            name: "Active",
            createdAt: start
        )
        let archived = ProjectRecord(
            id: UUID(uuidString: "60000000-0000-0000-0000-000000000006")!,
            name: "Archived",
            createdAt: start,
            archivedAt: start.addingTimeInterval(90)
        )
        let completed = CompletedSession(
            id: UUID(uuidString: "70000000-0000-0000-0000-000000000007")!,
            projectID: active.id,
            projectName: active.name,
            type: .coding,
            goal: "Preserve goal",
            outcome: "Preserve outcome",
            startedAt: start,
            endedAt: start.addingTimeInterval(120),
            pauseIntervals: [PauseInterval(
                id: UUID(uuidString: "80000000-0000-0000-0000-000000000008")!,
                startedAt: start.addingTimeInterval(30),
                endedAt: start.addingTimeInterval(45)
            )],
            gitContext: GitSessionContext(
                repositoryRoot: "/tmp/legacy",
                branchAtStart: "main",
                startHeadSHA: String(repeating: "a", count: 40),
                startWasDetached: false
            )
        )
        let legacyState = AppState(
            projects: [active, archived],
            completedSessions: [completed],
            settings: CodePulseSettings(globalShortcutEnabled: false)
        )
        let legacyData = try makeLegacyStateData(from: legacyState)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseWorkspaceMigration-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try legacyData.write(to: url)

        let firstPersistence = JSONFilePersistence(fileURL: url)
        let migrated = firstPersistence.load()
        XCTAssertEqual(firstPersistence.loadStatus, .loaded)
        XCTAssertEqual(migrated.schemaVersion, CodePulseStateSchema.currentVersion)
        XCTAssertEqual(migrated.workspaces.count, 1)
        XCTAssertEqual(migrated.workspaces[0].name, WorkspaceRecord.defaultName)
        XCTAssertEqual(Set(migrated.projects.map(\.workspaceID)), [migrated.workspaces[0].id])
        XCTAssertTrue(migrated.projects.first(where: { $0.id == archived.id })?.isArchived == true)
        XCTAssertEqual(migrated.completedSessions, [completed])

        let persistedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        XCTAssertEqual(persistedObject["schemaVersion"] as? Int, CodePulseStateSchema.currentVersion)
        XCTAssertEqual((persistedObject["workspaces"] as? [[String: Any]])?.count, 1)

        let secondPersistence = JSONFilePersistence(fileURL: url)
        let relaunched = secondPersistence.load()
        XCTAssertEqual(relaunched, migrated)
        XCTAssertEqual(relaunched.workspaces[0].id, migrated.workspaces[0].id)
    }

    func testExplicitSchemaOneLegacyStateMigratesSuccessfully() throws {
        let project = ProjectRecord(name: "Schema One", createdAt: start)
        let legacyData = try makeLegacyStateData(
            from: AppState(projects: [project]),
            schemaVersion: CodePulseStateSchema.legacyVersion
        )
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseExplicitSchemaOne-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try legacyData.write(to: url)

        let persistence = JSONFilePersistence(fileURL: url)
        let migrated = persistence.load()
        XCTAssertEqual(persistence.loadStatus, .loaded)
        XCTAssertEqual(migrated.schemaVersion, CodePulseStateSchema.currentVersion)
        XCTAssertEqual(migrated.workspaces.count, 1)
        XCTAssertEqual(migrated.projects.map(\.workspaceID), [migrated.workspaces[0].id])
    }

    func testWorkspaceAwareStateWithoutSchemaVersionEntersRecoveryAndLeavesBytesUnchanged() throws {
        var object = try jsonObject(makeWorkspaceAwareState())
        object.removeValue(forKey: "schemaVersion")
        try assertStateRejected(
            try JSONSerialization.data(withJSONObject: object),
            prefix: "CodePulseWorkspaceStateWithoutSchema"
        )
    }

    func testWorkspaceAwareStateWithSchemaVersionOneEntersRecoveryAndLeavesBytesUnchanged() throws {
        var object = try jsonObject(makeWorkspaceAwareState())
        object["schemaVersion"] = CodePulseStateSchema.legacyVersion
        try assertStateRejected(
            try JSONSerialization.data(withJSONObject: object),
            prefix: "CodePulseWorkspaceStateSchemaOne"
        )
    }

    func testUnversionedStateContainingProjectWorkspaceIDEntersRecoveryAndLeavesBytesUnchanged() throws {
        var object = try jsonObject(makeWorkspaceAwareState())
        object.removeValue(forKey: "schemaVersion")
        object.removeValue(forKey: "workspaces")
        var settings = try XCTUnwrap(object["settings"] as? [String: Any])
        settings.removeValue(forKey: "selectedWorkspaceID")
        object["settings"] = settings
        try assertStateRejected(
            try JSONSerialization.data(withJSONObject: object),
            prefix: "CodePulseWorkspaceStateProjectWorkspaceID"
        )
    }

    func testUnversionedStateContainingWorkspaceCollectionEntersRecoveryAndLeavesBytesUnchanged() throws {
        var object = try jsonObject(makeWorkspaceAwareState())
        object.removeValue(forKey: "schemaVersion")
        var projects = try XCTUnwrap(object["projects"] as? [[String: Any]])
        for index in projects.indices {
            projects[index].removeValue(forKey: "workspaceID")
        }
        object["projects"] = projects
        var settings = try XCTUnwrap(object["settings"] as? [String: Any])
        settings.removeValue(forKey: "selectedWorkspaceID")
        object["settings"] = settings
        try assertStateRejected(
            try JSONSerialization.data(withJSONObject: object),
            prefix: "CodePulseWorkspaceStateWorkspaces"
        )
    }

    func testUnversionedStateContainingSelectedWorkspaceIDEntersRecoveryAndLeavesBytesUnchanged() throws {
        var object = try jsonObject(makeWorkspaceAwareState())
        object.removeValue(forKey: "schemaVersion")
        object.removeValue(forKey: "workspaces")
        var projects = try XCTUnwrap(object["projects"] as? [[String: Any]])
        for index in projects.indices {
            projects[index].removeValue(forKey: "workspaceID")
        }
        object["projects"] = projects
        try assertStateRejected(
            try JSONSerialization.data(withJSONObject: object),
            prefix: "CodePulseWorkspaceStateSelectedWorkspaceID"
        )
    }

    func testLegacyMigrationFailureLeavesOriginalBytesAndCanRetry() throws {
        let project = ProjectRecord(name: "Legacy", createdAt: start)
        let legacyData = try makeLegacyStateData(from: AppState(projects: [project]))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseWorkspaceMigrationFailure-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try legacyData.write(to: url)

        let failing = JSONFilePersistence(fileURL: url, failureInjector: { point in
            if case .candidateWrite = point {
                throw NSError(domain: "WorkspaceMigrationTests", code: 1)
            }
        })
        XCTAssertTrue(failing.loadStatus == .notLoaded)
        _ = failing.load()
        XCTAssertTrue(failing.loadStatus.requiresRecovery)
        XCTAssertEqual(try Data(contentsOf: url), legacyData)

        let retry = JSONFilePersistence(fileURL: url)
        let migrated = retry.load()
        XCTAssertEqual(retry.loadStatus, .loaded)
        XCTAssertEqual(migrated.workspaces.count, 1)
        XCTAssertEqual(migrated.projects.count, 1)
    }

    func testInvalidNewSchemaWorkspaceReferenceFailsWithoutRepair() throws {
        let workspaceID = UUID(uuidString: "90000000-0000-0000-0000-000000000009")!
        let state = AppState(
            workspaces: [WorkspaceRecord(id: workspaceID, name: "Valid", createdAt: start)],
            projects: [ProjectRecord(workspaceID: workspaceID, name: "Project", createdAt: start)]
        )
        var object = try XCTUnwrap(try jsonObject(state))
        var projects = try XCTUnwrap(object["projects"] as? [[String: Any]])
        projects[0]["workspaceID"] = UUID().uuidString
        object["projects"] = projects
        let data = try JSONSerialization.data(withJSONObject: object)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseWorkspaceInvalid-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: url)

        let persistence = JSONFilePersistence(fileURL: url)
        _ = persistence.load()
        XCTAssertTrue(persistence.loadStatus.requiresRecovery)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testStateIntegrityRejectsDuplicateWorkspaceAndProjectIdentifiers() throws {
        let workspaceID = UUID(uuidString: "91000000-0000-0000-0000-000000000009")!
        let duplicateWorkspaceState = AppState(
            workspaces: [
                WorkspaceRecord(id: workspaceID, name: "First", createdAt: start),
                WorkspaceRecord(id: workspaceID, name: "Duplicate", createdAt: start)
            ]
        )
        XCTAssertThrowsError(try AppStateIntegrityValidator.validate(duplicateWorkspaceState)) { error in
            XCTAssertEqual(error as? AppStateIntegrityError, .duplicateWorkspaceID)
        }

        let projectID = UUID(uuidString: "92000000-0000-0000-0000-000000000009")!
        let duplicateProjectState = AppState(
            workspaces: [WorkspaceRecord(id: workspaceID, name: "Valid", createdAt: start)],
            projects: [
                ProjectRecord(id: projectID, workspaceID: workspaceID, name: "First", createdAt: start),
                ProjectRecord(id: projectID, workspaceID: workspaceID, name: "Duplicate", createdAt: start)
            ]
        )
        XCTAssertThrowsError(try AppStateIntegrityValidator.validate(duplicateProjectState)) { error in
            XCTAssertEqual(error as? AppStateIntegrityError, .duplicateProjectID)
        }
    }

    func testNewSchemaMissingCoreProjectCollectionFailsSafely() throws {
        let state = AppState()
        var object = try XCTUnwrap(try jsonObject(state))
        object.removeValue(forKey: "projects")
        let data = try JSONSerialization.data(withJSONObject: object)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseWorkspaceMissingProjects-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: url)

        let persistence = JSONFilePersistence(fileURL: url)
        _ = persistence.load()
        XCTAssertTrue(persistence.loadStatus.requiresRecovery)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    func testInvalidSelectedWorkspaceNormalizesAndPersistsValidSelection() throws {
        let firstID = UUID(uuidString: "A0000000-0000-0000-0000-00000000000A")!
        let secondID = UUID(uuidString: "B0000000-0000-0000-0000-00000000000B")!
        let state = AppState(
            workspaces: [
                WorkspaceRecord(id: firstID, name: "First", createdAt: start),
                WorkspaceRecord(id: secondID, name: "Second", createdAt: start)
            ],
            settings: CodePulseSettings(selectedWorkspaceID: secondID)
        )
        var object = try XCTUnwrap(try jsonObject(state))
        var settings = try XCTUnwrap(object["settings"] as? [String: Any])
        settings["selectedWorkspaceID"] = UUID().uuidString
        object["settings"] = settings
        let data = try JSONSerialization.data(withJSONObject: object)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseWorkspaceSelection-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: url)

        let persistence = JSONFilePersistence(fileURL: url)
        let normalized = persistence.load()
        XCTAssertEqual(normalized.settings.selectedWorkspaceID, firstID)
        let persisted = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let persistedSettings = try XCTUnwrap(persisted["settings"] as? [String: Any])
        XCTAssertEqual(persistedSettings["selectedWorkspaceID"] as? String, firstID.uuidString)
    }

    func testV1BackupImportsIntoExactlyOneDefaultWorkspace() throws {
        let first = ProjectRecord(name: "First", createdAt: start)
        let archived = ProjectRecord(name: "Archived", createdAt: start, archivedAt: start)
        let state = AppState(projects: [first, archived])
        let object = try makeV1BackupObject(from: state)

        let backup = try CodePulseBackupCodec.decode(try JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(backup.version, 1)
        XCTAssertEqual(backup.state.workspaces.count, 1)
        XCTAssertEqual(backup.state.workspaces[0].name, WorkspaceRecord.defaultName)
        XCTAssertEqual(Set(backup.state.projects.map(\.workspaceID)), [backup.state.workspaces[0].id])
        XCTAssertTrue(backup.state.projects.contains(where: \.isArchived))
    }

    func testV1BackupContainingWorkspacesIsRejected() throws {
        var object = try makeV1BackupObject(from: AppState(
            projects: [ProjectRecord(name: "Legacy", createdAt: start)]
        ))
        var state = try XCTUnwrap(object["state"] as? [String: Any])
        state["workspaces"] = [try jsonObject(WorkspaceRecord(
            id: UUID(),
            name: WorkspaceRecord.defaultName,
            createdAt: start,
            updatedAt: start
        ))]
        object["state"] = state

        XCTAssertThrowsError(try CodePulseBackupCodec.decode(try JSONSerialization.data(withJSONObject: object))) { error in
            XCTAssertEqual(error as? CodePulseBackupError, .malformedConfiguration)
        }
    }

    func testV1BackupContainingProjectWorkspaceIDIsRejected() throws {
        var object = try makeV1BackupObject(from: AppState(
            projects: [ProjectRecord(name: "Legacy", createdAt: start)]
        ))
        var state = try XCTUnwrap(object["state"] as? [String: Any])
        var projects = try XCTUnwrap(state["projects"] as? [[String: Any]])
        projects[0]["workspaceID"] = UUID().uuidString
        state["projects"] = projects
        object["state"] = state

        XCTAssertThrowsError(try CodePulseBackupCodec.decode(try JSONSerialization.data(withJSONObject: object))) { error in
            XCTAssertEqual(error as? CodePulseBackupError, .malformedConfiguration)
        }
    }

    func testV1BackupContainingSelectedWorkspaceIDIsRejected() throws {
        var object = try makeV1BackupObject(from: AppState(
            projects: [ProjectRecord(name: "Legacy", createdAt: start)]
        ))
        var state = try XCTUnwrap(object["state"] as? [String: Any])
        var settings = try XCTUnwrap(state["settings"] as? [String: Any])
        settings["selectedWorkspaceID"] = UUID().uuidString
        state["settings"] = settings
        object["state"] = state

        XCTAssertThrowsError(try CodePulseBackupCodec.decode(try JSONSerialization.data(withJSONObject: object))) { error in
            XCTAssertEqual(error as? CodePulseBackupError, .malformedConfiguration)
        }
    }

    func testV1BackupContainingSchemaTwoMetadataIsRejected() throws {
        var object = try makeV1BackupObject(from: AppState(
            projects: [ProjectRecord(name: "Legacy", createdAt: start)]
        ))
        var state = try XCTUnwrap(object["state"] as? [String: Any])
        state["schemaVersion"] = CodePulseStateSchema.currentVersion
        object["state"] = state

        XCTAssertThrowsError(try CodePulseBackupCodec.decode(try JSONSerialization.data(withJSONObject: object))) { error in
            XCTAssertEqual(error as? CodePulseBackupError, .malformedConfiguration)
        }
    }

    func testV2BackupRoundTripPreservesWorkspaceRelationships() throws {
        let firstID = UUID(uuidString: "C0000000-0000-0000-0000-00000000000C")!
        let secondID = UUID(uuidString: "D0000000-0000-0000-0000-00000000000D")!
        let state = AppState(
            workspaces: [
                WorkspaceRecord(id: firstID, name: "First", createdAt: start),
                WorkspaceRecord(id: secondID, name: "Second", createdAt: start)
            ],
            projects: [
                ProjectRecord(workspaceID: firstID, name: "One", createdAt: start),
                ProjectRecord(workspaceID: secondID, name: "Two", createdAt: start)
            ],
            settings: CodePulseSettings(selectedWorkspaceID: secondID)
        )

        let data = try CodePulseBackupCodec.encode(state: state, exportedAt: start)
        let backup = try CodePulseBackupCodec.decode(data)
        XCTAssertEqual(backup.version, CodePulseBackup.currentVersion)
        XCTAssertEqual(backup.state, state)
        XCTAssertEqual(backup.state.projects.map(\.workspaceID), [firstID, secondID])
    }

    func testV2BackupRejectsDanglingWorkspaceReference() throws {
        let workspaceID = UUID(uuidString: "E0000000-0000-0000-0000-00000000000E")!
        let state = AppState(
            workspaces: [WorkspaceRecord(id: workspaceID, name: "Valid", createdAt: start)],
            projects: [ProjectRecord(workspaceID: workspaceID, name: "Project", createdAt: start)]
        )
        var object = try XCTUnwrap(try jsonObjectData(try CodePulseBackupCodec.encode(state: state, exportedAt: start)))
        var stateObject = try XCTUnwrap(object["state"] as? [String: Any])
        var projects = try XCTUnwrap(stateObject["projects"] as? [[String: Any]])
        projects[0]["workspaceID"] = UUID().uuidString
        stateObject["projects"] = projects
        object["state"] = stateObject

        XCTAssertThrowsError(try CodePulseBackupCodec.decode(try JSONSerialization.data(withJSONObject: object))) { error in
            XCTAssertEqual(error as? CodePulseBackupError, .invalidWorkspaceReference)
        }
    }

    func testV2BackupRejectsDuplicateWorkspaceIdentifiers() throws {
        let firstID = UUID(uuidString: "F0000000-0000-0000-0000-00000000000F")!
        let secondID = UUID(uuidString: "F0000000-0000-0000-0000-000000000010")!
        let state = AppState(
            workspaces: [
                WorkspaceRecord(id: firstID, name: "First", createdAt: start),
                WorkspaceRecord(id: secondID, name: "Second", createdAt: start)
            ]
        )
        var object = try XCTUnwrap(try jsonObjectData(try CodePulseBackupCodec.encode(state: state, exportedAt: start)))
        var stateObject = try XCTUnwrap(object["state"] as? [String: Any])
        var workspaces = try XCTUnwrap(stateObject["workspaces"] as? [[String: Any]])
        workspaces[1]["id"] = firstID.uuidString
        stateObject["workspaces"] = workspaces
        object["state"] = stateObject

        XCTAssertThrowsError(try CodePulseBackupCodec.decode(try JSONSerialization.data(withJSONObject: object))) { error in
            XCTAssertEqual(error as? CodePulseBackupError, .duplicateIdentifier("workspace"))
        }
    }

    private func makeLegacyStateData(from state: AppState, schemaVersion: Int? = nil) throws -> Data {
        var object = try XCTUnwrap(try jsonObject(state))
        object.removeValue(forKey: "schemaVersion")
        object.removeValue(forKey: "workspaces")
        var settings = try XCTUnwrap(object["settings"] as? [String: Any])
        settings.removeValue(forKey: "selectedWorkspaceID")
        object["settings"] = settings
        var projects = try XCTUnwrap(object["projects"] as? [[String: Any]])
        for index in projects.indices {
            projects[index].removeValue(forKey: "workspaceID")
        }
        object["projects"] = projects
        if let schemaVersion {
            object["schemaVersion"] = schemaVersion
        }
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func makeWorkspaceAwareState() -> AppState {
        let firstID = UUID(uuidString: "A1000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "A2000000-0000-0000-0000-000000000002")!
        return AppState(
            workspaces: [
                WorkspaceRecord(id: firstID, name: "First", createdAt: start),
                WorkspaceRecord(id: secondID, name: "Second", createdAt: start)
            ],
            projects: [
                ProjectRecord(workspaceID: firstID, name: "One", createdAt: start),
                ProjectRecord(workspaceID: secondID, name: "Two", createdAt: start)
            ],
            settings: CodePulseSettings(selectedWorkspaceID: secondID)
        )
    }

    private func assertStateRejected(_ data: Data, prefix: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: url)

        let persistence = JSONFilePersistence(fileURL: url)
        _ = persistence.load()
        XCTAssertTrue(persistence.loadStatus.requiresRecovery)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    private func makeV1BackupObject(from state: AppState) throws -> [String: Any] {
        var object = try XCTUnwrap(try jsonObjectData(try CodePulseBackupCodec.encode(state: state, exportedAt: start)))
        object["version"] = 1
        var stateObject = try XCTUnwrap(object["state"] as? [String: Any])
        stateObject.removeValue(forKey: "schemaVersion")
        stateObject.removeValue(forKey: "workspaces")
        var settings = try XCTUnwrap(stateObject["settings"] as? [String: Any])
        settings.removeValue(forKey: "selectedWorkspaceID")
        stateObject["settings"] = settings
        var projects = try XCTUnwrap(stateObject["projects"] as? [[String: Any]])
        for index in projects.indices {
            projects[index].removeValue(forKey: "workspaceID")
        }
        stateObject["projects"] = projects
        object["state"] = stateObject
        return object
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any]
        )
    }

    private func jsonObjectData(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
