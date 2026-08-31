import Foundation
import XCTest
@testable import CodePulse

private struct Phase6Clock: SessionClock {
    let now: Date
}

@MainActor
final class Phase6BackupReleaseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testV3WireShapeIsCollectionOnlyAndOmitsMachineLocalState() throws {
        var state = AppState(activeSessions: [ActiveSession(startedAt: now)])
        state.controlProcessing = CodePulseControlProcessingState()
        state.developerToolIntegration = DeveloperToolIntegrationProcessingState()
        state.localInputAcceptanceDate = now

        let root = try object(CodePulseBackupCodec.encode(state: state, exportedAt: now))
        let wire = try XCTUnwrap(root["state"] as? [String: Any])
        XCTAssertEqual(root["version"] as? Int, 3)
        XCTAssertEqual(wire["schemaVersion"] as? Int, 3)
        XCTAssertEqual((wire["activeSessions"] as? [[String: Any]])?.count, 1)
        XCTAssertFalse(wire.keys.contains("activeSession"))
        XCTAssertFalse(wire.keys.contains("developerToolIntegration"))
        XCTAssertFalse(wire.keys.contains("controlProcessing"))
        XCTAssertFalse(wire.keys.contains("localInputAcceptanceDate"))

        let emptyWire = try XCTUnwrap(object(
            CodePulseBackupCodec.encode(state: AppState(), exportedAt: now)
        )["state"] as? [String: Any])
        XCTAssertEqual((emptyWire["activeSessions"] as? [[String: Any]])?.count, 0)
    }

    func testV3RoundTripsZeroOneTwoAndSixteenExactActiveIdentities() throws {
        for count in [0, 1, 2, 16] {
            let sessions = (0..<count).map { offset in
                ActiveSession(
                    id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", offset + 1))!,
                    startedAt: now.addingTimeInterval(Double(offset))
                )
            }
            let decoded = try CodePulseBackupCodec.decode(CodePulseBackupCodec.encode(
                state: AppState(activeSessions: sessions),
                exportedAt: now
            ))
            XCTAssertEqual(decoded.state.activeSessions.map(\.id), sessions.map(\.id), "count \(count)")
        }
    }

    func testV3RejectsSeventeenSessionsDuplicateIDsAndHistoryCollision() throws {
        var root = try object(CodePulseBackupCodec.encode(
            state: AppState(activeSessions: [ActiveSession(startedAt: now)]),
            exportedAt: now
        ))
        var wire = try XCTUnwrap(root["state"] as? [String: Any])
        let active = try XCTUnwrap((wire["activeSessions"] as? [[String: Any]])?.first)

        wire["activeSessions"] = (0..<17).map { index -> [String: Any] in
            var record = active
            record["id"] = String(format: "10000000-0000-0000-0000-%012d", index + 1)
            return record
        }
        root["state"] = wire
        assertDecode(root, equals: .invalidTimeline)

        var duplicateRoot = root
        var duplicateWire = wire
        duplicateWire["activeSessions"] = [active, active]
        duplicateRoot["state"] = duplicateWire
        assertDecode(duplicateRoot, equals: .duplicateIdentifier("session"))

        var collisionRoot = try object(CodePulseBackupCodec.encode(
            state: AppState(completedSessions: [CompletedSession(
                id: UUID(uuidString: "77777777-7777-7777-7777-777777777777")!,
                projectID: nil,
                projectName: nil,
                goal: nil,
                outcome: nil,
                startedAt: now,
                endedAt: now.addingTimeInterval(10),
                pauseIntervals: []
            )]),
            exportedAt: now
        ))
        var collisionWire = try XCTUnwrap(collisionRoot["state"] as? [String: Any])
        var collidingActive = active
        collidingActive["id"] = "77777777-7777-7777-7777-777777777777"
        collisionWire["activeSessions"] = [collidingActive]
        collisionRoot["state"] = collisionWire
        assertDecode(collisionRoot, equals: .duplicateIdentifier("session"))
    }

    func testV3StrictShapeAndMachineLocalHybridsAreRejected() throws {
        let base = try object(CodePulseBackupCodec.encode(state: AppState(), exportedAt: now))
        for mutation in ["activeSession", "developerToolIntegration", "controlProcessing", "localInputAcceptanceDate"] {
            var root = base
            var wire = try XCTUnwrap(root["state"] as? [String: Any])
            wire[mutation] = NSNull()
            root["state"] = wire
            assertDecode(root, equals: .malformedConfiguration)
        }

        var missing = base
        var missingWire = try XCTUnwrap(missing["state"] as? [String: Any])
        missingWire.removeValue(forKey: "activeSessions")
        missing["state"] = missingWire
        assertDecode(missing, equals: .missingRequiredField("active Sessions"))

        var schemaTwo = base
        var schemaTwoWire = try XCTUnwrap(schemaTwo["state"] as? [String: Any])
        schemaTwoWire["schemaVersion"] = 2
        schemaTwo["state"] = schemaTwoWire
        assertDecode(schemaTwo, equals: .missingRequiredField("workspace schema"))
    }

    func testV3RejectsInvalidReferencesTimelinesPausesAndOwnership() throws {
        let workspace = WorkspaceRecord(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            name: "Workspace",
            createdAt: now
        )
        let project = ProjectRecord(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            workspaceID: workspace.id,
            name: "Project",
            createdAt: now
        )
        let state = AppState(
            workspaces: [workspace],
            projects: [project],
            activeSessions: [ActiveSession(projectID: project.id, projectName: project.name, startedAt: now)]
        )
        let base = try object(CodePulseBackupCodec.encode(state: state, exportedAt: now))

        var missingProject = base
        var wire = try XCTUnwrap(missingProject["state"] as? [String: Any])
        var active = try XCTUnwrap((wire["activeSessions"] as? [[String: Any]])?.first)
        active["projectID"] = "33333333-3333-3333-3333-333333333333"
        wire["activeSessions"] = [active]
        missingProject["state"] = wire
        assertDecode(missingProject, equals: .invalidWorkspaceReference)

        var archived = base
        wire = try XCTUnwrap(archived["state"] as? [String: Any])
        var projects = try XCTUnwrap(wire["projects"] as? [[String: Any]])
        projects[0]["archivedAt"] = "2027-01-15T08:00:00Z"
        wire["projects"] = projects
        archived["state"] = wire
        assertDecode(archived, equals: .invalidWorkspaceReference)

        var missingWorkspace = base
        wire = try XCTUnwrap(missingWorkspace["state"] as? [String: Any])
        projects = try XCTUnwrap(wire["projects"] as? [[String: Any]])
        projects[0]["workspaceID"] = "44444444-4444-4444-4444-444444444444"
        wire["projects"] = projects
        missingWorkspace["state"] = wire
        assertDecode(missingWorkspace, equals: .invalidWorkspaceReference)

        var runningEnded = base
        wire = try XCTUnwrap(runningEnded["state"] as? [String: Any])
        active = try XCTUnwrap((wire["activeSessions"] as? [[String: Any]])?.first)
        active["endedAt"] = "2027-01-15T08:01:00Z"
        wire["activeSessions"] = [active]
        runningEnded["state"] = wire
        assertDecode(runningEnded, equals: .invalidTimeline)

        var finishingWithoutEnd = base
        wire = try XCTUnwrap(finishingWithoutEnd["state"] as? [String: Any])
        active = try XCTUnwrap((wire["activeSessions"] as? [[String: Any]])?.first)
        active["phase"] = "finishing"
        active["endedAt"] = NSNull()
        wire["activeSessions"] = [active]
        finishingWithoutEnd["state"] = wire
        assertDecode(finishingWithoutEnd, equals: .invalidTimeline)

        let openPause: [String: Any] = [
            "id": "55555555-5555-5555-5555-555555555555",
            "startedAt": "2027-01-15T08:00:01Z",
            "endedAt": NSNull()
        ]
        var runningOpenPause = base
        wire = try XCTUnwrap(runningOpenPause["state"] as? [String: Any])
        active = try XCTUnwrap((wire["activeSessions"] as? [[String: Any]])?.first)
        active["pauseIntervals"] = [openPause]
        wire["activeSessions"] = [active]
        runningOpenPause["state"] = wire
        assertDecode(runningOpenPause, equals: .invalidTimeline)

        var multipleOpen = runningOpenPause
        wire = try XCTUnwrap(multipleOpen["state"] as? [String: Any])
        active = try XCTUnwrap((wire["activeSessions"] as? [[String: Any]])?.first)
        active["phase"] = "paused"
        var secondPause = openPause
        secondPause["id"] = "66666666-6666-6666-6666-666666666666"
        secondPause["startedAt"] = "2027-01-15T08:00:02Z"
        active["pauseIntervals"] = [openPause, secondPause]
        wire["activeSessions"] = [active]
        multipleOpen["state"] = wire
        assertDecode(multipleOpen, equals: .invalidTimeline)

        var ownedState = AppState(
            workspaces: [workspace],
            projects: [project],
            activeSessions: [ownedSession(project: project, thread: "thread-a", offset: 0),
                             ownedSession(project: project, thread: "thread-b", offset: 1)]
        )
        ownedState.seedDeveloperToolReservationsFromActiveOwnership()
        var duplicateOwner = try object(CodePulseBackupCodec.encode(state: ownedState, exportedAt: now))
        wire = try XCTUnwrap(duplicateOwner["state"] as? [String: Any])
        var owned = try XCTUnwrap(wire["activeSessions"] as? [[String: Any]])
        setThread("thread-a", in: &owned[1])
        wire["activeSessions"] = owned
        duplicateOwner["state"] = wire
        assertDecode(duplicateOwner, equals: .invalidTimeline)

        var malformedOwner = try object(CodePulseBackupCodec.encode(state: ownedState, exportedAt: now))
        wire = try XCTUnwrap(malformedOwner["state"] as? [String: Any])
        owned = try XCTUnwrap(wire["activeSessions"] as? [[String: Any]])
        setThread(" bad ", in: &owned[0])
        wire["activeSessions"] = owned
        malformedOwner["state"] = wire
        assertDecode(malformedOwner, equals: .invalidTimeline)
    }

    func testGenuineV2FixtureMigratesExactSingularActiveIdentity() throws {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "v1_4_backup_v2",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let data = try Data(contentsOf: url)
        let root = try object(data)
        let wire = try XCTUnwrap(root["state"] as? [String: Any])
        XCTAssertEqual(root["version"] as? Int, 2)
        XCTAssertEqual(wire["schemaVersion"] as? Int, 2)
        XCTAssertNotNil(wire["activeSession"] as? [String: Any])
        XCTAssertNil(wire["activeSessions"])

        let imported = try CodePulseBackupCodec.decode(data)
        XCTAssertEqual(imported.state.schemaVersion, 3)
        XCTAssertEqual(imported.state.activeSessions.map(\.id), [
            UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        ])
        XCTAssertEqual(imported.state.activeSessions.first?.pauseIntervals.count, 1)
        XCTAssertEqual(imported.state.activeSessions.first?.developerToolContexts.count, 1)
    }

    func testV1V2V3PreviewCountsFollowValidatedCanonicalState() throws {
        let v1URL = try XCTUnwrap(Bundle.module.url(
            forResource: "v0_8_backup",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let v2URL = try XCTUnwrap(Bundle.module.url(
            forResource: "v1_4_backup_v2",
            withExtension: "json",
            subdirectory: "Fixtures"
        ))
        let v1 = try CodePulseBackupCodec.decode(Data(contentsOf: v1URL))
        let v2 = try CodePulseBackupCodec.decode(Data(contentsOf: v2URL))
        let v3 = try CodePulseBackupCodec.decode(CodePulseBackupCodec.encode(
            state: AppState(activeSessions: [ActiveSession(startedAt: now), ActiveSession(startedAt: now)]),
            exportedAt: now
        ))
        XCTAssertEqual(CodePulseBackupPreview(backup: v1, state: v1.state).activeSessionCount, 1)
        XCTAssertEqual(CodePulseBackupPreview(backup: v2, state: v2.state).activeSessionCount, 1)
        XCTAssertEqual(CodePulseBackupPreview(backup: v3, state: v3.state).activeSessionCount, 2)
    }

    func testRestoreIsBlockedDuringPerSessionGitCaptureWithoutPublishingCandidate() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulse-Phase6-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("CodePulse/state.json")
        let original = AppState(settings: CodePulseSettings(globalShortcutEnabled: false))
        let persistence = JSONFilePersistence(fileURL: stateURL)
        persistence.save(original)
        let store = SessionStore(
            persistence: persistence,
            clock: Phase6Clock(now: now),
            automaticallyRefresh: false
        )
        let backupURL = root.appendingPathComponent("candidate.json")
        try CodePulseBackupCodec.encode(
            state: AppState(settings: CodePulseSettings(menuBarDisplay: .timerOnly)),
            exportedAt: now
        ).write(to: backupURL)
        let candidate = try store.inspectBackup(at: backupURL)
        let captureID = UUID()
        let capture = SessionGitCaptureState(startStatus: .running, activeStage: .start)
        store.setGitCaptureStateForPresentationTesting(capture, sessionID: captureID)

        XCTAssertThrowsError(try store.restoreBackup(candidate)) { error in
            guard case .activeSession = (error as? BackupRestoreError) else {
                return XCTFail("Expected active-session restore guard, got \(error)")
            }
        }
        XCTAssertEqual(store.state, original)
        XCTAssertEqual(persistence.load(), original)
        XCTAssertEqual(store.gitCaptureStatus(for: captureID), .running)
    }

    func testReleaseMetadataAndSettingsCopyAreV15AndCountAware() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appendingPathComponent("Resources/Info.plist")),
            format: nil
        ) as? [String: Any])
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "1.5.0")
        XCTAssertEqual(plist["CFBundleVersion"] as? String, "1500")
        XCTAssertEqual(plist["SUPublicEDKey"] as? String, "EX4J6W41dIHFiPsqUhlk6Jp/VsX/2AxoYmCDlsqzuDM=")

        let settings = try String(contentsOf: root.appendingPathComponent(
            "Sources/CodePulse/Settings/SettingsView.swift"
        ))
        XCTAssertTrue(settings.contains("preview.activeSessionCount > 0"))
        XCTAssertTrue(settings.contains("active \\(preview.activeSessionCount == 1 ? \"session\" : \"sessions\")"))
        XCTAssertFalse(settings.contains("if preview.includesActiveSession"))
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func ownedSession(project: ProjectRecord, thread: String, offset: TimeInterval) -> ActiveSession {
        ActiveSession(
            projectID: project.id,
            projectName: project.name,
            startedAt: now.addingTimeInterval(offset),
            automationMetadata: SessionAutomationMetadata(
                startedByRuleID: UUID(),
                startedByRuleName: "Rule",
                startedBySource: .developerTool(tool: .codex, externalSessionID: thread),
                lastMatchingSignalAt: now.addingTimeInterval(offset),
                pauseDelay: 60,
                finishDelay: 300,
                minimumSavedDuration: 60,
                claims: [SessionAutomationClaim(
                    source: .developerTool(tool: .codex, externalSessionID: thread),
                    isActive: true,
                    lastSignalAt: now.addingTimeInterval(offset)
                )]
            )
        )
    }

    private func setThread(_ thread: String, in session: inout [String: Any]) {
        guard var metadata = session["automationMetadata"] as? [String: Any] else { return }
        if var source = metadata["startedBySource"] as? [String: Any] {
            source["externalSessionID"] = thread
            metadata["startedBySource"] = source
        }
        if var claims = metadata["claims"] as? [[String: Any]],
           var source = claims.first?["source"] as? [String: Any] {
            source["externalSessionID"] = thread
            claims[0]["source"] = source
            metadata["claims"] = claims
        }
        session["automationMetadata"] = metadata
    }

    private func assertDecode(
        _ root: [String: Any],
        equals expected: CodePulseBackupError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try CodePulseBackupCodec.decode(try JSONSerialization.data(withJSONObject: root)),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? CodePulseBackupError, expected, file: file, line: line)
        }
    }
}
