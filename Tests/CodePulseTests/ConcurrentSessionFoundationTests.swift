import CodePulseIntegration
import Foundation
import XCTest
@testable import CodePulse

final class ConcurrentSessionFoundationTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 2_000_000_000)

    func testSchemaTwoWithoutActiveSessionMigratesToCanonicalEmptyCollection() throws {
        let data = try schemaTwoData(active: nil)
        let state = try decodeState(data)

        XCTAssertEqual(state.schemaVersion, CodePulseStateSchema.currentVersion)
        XCTAssertTrue(state.activeSessions.isEmpty)
        XCTAssertNil(state.activeSession)
        let object = try jsonObject(state)
        XCTAssertNotNil(object["activeSessions"])
        XCTAssertNil(object["activeSession"])
    }

    func testSchemaTwoActiveSessionMigratesWithoutChangingIdentityOrContent() throws {
        let active = ActiveSession(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            projectName: "Preserved",
            type: .review,
            goal: "Keep all fields",
            startedAt: date
        )
        let state = try decodeState(schemaTwoData(active: active))

        XCTAssertEqual(state.activeSessions, [active])
        XCTAssertEqual(state.activeSessions[0].id, active.id)
        XCTAssertEqual(state.activeSessions[0].goal, active.goal)
        XCTAssertEqual(state.activeSessions[0].type, active.type)
    }

    func testSchemaOneMigrationPreservesWorkspaceConversionAndActiveIdentity() throws {
        let project = ProjectRecord(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            name: "Legacy",
            createdAt: date
        )
        let active = ActiveSession(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            projectID: project.id,
            projectName: project.name,
            startedAt: date
        )
        let state = try decodeState(schemaOneData(project: project, active: active))

        XCTAssertEqual(state.schemaVersion, CodePulseStateSchema.currentVersion)
        XCTAssertEqual(state.activeSessions.map(\.id), [active.id])
        XCTAssertEqual(state.projects.map(\.id), [project.id])
        XCTAssertEqual(state.projects[0].workspaceID, state.workspaces[0].id)
    }

    func testSchemaOneMigrationWithoutActiveSessionProducesEmptyCollection() throws {
        let project = ProjectRecord(
            id: UUID(uuidString: "23232323-2323-2323-2323-232323232323")!,
            name: "Legacy without active",
            createdAt: date
        )
        let state = try decodeState(schemaOneData(project: project, active: nil))

        XCTAssertEqual(state.schemaVersion, CodePulseStateSchema.currentVersion)
        XCTAssertTrue(state.activeSessions.isEmpty)
        XCTAssertEqual(state.projects.map(\.id), [project.id])
        XCTAssertEqual(state.workspaces.count, 1)
    }

    func testSchemaThreeLegacyOnlyAndAmbiguousRepresentationsAreRejected() throws {
        let active = ActiveSession(startedAt: date)
        var legacyOnly = try jsonObject(AppState(activeSession: active))
        legacyOnly.removeValue(forKey: "activeSessions")
        legacyOnly["activeSession"] = try jsonObject(active)
        XCTAssertThrowsError(try decodeState(try jsonData(legacyOnly)))

        var both = try jsonObject(AppState(activeSession: active))
        both["activeSession"] = try jsonObject(active)
        XCTAssertThrowsError(try decodeState(try jsonData(both)))
    }

    func testMigratedPersistenceWritesSchemaThreeCollectionOnly() throws {
        let active = ActiveSession(startedAt: date)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseConcurrentMigration-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("state.json")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try schemaTwoData(active: active).write(to: url)

        let persistence = JSONFilePersistence(fileURL: url)
        let migrated = persistence.load()
        XCTAssertEqual(persistence.loadStatus, .loaded)
        XCTAssertEqual(migrated.schemaVersion, CodePulseStateSchema.currentVersion)

        let persisted = try jsonObject(Data(contentsOf: url))
        XCTAssertEqual((persisted["activeSessions"] as? [[String: Any]])?.count, 1)
        XCTAssertNil(persisted["activeSession"])
    }

    func testActiveSessionIntegrityRejectsDuplicateAndHistoryCollision() throws {
        let id = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let first = ActiveSession(id: id, startedAt: date)
        let duplicate = ActiveSession(id: id, startedAt: date)
        XCTAssertThrowsError(try AppStateIntegrityValidator.validate(AppState(activeSessions: [first, duplicate]))) { error in
            XCTAssertEqual(error as? AppStateIntegrityError, .duplicateActiveSessionID(id))
        }

        let completed = CompletedSession(
            id: id,
            projectID: nil,
            projectName: nil,
            goal: nil,
            outcome: nil,
            startedAt: date,
            endedAt: date.addingTimeInterval(1),
            pauseIntervals: []
        )
        XCTAssertThrowsError(try AppStateIntegrityValidator.validate(
            AppState(completedSessions: [completed], activeSessions: [first])
        )) { error in
            XCTAssertEqual(error as? AppStateIntegrityError, .activeSessionHistoryCollision(id))
        }
    }

    func testActiveSessionBoundAcceptsSixteenAndRejectsSeventeen() throws {
        let sixteen = (0..<16).map { index in
            ActiveSession(id: UUID(), startedAt: date.addingTimeInterval(TimeInterval(index)))
        }
        XCTAssertNoThrow(try AppStateIntegrityValidator.validate(AppState(activeSessions: sixteen)))

        let seventeen = sixteen + [ActiveSession(startedAt: date)]
        XCTAssertThrowsError(try AppStateIntegrityValidator.validate(AppState(activeSessions: seventeen))) { error in
            XCTAssertEqual(error as? AppStateIntegrityError, .activeSessionLimitExceeded(17))
        }
    }

    func testActiveSessionIntegrityRejectsDanglingArchivedAndInvalidTimeline() throws {
        let dangling = ActiveSession(projectID: UUID(), startedAt: date)
        XCTAssertThrowsError(try AppStateIntegrityValidator.validate(AppState(activeSessions: [dangling]))) { error in
            XCTAssertEqual(error as? AppStateIntegrityError, .danglingActiveSessionProject(dangling.id))
        }

        let archivedProject = ProjectRecord(name: "Archived", createdAt: date, archivedAt: date)
        let archived = ActiveSession(projectID: archivedProject.id, startedAt: date)
        XCTAssertThrowsError(try AppStateIntegrityValidator.validate(AppState(
            projects: [archivedProject],
            activeSessions: [archived]
        ))) { error in
            XCTAssertEqual(error as? AppStateIntegrityError, .archivedActiveSessionProject(archived.id))
        }

        var invalid = ActiveSession(startedAt: date)
        invalid.phase = .running
        invalid.pauseIntervals = [PauseInterval(startedAt: date.addingTimeInterval(1))]
        XCTAssertThrowsError(try AppStateIntegrityValidator.validate(AppState(activeSessions: [invalid]))) { error in
            XCTAssertEqual(error as? AppStateIntegrityError, .invalidActiveSession(invalid.id))
        }
    }

    func testSessionLookupMutationAndSoleCompatibilityAreIDBased() throws {
        let first = ActiveSession(startedAt: date)
        let second = ActiveSession(startedAt: date.addingTimeInterval(1))
        var state = AppState(activeSessions: [first, second])
        XCTAssertEqual(state.activeSession(id: second.id), second)
        XCTAssertEqual(state.activeSessionIndex(id: first.id), 0)
        XCTAssertNil(state.soleActiveSession)

        try state.mutateActiveSession(id: second.id) { $0.outcome = "targeted" }
        XCTAssertEqual(state.activeSession(id: second.id)?.outcome, "targeted")
        XCTAssertNil(state.activeSession(id: first.id)?.outcome)

        let before = state
        XCTAssertThrowsError(try state.mutateActiveSession(id: UUID()) { $0.outcome = "nope" })
        XCTAssertEqual(state, before)

        let one = AppState(activeSession: first)
        XCTAssertEqual(one.soleActiveSession, first)
        let none = AppState()
        XCTAssertNil(none.soleActiveSession)
    }

    func testDeveloperToolOwnershipDuplicatesAreRejectedAcrossActiveSessions() throws {
        let metadata = automationMetadata(tool: .codex, externalSessionID: "thread-duplicate")
        let first = ActiveSession(startedAt: date, automationMetadata: metadata)
        let second = ActiveSession(startedAt: date.addingTimeInterval(1), automationMetadata: metadata)
        XCTAssertThrowsError(try AppStateIntegrityValidator.validate(AppState(activeSessions: [first, second]))) { error in
            XCTAssertEqual(
                error as? AppStateIntegrityError,
                .duplicateDeveloperToolOwnership(.codex, "thread-duplicate")
            )
        }
    }

    func testDistinctActiveDeveloperToolOwnershipKeysReserveIndependently() throws {
        let metadata = SessionAutomationMetadata(
            startedByRuleID: UUID(),
            startedByRuleName: "Developer Tool",
            startedBySource: .developerTool(tool: .codex, externalSessionID: "thread-a"),
            lastMatchingSignalAt: date,
            pauseDelay: 1,
            finishDelay: 2,
            minimumSavedDuration: 0,
            claims: [
                SessionAutomationClaim(
                    tool: .opencode,
                    externalSessionID: "thread-b",
                    isActive: true,
                    lastSignalAt: date
                ),
                SessionAutomationClaim(
                    tool: .codex,
                    externalSessionID: "inactive",
                    isActive: false,
                    lastSignalAt: date
                )
            ]
        )
        let session = ActiveSession(startedAt: date, automationMetadata: metadata)
        let state = AppState(activeSessions: [session])

        XCTAssertEqual(state.activeDeveloperToolOwnedThreadCount, 2)
        XCTAssertTrue(state.activeDeveloperToolOwnershipIdentities.contains(
            DeveloperToolThreadIdentity(tool: .codex, externalSessionID: "thread-a")
        ))
        XCTAssertTrue(state.activeDeveloperToolOwnershipIdentities.contains(
            DeveloperToolThreadIdentity(tool: .opencode, externalSessionID: "thread-b")
        ))
        XCTAssertFalse(state.activeDeveloperToolOwnershipIdentities.contains(
            DeveloperToolThreadIdentity(tool: .codex, externalSessionID: "inactive")
        ))
        XCTAssertNoThrow(try AppStateIntegrityValidator.validate(state))
    }

    func testAdmissionReservesDistinctOwnershipIdentitiesIdempotently() throws {
        var state = AppState()
        try state.admitDeveloperToolOwner(tool: .codex, externalSessionID: "owner-a", at: date)
        try state.admitDeveloperToolOwner(tool: .codex, externalSessionID: "owner-a", at: date)
        try state.admitDeveloperToolOwner(tool: .opencode, externalSessionID: "owner-a", at: date)

        XCTAssertEqual(state.reservedDeveloperToolOwnershipIdentities.count, 2)
        XCTAssertTrue(state.canAdmitDeveloperToolOwner(
            tool: .codex,
            externalSessionID: "owner-a",
            at: date
        ))
        XCTAssertEqual(state.developerToolThreadCapacityUsed(at: date), 2)
    }

    func testMalformedDeveloperToolOwnershipIsRejectedByIntegrityValidation() throws {
        var metadata = automationMetadata(tool: .codex, externalSessionID: "valid")
        metadata.startedBySource = .developerTool(tool: .codex, externalSessionID: "  ")
        let state = AppState(activeSessions: [ActiveSession(
            startedAt: date,
            automationMetadata: metadata
        )])

        XCTAssertThrowsError(try AppStateIntegrityValidator.validate(state)) { error in
            XCTAssertEqual(error as? AppStateIntegrityError, .malformedDeveloperToolOwnership)
        }
    }

    func testRetiredThreadProtectionBoundaryAndPruning() throws {
        let identity = DeveloperToolThreadIdentity(tool: .codex, externalSessionID: "thread-retired")
        let entry = RetiredDeveloperToolThread(
            tool: identity.tool,
            externalSessionID: identity.externalSessionID,
            retiredAt: date,
            lastAcceptedEventAt: date
        )
        XCTAssertTrue(entry.isProtected(at: date.addingTimeInterval(ConcurrentSessionLimits.retiredDeveloperToolRetention - 1)))
        XCTAssertFalse(entry.isProtected(at: date.addingTimeInterval(ConcurrentSessionLimits.retiredDeveloperToolRetention)))

        var state = AppState(developerToolIntegration: DeveloperToolIntegrationProcessingState(
            retiredDeveloperToolThreads: [entry]
        ))
        state.pruneExpiredRetiredDeveloperToolThreads(at: date.addingTimeInterval(ConcurrentSessionLimits.retiredDeveloperToolRetention))
        XCTAssertTrue(state.developerToolIntegration?.retiredDeveloperToolThreads.isEmpty != false)
    }

    func testRetiredThreadCapacityAdmissionPrunesExpiredBeforeCounting() throws {
        let expired = (0..<2_048).map { index in
            RetiredDeveloperToolThread(
                tool: .codex,
                externalSessionID: "expired-\(index)",
                retiredAt: date.addingTimeInterval(-ConcurrentSessionLimits.retiredDeveloperToolRetention),
                lastAcceptedEventAt: date.addingTimeInterval(-ConcurrentSessionLimits.retiredDeveloperToolRetention)
            )
        }
        var state = AppState(developerToolIntegration: DeveloperToolIntegrationProcessingState(
            retiredDeveloperToolThreads: expired
        ))
        XCTAssertNoThrow(try state.admitDeveloperToolOwner(
            tool: .opencode,
            externalSessionID: "new-owner",
            at: date
        ))
        XCTAssertEqual(state.protectedRetiredDeveloperToolThreadCount(at: date), 0)
        XCTAssertEqual(state.activeDeveloperToolOwnedThreadCount, 1)
    }

    func testRetiredThreadCapacityCountsDistinctActiveOwners() throws {
        let retired = (0..<2_047).map { index in
            RetiredDeveloperToolThread(
                tool: .codex,
                externalSessionID: "retained-\(index)",
                retiredAt: date.addingTimeInterval(-1),
                lastAcceptedEventAt: date.addingTimeInterval(-1)
            )
        }
        var state = AppState(developerToolIntegration: DeveloperToolIntegrationProcessingState(
            retiredDeveloperToolThreads: retired
        ))
        XCTAssertNoThrow(try state.admitDeveloperToolOwner(tool: .opencode, externalSessionID: "owner", at: date))
        XCTAssertEqual(state.developerToolThreadCapacityUsed(at: date), 2_048)

        let before = state
        XCTAssertThrowsError(try state.admitDeveloperToolOwner(tool: .opencode, externalSessionID: "another", at: date)) { error in
            XCTAssertEqual(error as? DeveloperToolThreadAdmissionError, .capacityExceeded)
        }
        XCTAssertEqual(state, before)
    }

    func testRetirementConversionPreservesCapacityAtSaturation() throws {
        let reservations = (0..<2_048).map {
            DeveloperToolThreadIdentity(tool: .codex, externalSessionID: "reserved-\($0)")
        }
        var state = AppState(developerToolIntegration: DeveloperToolIntegrationProcessingState(
            reservedDeveloperToolThreads: reservations
        ))
        XCTAssertEqual(state.developerToolThreadCapacityUsed(at: date), 2_048)

        XCTAssertNoThrow(try state.retireDeveloperToolOwner(
            tool: .codex,
            externalSessionID: "reserved-0",
            retiredAt: date,
            lastAcceptedEventAt: date
        ))
        XCTAssertEqual(state.developerToolThreadCapacityUsed(at: date), 2_048)
        XCTAssertEqual(state.developerToolIntegration?.reservedDeveloperToolThreads.count, 2_047)
        XCTAssertEqual(state.developerToolIntegration?.retiredDeveloperToolThreads.count, 1)
    }

    func testProtectedRetiredIdentityCannotBeReused() throws {
        let retired = RetiredDeveloperToolThread(
            tool: .codex,
            externalSessionID: "protected",
            retiredAt: date,
            lastAcceptedEventAt: date
        )
        var state = AppState(developerToolIntegration: DeveloperToolIntegrationProcessingState(
            retiredDeveloperToolThreads: [retired]
        ))

        XCTAssertFalse(state.canAdmitDeveloperToolOwner(
            tool: .codex,
            externalSessionID: "protected",
            at: date.addingTimeInterval(1)
        ))
        XCTAssertThrowsError(try state.admitDeveloperToolOwner(
            tool: .codex,
            externalSessionID: "protected",
            at: date.addingTimeInterval(1)
        )) { error in
            XCTAssertEqual(error as? DeveloperToolThreadAdmissionError, .identityStillProtected)
        }
        XCTAssertEqual(state.developerToolIntegration?.retiredDeveloperToolThreads, [retired])
    }

    func testMultiOwnerRetirementIsAtomicAndLeavesUnrelatedReservationsUntouched() throws {
        let metadata = SessionAutomationMetadata(
            startedByRuleID: UUID(),
            startedByRuleName: "Developer Tool",
            startedBySource: .developerTool(tool: .codex, externalSessionID: "owner-a"),
            lastMatchingSignalAt: date,
            pauseDelay: 1,
            finishDelay: 2,
            minimumSavedDuration: 0,
            claims: [SessionAutomationClaim(
                tool: .opencode,
                externalSessionID: "owner-b",
                isActive: true,
                lastSignalAt: date
            )]
        )
        let session = ActiveSession(startedAt: date, automationMetadata: metadata)
        let unrelated = DeveloperToolThreadIdentity(tool: .codex, externalSessionID: "unrelated")
        var state = AppState(
            activeSessions: [session],
            developerToolIntegration: DeveloperToolIntegrationProcessingState(
                reservedDeveloperToolThreads: [
                    DeveloperToolThreadIdentity(tool: .codex, externalSessionID: "owner-a"),
                    DeveloperToolThreadIdentity(tool: .opencode, externalSessionID: "owner-b"),
                    unrelated
                ]
            )
        )

        _ = try state.removeActiveSession(id: session.id)
        XCTAssertNoThrow(try state.retireDeveloperToolOwnership(for: session, retiredAt: date))
        XCTAssertEqual(state.reservedDeveloperToolOwnershipIdentities, Set([unrelated]))
        XCTAssertEqual(
            Set(state.developerToolIntegration?.retiredDeveloperToolThreads.map(\.identity) ?? []),
            Set([
                DeveloperToolThreadIdentity(tool: .codex, externalSessionID: "owner-a"),
                DeveloperToolThreadIdentity(tool: .opencode, externalSessionID: "owner-b")
            ])
        )
    }

    func testManualAndApplicationSessionsDoNotConsumeDeveloperToolCapacity() throws {
        let applicationMetadata = SessionAutomationMetadata(
            startedByRuleID: UUID(),
            startedByRuleName: "Application",
            startedBySource: .application(bundleIdentifier: "com.example.app"),
            lastMatchingSignalAt: date,
            pauseDelay: 1,
            finishDelay: 2,
            minimumSavedDuration: 0
        )
        let state = AppState(activeSessions: [
            ActiveSession(startedAt: date),
            ActiveSession(startedAt: date.addingTimeInterval(1), automationMetadata: applicationMetadata)
        ])
        XCTAssertEqual(state.activeDeveloperToolOwnedThreadCount, 0)
        XCTAssertEqual(state.developerToolThreadCapacityUsed(at: date), 0)
    }

    func testRetiredAndReservedProcessingStateRoundTripsThroughAppState() throws {
        let retired = RetiredDeveloperToolThread(
            tool: .codex,
            externalSessionID: "round-trip",
            retiredAt: date,
            lastAcceptedEventAt: date
        )
        let reserved = DeveloperToolThreadIdentity(tool: .opencode, externalSessionID: "reserved")
        let metadata = SessionAutomationMetadata(
            startedByRuleID: UUID(),
            startedByRuleName: "Reserved owner",
            startedBySource: .developerTool(tool: reserved.tool, externalSessionID: reserved.externalSessionID),
            lastMatchingSignalAt: date,
            pauseDelay: 1,
            finishDelay: 2,
            minimumSavedDuration: 0
        )
        let state = AppState(
            activeSessions: [ActiveSession(startedAt: date, automationMetadata: metadata)],
            developerToolIntegration: DeveloperToolIntegrationProcessingState(
                retiredDeveloperToolThreads: [retired],
                reservedDeveloperToolThreads: [reserved]
            )
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(AppState.self, from: try jsonData(state))
        XCTAssertEqual(decoded.developerToolIntegration?.retiredDeveloperToolThreads, [retired])
        XCTAssertEqual(decoded.developerToolIntegration?.reservedDeveloperToolThreads, [reserved])
    }

    func testPortableBackupOmitsRetiredAndReservedProcessingMetadata() throws {
        let state = AppState(developerToolIntegration: DeveloperToolIntegrationProcessingState(
            retiredDeveloperToolThreads: [RetiredDeveloperToolThread(
                tool: .codex,
                externalSessionID: "portable-reset",
                retiredAt: date,
                lastAcceptedEventAt: date
            )],
            reservedDeveloperToolThreads: [DeveloperToolThreadIdentity(
                tool: .opencode,
                externalSessionID: "portable-reservation"
            )]
        ))

        let data = try CodePulseBackupCodec.encode(state: state, exportedAt: date)
        let decoded = try CodePulseBackupCodec.decode(data)
        XCTAssertNil(decoded.state.developerToolIntegration)
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains("portable-reset") == true)
        XCTAssertFalse(String(data: data, encoding: .utf8)?.contains("portable-reservation") == true)
    }

    private func automationMetadata(tool: DeveloperTool, externalSessionID: String) -> SessionAutomationMetadata {
        SessionAutomationMetadata(
            startedByRuleID: UUID(),
            startedByRuleName: "Developer Tool",
            startedBySource: .developerTool(tool: tool, externalSessionID: externalSessionID),
            lastMatchingSignalAt: date,
            pauseDelay: 1,
            finishDelay: 2,
            minimumSavedDuration: 0,
            claims: [SessionAutomationClaim(
                tool: tool,
                externalSessionID: externalSessionID,
                isActive: true,
                lastSignalAt: date
            )]
        )
    }

    private func schemaTwoData(active: ActiveSession?) throws -> Data {
        var object = try jsonObject(AppState(activeSession: active))
        object["schemaVersion"] = 2
        object.removeValue(forKey: "activeSessions")
        if let active {
            object["activeSession"] = try jsonObject(active)
        }
        return try jsonData(object)
    }

    private func schemaOneData(project: ProjectRecord, active: ActiveSession?) throws -> Data {
        var object = try jsonObject(AppState(projects: [project], activeSession: active))
        object.removeValue(forKey: "schemaVersion")
        object.removeValue(forKey: "workspaces")
        object.removeValue(forKey: "activeSessions")
        var projects = try XCTUnwrap(object["projects"] as? [[String: Any]])
        for index in projects.indices {
            projects[index].removeValue(forKey: "workspaceID")
        }
        object["projects"] = projects
        if let settings = object["settings"] as? [String: Any] {
            var settings = settings
            settings.removeValue(forKey: "selectedWorkspaceID")
            object["settings"] = settings
        }
        if let active {
            object["activeSession"] = try jsonObject(active)
        }
        return try jsonData(object)
    }

    private func decodeState(_ data: Data) throws -> AppState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppState.self, from: data)
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: jsonData(value)) as? [String: Any])
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func jsonData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private func jsonData(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}
