import CodePulseIntegration
import XCTest
@testable import CodePulse

@MainActor
final class Phase3ThreadNativeAutomationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_900_100_000)

    func testSameProjectThreadsCreateIndependentOwnersAndRouteExactly() throws {
        let fixture = try makeFixture()
        try fixture.inbox.write(event("a", .sessionStarted, at: start, path: fixture.folder.path))
        fixture.clock.now = start.addingTimeInterval(5)
        fixture.store.refresh()
        let aID = try XCTUnwrap(owner("a", in: fixture.store.state)?.id)

        fixture.clock.now = start.addingTimeInterval(10)
        try fixture.inbox.write(event("b", .activity, at: fixture.clock.now, path: fixture.folder.path))
        fixture.store.refresh()

        XCTAssertEqual(fixture.store.state.activeSessions.count, 2)
        XCTAssertNotEqual(aID, owner("b", in: fixture.store.state)?.id)
        XCTAssertEqual(owner("a", in: fixture.store.state)?.developerToolContexts.first?.eventCount, 1)
        XCTAssertEqual(owner("b", in: fixture.store.state)?.developerToolContexts.first?.eventCount, 1)
        XCTAssertEqual(fixture.store.state.developerToolIntegration?.reservedDeveloperToolThreads.count, 2)
    }

    func testProjectMismatchAndStaleEndLeaveOwnerUnchanged() throws {
        let fixture = try makeFixture(includeSecondProject: true)
        try fixture.inbox.write(event("a", .activity, at: start, path: fixture.folder.path))
        fixture.clock.now = start.addingTimeInterval(5)
        fixture.store.refresh()
        let original = try XCTUnwrap(owner("a", in: fixture.store.state))

        fixture.clock.now = start.addingTimeInterval(10)
        try fixture.inbox.write(event("a", .activity, at: fixture.clock.now, path: fixture.folder.path))
        fixture.store.refresh()
        let newer = try XCTUnwrap(owner("a", in: fixture.store.state))

        try fixture.inbox.write(event("a", .sessionEnded, at: start.addingTimeInterval(1), path: fixture.folder.path))
        fixture.clock.now = fixture.clock.now.addingTimeInterval(5)
        fixture.store.refresh()
        XCTAssertEqual(owner("a", in: fixture.store.state)?.automationMetadata?.claims.first?.isActive, true)
        XCTAssertEqual(owner("a", in: fixture.store.state)?.automationMetadata?.claims.first?.lastSignalAt, newer.automationMetadata?.claims.first?.lastSignalAt)

        let ownerBefore = try XCTUnwrap(owner("a", in: fixture.store.state))
        let allActiveSessionsBefore = fixture.store.state.activeSessions
        let reservationStateBefore = fixture.store.state.developerToolIntegration?.reservedDeveloperToolThreads
        let ownershipMapBefore = fixture.store.state.activeSessions.map { ($0.id, $0.developerToolOwnershipIdentities) }
        let rejected = event("a", .activity, at: fixture.clock.now, path: try XCTUnwrap(fixture.secondFolder).path)
        try fixture.inbox.write(rejected)
        fixture.clock.now = fixture.clock.now.addingTimeInterval(5)
        fixture.store.refresh()
        XCTAssertEqual(owner("a", in: fixture.store.state), ownerBefore)
        XCTAssertEqual(fixture.store.state.activeSessions, allActiveSessionsBefore)
        XCTAssertEqual(fixture.store.state.activeSessions.count, allActiveSessionsBefore.count)
        XCTAssertEqual(fixture.store.state.developerToolIntegration?.reservedDeveloperToolThreads, reservationStateBefore)
        XCTAssertEqual(fixture.store.state.activeSessions.map { ($0.id, $0.developerToolOwnershipIdentities) }.map(OwnershipSnapshot.init), ownershipMapBefore.map(OwnershipSnapshot.init))
        XCTAssertNil(fixture.store.state.activeSessions.first { $0.projectID == fixture.secondProject?.id && $0.developerToolOwnershipIdentities.contains(identity(.codex, "a")) })
        XCTAssertTrue(isProcessed(rejected.id, in: fixture.store.state))
        XCTAssertTrue(fixture.inbox.pendingEventURLs().isEmpty)
        XCTAssertNotEqual(original.developerToolContexts.first?.eventCount, newer.developerToolContexts.first?.eventCount)
    }

    func testSameExternalIDDifferentToolsCreateDistinctOwners() throws {
        let fixture = try makeFixture()
        try send(event("shared", .activity, at: start, path: fixture.folder.path), through: fixture)
        try send(event("shared", .activity, tool: .opencode, at: start.addingTimeInterval(1), path: fixture.folder.path), through: fixture)
        let codex = try XCTUnwrap(owner("shared", tool: .codex, in: fixture.store.state))
        let openCode = try XCTUnwrap(owner("shared", tool: .opencode, in: fixture.store.state))
        XCTAssertNotEqual(codex.id, openCode.id)
        XCTAssertEqual(codex.developerToolOwnershipIdentities, [identity(.codex, "shared")])
        XCTAssertEqual(openCode.developerToolOwnershipIdentities, [identity(.opencode, "shared")])
    }

    func testDifferentProjectsAndSelectedWorkspaceRouteIndependently() throws {
        let fixture = try makeFixture(includeSecondProject: true, separateWorkspaces: true)
        try send(event("a", .activity, at: start, path: fixture.folder.path), through: fixture)
        let a = try XCTUnwrap(owner("a", in: fixture.store.state))
        let aBefore = a
        try send(event("b", .activity, at: start.addingTimeInterval(1), path: try XCTUnwrap(fixture.secondFolder).path), through: fixture)
        let b = try XCTUnwrap(owner("b", in: fixture.store.state))
        XCTAssertEqual(a.projectID, fixture.project.id)
        XCTAssertEqual(b.projectID, fixture.secondProject?.id)
        XCTAssertEqual(owner("a", in: fixture.store.state), aBefore)
        let bBefore = b
        try send(event("a", .activity, at: start.addingTimeInterval(2), path: fixture.folder.path), through: fixture)
        XCTAssertEqual(owner("b", in: fixture.store.state), bBefore)
        XCTAssertEqual(fixture.store.state.settings.selectedWorkspaceID, fixture.project.workspaceID)
    }

    func testExactlyOneManualSessionGetsContextWithoutOwnership() throws {
        let fixture = try makeFixture(automationEnabled: false)
        let manualID = try XCTUnwrap(fixture.store.createManualSession(projectID: fixture.project.id, goal: "Manual", at: start))
        let input = event("manual", .activity, at: start.addingTimeInterval(1), path: fixture.folder.path)
        try send(input, through: fixture)
        let manual = try XCTUnwrap(fixture.store.state.activeSession(id: manualID))
        XCTAssertEqual(manual.developerToolContexts.first?.externalSessionID, "manual")
        XCTAssertNil(manual.automationMetadata)
        XCTAssertTrue(fixture.store.state.reservedDeveloperToolOwnershipIdentities.isEmpty)
        XCTAssertTrue(isProcessed(input.id, in: fixture.store.state))
    }

    func testUnownedEndContextEnrichesOnlyEligibleManualSessionWithoutAutomationAuthority() throws {
        let fixture = try makeFixture(automationEnabled: false)
        let manualID = try XCTUnwrap(fixture.store.createManualSession(
            projectID: fixture.project.id,
            goal: "Manual",
            at: start
        ))
        let input = event(
            "manual-end",
            .sessionEnded,
            at: start.addingTimeInterval(1),
            path: fixture.folder.path
        )

        try send(input, through: fixture)

        let manual = try XCTUnwrap(fixture.store.state.activeSession(id: manualID))
        XCTAssertEqual(manual.developerToolContexts.first?.externalSessionID, "manual-end")
        XCTAssertEqual(manual.developerToolContexts.first?.eventCount, 1)
        XCTAssertNil(manual.automationMetadata)
        XCTAssertTrue(manual.developerToolOwnershipIdentities.isEmpty)
        XCTAssertEqual(manual.phase, .running)
        XCTAssertNil(manual.endedAt)
        XCTAssertTrue(
            fixture.store.state.developerToolIntegration?.reservedDeveloperToolThreads.isEmpty == true
        )
        XCTAssertTrue(
            fixture.store.state.developerToolIntegration?.retiredDeveloperToolThreads.isEmpty == true
        )
        XCTAssertTrue(isProcessed(input.id, in: fixture.store.state))
        XCTAssertTrue(fixture.inbox.pendingEventURLs().isEmpty)
    }

    func testTwoEligibleManualSessionsAreUnchangedAndEventAcknowledged() throws {
        let fixture = try makeFixture(automationEnabled: false)
        _ = fixture.store.createManualSession(projectID: fixture.project.id, goal: "A", at: start)
        _ = fixture.store.createManualSession(projectID: fixture.project.id, goal: "B", at: start)
        let before = fixture.store.state.activeSessions
        let input = event("ambiguous", .activity, at: start.addingTimeInterval(1), path: fixture.folder.path)
        try send(input, through: fixture)
        XCTAssertEqual(fixture.store.state.activeSessions, before)
        XCTAssertTrue(isProcessed(input.id, in: fixture.store.state))
        XCTAssertTrue(fixture.inbox.pendingEventURLs().isEmpty)
    }

    func testEndAndPausedResumeTargetOnlyExactOwner() throws {
        let fixture = try makeFixture(pauseDelay: 20, finishDelay: 60)
        try send(event("a", .activity, at: start, path: fixture.folder.path), through: fixture)
        try send(event("b", .activity, at: start, path: fixture.folder.path), through: fixture)
        let bBeforeEnd = try XCTUnwrap(owner("b", in: fixture.store.state))
        try send(event("a", .sessionEnded, at: start.addingTimeInterval(1), path: fixture.folder.path), through: fixture)
        XCTAssertFalse(try XCTUnwrap(owner("a", in: fixture.store.state)?.automationMetadata?.claims.first?.isActive))
        XCTAssertEqual(owner("b", in: fixture.store.state), bBeforeEnd)

        try send(event("b", .sessionEnded, at: start.addingTimeInterval(2), path: fixture.folder.path), through: fixture)
        fixture.clock.now = start.addingTimeInterval(22)
        fixture.store.refresh()
        XCTAssertEqual(owner("b", in: fixture.store.state)?.phase, .paused)
        let aBeforeResume = try XCTUnwrap(owner("a", in: fixture.store.state))
        try send(event("b", .activity, at: start.addingTimeInterval(25), path: fixture.folder.path), through: fixture)
        XCTAssertEqual(owner("b", in: fixture.store.state)?.phase, .running)
        XCTAssertTrue(try XCTUnwrap(owner("b", in: fixture.store.state)?.automationMetadata?.claims.first?.isActive))
        XCTAssertEqual(owner("a", in: fixture.store.state), aBeforeResume)
    }

    func testOutOfOrderContextAndLifecycleNeverRewindNewestMetadata() throws {
        let fixture = try makeFixture(pauseDelay: 5, finishDelay: 10)
        try send(event("a", .sessionStarted, at: start, path: fixture.folder.path), through: fixture)
        let t10 = start.addingTimeInterval(10)
        let newest = event("a", .activity, at: t10, path: fixture.folder.path, model: "new", profile: "new-profile")
        try send(newest, through: fixture)
        let before = try XCTUnwrap(owner("a", in: fixture.store.state))
        let stale = event("a", .sessionEnded, at: start.addingTimeInterval(5), path: fixture.folder.path, model: "old", profile: "old-profile")
        try send(stale, through: fixture)
        let after = try XCTUnwrap(owner("a", in: fixture.store.state))
        let context = try XCTUnwrap(after.developerToolContexts.first)
        XCTAssertEqual(context.firstActivityAt, start)
        XCTAssertEqual(context.lastActivityAt, t10)
        XCTAssertEqual(context.eventCount, 3)
        XCTAssertEqual(context.model, "new")
        XCTAssertEqual(context.profile, "new-profile")
        XCTAssertNil(context.endedAt)
        XCTAssertEqual(after.automationMetadata?.claims.first?.lastSignalAt, t10)
        XCTAssertEqual(after.automationMetadata?.pauseEligibleAt, before.automationMetadata?.pauseEligibleAt)
        XCTAssertEqual(after.automationMetadata?.finishEligibleAt, before.automationMetadata?.finishEligibleAt)
    }

    func testNewerActivityAfterEndReactivatesOnlyOriginalOwner() throws {
        let fixture = try makeFixture(pauseDelay: 2, finishDelay: 30)
        try send(event("a", .activity, at: start, path: fixture.folder.path), through: fixture)
        try send(event("b", .activity, at: start, path: fixture.folder.path), through: fixture)
        try send(event("a", .sessionEnded, at: start.addingTimeInterval(10), path: fixture.folder.path), through: fixture)
        fixture.clock.now = start.addingTimeInterval(12)
        fixture.store.refresh()
        XCTAssertEqual(owner("a", in: fixture.store.state)?.phase, .paused)
        let bBefore = try XCTUnwrap(owner("b", in: fixture.store.state))
        try send(event("a", .activity, at: start.addingTimeInterval(20), path: fixture.folder.path), through: fixture)
        let a = try XCTUnwrap(owner("a", in: fixture.store.state))
        XCTAssertEqual(a.phase, .running)
        XCTAssertTrue(try XCTUnwrap(a.automationMetadata?.claims.first?.isActive))
        XCTAssertNil(a.developerToolContexts.first?.endedAt)
        XCTAssertEqual(a.automationMetadata?.pauseEligibleAt, start.addingTimeInterval(22))
        XCTAssertEqual(owner("b", in: fixture.store.state), bBefore)
    }

    func testSixteenSessionBoundRejectsRealEventAndAcknowledgesIt() throws {
        let fixture = try makeFixture()
        for index in 0..<ConcurrentSessionLimits.maximumActiveSessions {
            XCTAssertNotNil(fixture.store.createManualSession(projectID: fixture.project.id, goal: "Manual \(index)", at: start))
        }
        let before = fixture.store.state.activeSessions
        let reservationsBefore = fixture.store.state.reservedDeveloperToolOwnershipIdentities
        let input = event("seventeenth", .activity, at: start.addingTimeInterval(1), path: fixture.folder.path)
        try send(input, through: fixture)
        XCTAssertEqual(fixture.store.state.activeSessions, before)
        XCTAssertEqual(fixture.store.state.reservedDeveloperToolOwnershipIdentities, reservationsBefore)
        XCTAssertTrue(isProcessed(input.id, in: fixture.store.state))
        XCTAssertTrue(fixture.inbox.pendingEventURLs().isEmpty)
        XCTAssertNoThrow(try AppStateIntegrityValidator.validate(fixture.store.state))
    }

    func testThreadCapacityFullRejectsAndOneSlotAdmitsExactlyOnce() throws {
        let full = try makeFixture()
        full.persistence.state.developerToolIntegration = processingWithRetired(count: 2_048, at: start)
        let fullStore = relaunch(full)
        let rejected = event("full", .activity, at: start.addingTimeInterval(1), path: full.folder.path)
        try full.inbox.write(rejected)
        full.clock.now = start.addingTimeInterval(5)
        fullStore.refresh()
        XCTAssertTrue(fullStore.state.activeSessions.isEmpty)
        XCTAssertEqual(fullStore.state.developerToolThreadCapacityUsed(at: full.clock.now), 2_048)
        XCTAssertEqual(fullStore.state.developerToolIntegration?.retiredDeveloperToolThreads.count, 2_048)
        XCTAssertTrue(isProcessed(rejected.id, in: fullStore.state))

        let slot = try makeFixture()
        slot.persistence.state.developerToolIntegration = processingWithRetired(count: 2_047, at: start)
        let slotStore = relaunch(slot)
        try slot.inbox.write(event("last-slot", .activity, at: start.addingTimeInterval(1), path: slot.folder.path))
        slot.clock.now = start.addingTimeInterval(5)
        slotStore.refresh()
        XCTAssertNotNil(owner("last-slot", in: slotStore.state))
        XCTAssertEqual(slotStore.state.developerToolThreadCapacityUsed(at: slot.clock.now), 2_048)
        let ownerBefore = slotStore.state.activeSessions
        let overflow = event("overflow", .activity, at: start.addingTimeInterval(2), path: slot.folder.path)
        try slot.inbox.write(overflow)
        slot.clock.now = start.addingTimeInterval(10)
        slotStore.refresh()
        XCTAssertEqual(slotStore.state.activeSessions, ownerBefore)
        XCTAssertEqual(slotStore.state.developerToolThreadCapacityUsed(at: slot.clock.now), 2_048)
        XCTAssertTrue(isProcessed(overflow.id, in: slotStore.state))
    }

    func testRetiredProtectionSurvivesRelaunchAndExpiresAtExactBoundary() throws {
        let fixture = try makeFixture()
        let retired = RetiredDeveloperToolThread(tool: .codex, externalSessionID: "retired", retiredAt: start, lastAcceptedEventAt: start)
        fixture.persistence.state.developerToolIntegration = DeveloperToolIntegrationProcessingState(retiredDeveloperToolThreads: [retired])
        let protectedStore = relaunch(fixture)
        let blocked = event("retired", .activity, at: start.addingTimeInterval(1), path: fixture.folder.path)
        try fixture.inbox.write(blocked)
        fixture.clock.now = start.addingTimeInterval(5)
        protectedStore.refresh()
        XCTAssertNil(owner("retired", in: protectedStore.state))
        XCTAssertTrue(isProcessed(blocked.id, in: protectedStore.state))

        fixture.clock.now = start.addingTimeInterval(ConcurrentSessionLimits.retiredDeveloperToolRetention)
        let expiredStore = SessionStore(persistence: fixture.persistence, clock: fixture.clock, gitService: Phase3NoOpGit(), developerToolEventConsumer: DeveloperToolEventConsumer(inbox: fixture.inbox), automaticallyRefresh: false)
        let admitted = event("retired", .activity, at: fixture.clock.now, path: fixture.folder.path)
        try fixture.inbox.write(admitted)
        fixture.clock.now = fixture.clock.now.addingTimeInterval(5)
        expiredStore.refresh()
        XCTAssertNotNil(owner("retired", in: expiredStore.state))
        XCTAssertFalse(expiredStore.state.developerToolIntegration?.retiredDeveloperToolThreads.contains { $0.identity == identity(.codex, "retired") } == true)
    }

    func testMultipleOwnersAndLegacyMultiIdentityOwnerSurviveRelaunch() throws {
        let fixture = try makeFixture()
        try send(event("a", .activity, at: start, path: fixture.folder.path), through: fixture)
        try send(event("b", .activity, tool: .opencode, at: start, path: fixture.folder.path), through: fixture)
        let aID = try XCTUnwrap(owner("a", in: fixture.store.state)?.id)
        let bID = try XCTUnwrap(owner("b", tool: .opencode, in: fixture.store.state)?.id)
        let restored = relaunch(fixture)
        let bBefore = try XCTUnwrap(restored.state.activeSession(id: bID))
        try fixture.inbox.write(event("a", .activity, at: start.addingTimeInterval(20), path: fixture.folder.path))
        fixture.clock.now = start.addingTimeInterval(25)
        restored.refresh()
        XCTAssertEqual(owner("a", in: restored.state)?.id, aID)
        XCTAssertEqual(restored.state.activeSession(id: bID), bBefore)

        var legacyState = restored.state
        guard let aIndex = legacyState.activeSessionIndex(id: aID), var metadata = legacyState.activeSessions[aIndex].automationMetadata else { return XCTFail("missing owner") }
        let legacySource = SessionAutomationClaimSource.developerTool(tool: .opencode, externalSessionID: "legacy-b")
        metadata.claims.append(SessionAutomationClaim(source: legacySource, isActive: true, lastSignalAt: start))
        legacyState.activeSessions[aIndex].automationMetadata = metadata
        legacyState.activeSessions.removeAll { $0.id == bID }
        legacyState.developerToolIntegration?.reservedDeveloperToolThreads.removeAll { $0 == identity(.opencode, "b") }
        legacyState.developerToolIntegration?.reservedDeveloperToolThreads.append(identity(.opencode, "legacy-b"))
        fixture.persistence.state = legacyState
        let legacyStore = relaunch(fixture)
        try fixture.inbox.write(event("legacy-b", .activity, tool: .opencode, at: start.addingTimeInterval(30), path: fixture.folder.path))
        fixture.clock.now = start.addingTimeInterval(35)
        legacyStore.refresh()
        XCTAssertEqual(owner("legacy-b", tool: .opencode, in: legacyStore.state)?.id, aID)
        XCTAssertEqual(legacyStore.state.activeSessions.count, 1)
    }

    func testDeletingOneToolRuleRelinquishesOnlyItsOwner() throws {
        let fixture = try makeFixture()
        try send(event("a", .activity, at: start, path: fixture.folder.path), through: fixture)
        try send(event("b", .activity, tool: .opencode, at: start, path: fixture.folder.path), through: fixture)
        let bBefore = try XCTUnwrap(owner("b", tool: .opencode, in: fixture.store.state))
        let codexRule = try XCTUnwrap(fixture.store.state.automationRules.first { $0.trigger.developerTool == .codex })
        fixture.store.deleteAutomationRule(id: codexRule.id)
        XCTAssertFalse(try XCTUnwrap(owner("a", in: fixture.store.state)?.automationMetadata?.controlEnabled))
        XCTAssertNotNil(owner("a", in: fixture.store.state))
        XCTAssertEqual(owner("b", tool: .opencode, in: fixture.store.state), bBefore)
    }

    func testApplicationOwnerCoexistsRemainsSingularAndSignalsAreIsolated() throws {
        let fixture = try makeFixture()
        try send(event("a", .activity, at: start, path: fixture.folder.path), through: fixture)
        let developerBefore = try XCTUnwrap(owner("a", in: fixture.store.state))
        let appPreset = SessionPreset(name: "App", projectID: fixture.project.id)
        let app = ApplicationIdentity(bundleIdentifier: "com.example.editor", displayName: "Editor")
        let appRule = SessionAutomationRule(name: "Editor", trigger: .applications(ApplicationAutomationTrigger(applications: [app])), presetID: appPreset.id, pauseDelay: 10, finishDelay: 20, minimumSavedDuration: 0)
        var state = fixture.store.state
        state.sessionPresets.append(appPreset)
        state.automationRules.append(appRule)
        fixture.persistence.state = state
        let store = relaunch(fixture)
        store.handleFrontmostApplication(app)
        let appOwner = try XCTUnwrap(store.state.activeSessions.first { if case .application = $0.automationMetadata?.startedBySource { return true }; return false })
        XCTAssertEqual(store.state.activeSessions.count, 2)
        XCTAssertEqual(store.state.activeSession(id: developerBefore.id), developerBefore)
        store.handleFrontmostApplication(nil)
        XCTAssertEqual(store.state.activeSession(id: developerBefore.id), developerBefore)
        store.handleFrontmostApplication(app)
        XCTAssertEqual(store.state.activeSessions.filter { if case .application = $0.automationMetadata?.startedBySource { return true }; return false }.count, 1)
        XCTAssertEqual(store.state.activeSessions.first { $0.id == appOwner.id }?.id, appOwner.id)
    }

    func testGitDiscoveryStartsOnlyAfterSuccessfulCriticalAdmission() async throws {
        let persistence = Phase3Persistence(AppState())
        let git = Phase3RecordingGit(persistence: persistence)
        let fixture = try makeFixture(gitService: git)
        git.persistence = fixture.persistence
        fixture.persistence.failCriticalSaves = true
        let input = event("git", .activity, at: start, path: fixture.folder.path)
        try send(input, through: fixture)
        XCTAssertEqual(git.captureStartCount, 0)
        XCTAssertTrue(fixture.store.state.activeSessions.isEmpty)
        XCTAssertEqual(fixture.inbox.pendingEventURLs().count, 1)
        fixture.persistence.failCriticalSaves = false
        fixture.clock.now = fixture.clock.now.addingTimeInterval(5)
        fixture.store.refresh()
        try await waitUntil("Git discovery did not start after successful critical admission") {
            git.captureStartCount == 1
        }
        XCTAssertEqual(git.captureStartCount, 1)
        XCTAssertEqual(git.criticalSuccessCountAtCapture, [1])
        XCTAssertEqual(git.pathsAtCapture, [fixture.folder.path])
    }

    func testAllRetirementPathsPreventThreadResurrection() async throws {
        let saved = try makeFixture(pauseDelay: 1, finishDelay: 2, minimumSavedDuration: 0)
        let savedStart = event("saved", .activity, at: start, path: saved.folder.path)
        try send(savedStart, through: saved)
        try await settleGitCapture(saved.store)
        let savedOwnerID = try XCTUnwrap(owner("saved", in: saved.store.state)?.id)
        let savedUnrelatedID = try XCTUnwrap(saved.store.createManualSession(projectID: saved.project.id, goal: "Unrelated", at: start))
        let savedUnrelatedBefore = try XCTUnwrap(saved.store.state.activeSession(id: savedUnrelatedID))
        try send(event("saved", .sessionEnded, at: start.addingTimeInterval(1), path: saved.folder.path), through: saved)
        try await waitUntil("Automatic save did not remove the owner and publish its completed Session") {
            saved.store.state.activeSession(id: savedOwnerID) == nil &&
            saved.store.state.completedSessions.contains { $0.id == savedOwnerID }
        }
        XCTAssertNil(saved.store.state.activeSession(id: savedOwnerID))
        XCTAssertEqual(saved.store.state.completedSessions.filter { $0.id == savedOwnerID }.count, 1)
        XCTAssertEqual(saved.store.state.activeSession(id: savedUnrelatedID), savedUnrelatedBefore)
        try send(savedStart, through: saved)
        XCTAssertNil(owner("saved", in: saved.store.state))
        let savedLate = event("saved", .activity, at: saved.clock.now, path: saved.folder.path)
        try send(savedLate, through: saved)
        XCTAssertNil(owner("saved", in: saved.store.state))
        XCTAssertEqual(saved.store.state.completedSessions.filter { $0.id == savedOwnerID }.count, 1)
        XCTAssertEqual(saved.store.state.activeSession(id: savedUnrelatedID), savedUnrelatedBefore)

        let discarded = try makeFixture(pauseDelay: 1, finishDelay: 2, minimumSavedDuration: 100)
        try send(event("short", .activity, at: start, path: discarded.folder.path), through: discarded)
        try await settleGitCapture(discarded.store)
        let discardedOwnerID = try XCTUnwrap(owner("short", in: discarded.store.state)?.id)
        try send(event("short", .sessionEnded, at: start.addingTimeInterval(1), path: discarded.folder.path), through: discarded)
        try await waitUntil("Minimum-duration discard did not remove the owner without publishing history") {
            discarded.store.state.activeSession(id: discardedOwnerID) == nil &&
            !discarded.store.state.completedSessions.contains { $0.id == discardedOwnerID }
        }
        XCTAssertNil(owner("short", in: discarded.store.state))
        XCTAssertTrue(discarded.store.state.completedSessions.isEmpty)
        try send(event("short", .activity, at: discarded.clock.now, path: discarded.folder.path), through: discarded)
        XCTAssertNil(owner("short", in: discarded.store.state))
        XCTAssertTrue(discarded.store.state.completedSessions.isEmpty)

        let manual = try makeFixture()
        try send(event("manual-discard", .activity, at: start, path: manual.folder.path), through: manual)
        let manualOwnerID = try XCTUnwrap(owner("manual-discard", in: manual.store.state)?.id)
        XCTAssertTrue(manual.store.finish(sessionID: manualOwnerID, at: manual.clock.now))
        XCTAssertTrue(manual.store.discardSession(sessionID: manualOwnerID))
        XCTAssertNil(owner("manual-discard", in: manual.store.state))
        try send(event("manual-discard", .activity, at: manual.clock.now, path: manual.folder.path), through: manual)
        XCTAssertNil(owner("manual-discard", in: manual.store.state))
        XCTAssertTrue(manual.store.state.completedSessions.isEmpty)
    }

    func testEventMutationAndAcknowledgementFailAtomically() throws {
        let fixture = try makeFixture()
        fixture.persistence.failCriticalSaves = true
        let input = event("retry", .activity, at: start, path: fixture.folder.path)
        try fixture.inbox.write(input)
        fixture.clock.now = start.addingTimeInterval(5)
        fixture.store.refresh()
        XCTAssertTrue(fixture.store.state.activeSessions.isEmpty)
        XCTAssertFalse(fixture.store.state.developerToolIntegration?.processedEvents.contains(where: { $0.id == input.id }) == true)
        XCTAssertEqual(fixture.inbox.pendingEventURLs().count, 1)

        fixture.persistence.failCriticalSaves = false
        fixture.clock.now = start.addingTimeInterval(10)
        fixture.store.refresh()
        XCTAssertEqual(fixture.store.state.activeSessions.count, 1)
        XCTAssertTrue(fixture.store.state.developerToolIntegration?.processedEvents.contains(where: { $0.id == input.id }) == true)
    }

    func testIntegrityRejectsTwoApplicationOwnedSessions() throws {
        let fixture = try makeFixture()
        let source = SessionAutomationClaimSource.application(bundleIdentifier: "com.example.editor")
        let metadata = SessionAutomationMetadata(
            startedByRuleID: UUID(), startedByRuleName: "App", startedBySource: source,
            lastMatchingSignalAt: start, pauseDelay: 1, finishDelay: 2,
            minimumSavedDuration: 0,
            claims: [SessionAutomationClaim(source: source, isActive: true, lastSignalAt: start)]
        )
        var state = fixture.store.state
        state.activeSessions = [
            ActiveSession(projectID: fixture.project.id, projectName: fixture.project.name, startedAt: start, automationMetadata: metadata),
            ActiveSession(projectID: fixture.project.id, projectName: fixture.project.name, startedAt: start, automationMetadata: metadata)
        ]
        XCTAssertThrowsError(try AppStateIntegrityValidator.validate(state)) { error in
            XCTAssertEqual(error as? AppStateIntegrityError, .multipleApplicationAutomationOwners)
        }
    }

    private func identity(_ tool: DeveloperTool, _ externalID: String) -> DeveloperToolThreadIdentity {
        DeveloperToolThreadIdentity(tool: tool, externalSessionID: externalID)
    }

    private func owner(_ externalID: String, tool: DeveloperTool = .codex, in state: AppState) -> ActiveSession? {
        let identity = identity(tool, externalID)
        return state.activeSessions.first { $0.developerToolOwnershipIdentities.contains(identity) }
    }

    private func event(
        _ id: String,
        _ type: DeveloperToolEventType,
        tool: DeveloperTool = .codex,
        at date: Date,
        path: String,
        model: String? = nil,
        profile: String? = nil
    ) -> DeveloperToolEvent {
        DeveloperToolEvent(tool: tool, externalSessionID: id, eventType: type, timestamp: date, workingDirectory: path, model: model, profile: profile)
    }

    private func send(_ input: DeveloperToolEvent, through fixture: Fixture) throws {
        try fixture.inbox.write(input)
        fixture.clock.now = max(fixture.clock.now.addingTimeInterval(5), input.timestamp)
        fixture.store.refresh()
    }

    private func isProcessed(_ id: UUID, in state: AppState) -> Bool {
        state.developerToolIntegration?.processedEvents.contains { $0.id == id } == true
    }

    private func settleGitCapture(_ store: SessionStore) async throws {
        try await waitUntil("Timed out waiting for Git capture to settle") {
            !store.gitCaptureInProgress
        }
    }

    private func waitUntil(
        _ failureMessage: String,
        predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail(failureMessage)
    }

    private func relaunch(_ fixture: Fixture) -> SessionStore {
        SessionStore(
            persistence: fixture.persistence,
            clock: fixture.clock,
            gitService: fixture.gitService,
            developerToolEventConsumer: DeveloperToolEventConsumer(inbox: fixture.inbox),
            automaticallyRefresh: false
        )
    }

    private func processingWithRetired(count: Int, at date: Date) -> DeveloperToolIntegrationProcessingState {
        DeveloperToolIntegrationProcessingState(retiredDeveloperToolThreads: (0..<count).map { index in
            RetiredDeveloperToolThread(tool: .codex, externalSessionID: "retired-\(index)", retiredAt: date, lastAcceptedEventAt: date)
        })
    }

    private func makeFixture(
        includeSecondProject: Bool = false,
        separateWorkspaces: Bool = false,
        automationEnabled: Bool = true,
        pauseDelay: TimeInterval = 60,
        finishDelay: TimeInterval = 300,
        minimumSavedDuration: TimeInterval = 60,
        gitService: GitServicing = Phase3NoOpGit()
    ) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodePulsePhase3-\(UUID())")
        let folder = root.appendingPathComponent("one", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let secondFolder = includeSecondProject ? root.appendingPathComponent("two", isDirectory: true) : nil
        if let secondFolder { try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true) }
        let firstWorkspace = WorkspaceRecord(name: "First", createdAt: start)
        let secondWorkspace = WorkspaceRecord(name: "Second", createdAt: start)
        let project = ProjectRecord(workspaceID: firstWorkspace.id, name: "One", folderPath: folder.path, createdAt: start)
        var projects = [project]
        let secondProject = secondFolder.map { ProjectRecord(workspaceID: separateWorkspaces ? secondWorkspace.id : firstWorkspace.id, name: "Two", folderPath: $0.path, createdAt: start) }
        if let secondProject { projects.append(secondProject) }
        let preset = SessionPreset(name: "Thread", projectID: nil)
        let rules = DeveloperTool.allCases.map { tool in
            SessionAutomationRule(name: tool.title, trigger: .developerTool(tool), presetID: preset.id, pauseDelay: pauseDelay, finishDelay: finishDelay, minimumSavedDuration: minimumSavedDuration)
        }
        let state = AppState(
            workspaces: separateWorkspaces ? [firstWorkspace, secondWorkspace] : [firstWorkspace],
            projects: projects,
            settings: CodePulseSettings(automationEnabled: automationEnabled, selectedWorkspaceID: firstWorkspace.id),
            sessionPresets: [preset],
            automationRules: rules
        )
        let persistence = Phase3Persistence(state)
        let clock = Phase3Clock(start)
        let inbox = DeveloperToolInbox(paths: DeveloperToolIntegrationPaths(applicationSupportDirectory: root.appendingPathComponent("support")))
        let store = SessionStore(persistence: persistence, clock: clock, gitService: gitService, developerToolEventConsumer: DeveloperToolEventConsumer(inbox: inbox), automaticallyRefresh: false)
        return Fixture(folder: folder, secondFolder: secondFolder, project: project, secondProject: secondProject, persistence: persistence, clock: clock, inbox: inbox, gitService: gitService, store: store)
    }
}

private struct OwnershipSnapshot: Equatable {
    let id: UUID
    let identities: Set<DeveloperToolThreadIdentity>

    init(_ value: (UUID, Set<DeveloperToolThreadIdentity>)) {
        id = value.0
        identities = value.1
    }
}

@MainActor private struct Fixture {
    let folder: URL
    let secondFolder: URL?
    let project: ProjectRecord
    let secondProject: ProjectRecord?
    let persistence: Phase3Persistence
    let clock: Phase3Clock
    let inbox: DeveloperToolInbox
    let gitService: GitServicing
    let store: SessionStore
}

private final class Phase3Persistence: StatePersisting {
    private let lock = NSLock()
    private var _state: AppState
    private var _failCriticalSaves = false
    private var _criticalSuccessCount = 0

    var state: AppState {
        get { withLock { _state } }
        set { withLock { _state = newValue } }
    }
    var failCriticalSaves: Bool {
        get { withLock { _failCriticalSaves } }
        set { withLock { _failCriticalSaves = newValue } }
    }
    var criticalSuccessCount: Int { withLock { _criticalSuccessCount } }

    init(_ state: AppState) { _state = state }
    func load() -> AppState { state }
    func save(_ state: AppState) { self.state = state }
    func saveCritical(_ state: AppState) throws {
        try withLock {
            if _failCriticalSaves { throw Phase3SaveFailure() }
            _criticalSuccessCount += 1
            _state = state
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
private struct Phase3SaveFailure: Error {}
private final class Phase3Clock: SessionClock {
    var now: Date
    init(_ now: Date) { self.now = now }
}
private final class Phase3NoOpGit: GitServicing, @unchecked Sendable {
    func captureStartSnapshot(at folderURL: URL) -> GitStartSnapshot? { nil }
    func captureFinishSnapshot(for startSnapshot: GitStartSnapshot) -> GitFinishSnapshot? { nil }
}

private final class Phase3RecordingGit: GitServicing, @unchecked Sendable {
    private let lock = NSLock()
    var persistence: Phase3Persistence
    private var _captureStartCount = 0
    private var _criticalSuccessCountAtCapture: [Int] = []
    private var _pathsAtCapture: [String] = []

    var captureStartCount: Int { withLock { _captureStartCount } }
    var criticalSuccessCountAtCapture: [Int] { withLock { _criticalSuccessCountAtCapture } }
    var pathsAtCapture: [String] { withLock { _pathsAtCapture } }

    init(persistence: Phase3Persistence) { self.persistence = persistence }

    func captureStartSnapshot(at folderURL: URL) -> GitStartSnapshot? {
        let criticalSuccessCount = persistence.criticalSuccessCount
        withLock {
            _captureStartCount += 1
            _criticalSuccessCountAtCapture.append(criticalSuccessCount)
            _pathsAtCapture.append(folderURL.path)
        }
        return nil
    }

    func captureFinishSnapshot(for startSnapshot: GitStartSnapshot) -> GitFinishSnapshot? { nil }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
