import CodePulseIntegration
import Foundation
import XCTest
@testable import CodePulse

@MainActor
final class SessionPresetAutomationTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_950_000_000)

    func testMilestoneOneRuleMigratesToOneDeterministicPresetIdempotently() throws {
        let project = ProjectRecord(
            name: "CodePulse",
            folderPath: "/tmp/codepulse-migration",
            createdAt: start
        )
        let legacyRule = SessionAutomationRule(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Legacy Codex",
            trigger: .developerTool(.codex),
            projectID: project.id,
            sessionType: .debugging,
            goal: "Migrate this rule"
        )

        let legacyObject: [String: Any] = [
            "projects": [try jsonObject(project)],
            "completedSessions": [],
            "settings": ["automationEnabled": true],
            "automationRules": [try jsonObject(legacyRule)]
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let first = try decodeState(legacyData)
        let second = try decodeState(try encode(first))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.sessionPresets.count, 1)
        XCTAssertEqual(second.sessionPresets.count, 1)
        XCTAssertEqual(first.sessionPresets[0].id, second.sessionPresets[0].id)
        XCTAssertEqual(first.sessionPresets[0].projectID, project.id)
        XCTAssertEqual(first.sessionPresets[0].sessionType, .debugging)
        XCTAssertEqual(first.sessionPresets[0].goal, "Migrate this rule")
        XCTAssertEqual(first.automationRules[0].presetID, first.sessionPresets[0].id)
        XCTAssertNil(first.automationRules[0].projectID)

        let canonicalObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encode(first)) as? [String: Any])
        let canonicalRule = try XCTUnwrap((canonicalObject["automationRules"] as? [[String: Any]])?.first)
        XCTAssertNil(canonicalRule["projectID"])
        XCTAssertNotNil(canonicalRule["presetID"])
    }

    func testProjectIndependentDeveloperTemplatePersistsWithoutProjectOwnership() throws {
        let preset = SessionPreset(
            name: "Developer Tool Template",
            projectID: nil,
            sessionType: .review,
            goal: "Review the resolved repository"
        )
        let rule = SessionAutomationRule(
            name: "Codex anywhere",
            trigger: .developerTool(.codex),
            presetID: preset.id,
            minimumSavedDuration: 0
        )
        let state = AppState(
            settings: CodePulseSettings(automationEnabled: true),
            sessionPresets: [preset],
            automationRules: [rule]
        )

        let decoded = try decodeState(encode(state))
        XCTAssertEqual(decoded, state)
        XCTAssertNil(decoded.sessionPresets.first?.projectID)
        XCTAssertEqual(decoded.automationRules.first?.presetID, preset.id)
        XCTAssertNil(decoded.automationRules.first?.projectID)
    }

    func testPresetRoundTripAndQuickStartRemainManual() throws {
        let project = try makeProject(name: "Preset Project")
        let preset = SessionPreset(
            name: "  Focus preset  ",
            projectID: project.record.id,
            sessionType: .review,
            goal: "  Review the change  "
        )
        let persistence = PresetTestPersistence(AppState(
            projects: [project.record],
            sessionPresets: [preset]
        ))
        let clock = PresetTestClock(start)
        let store = makeStore(persistence: persistence, clock: clock)

        let data = try encode(persistence.state)
        XCTAssertEqual(try decodeState(data), persistence.state)
        XCTAssertTrue(store.startSession(using: preset, at: start))
        XCTAssertEqual(store.activeSession?.projectID, project.record.id)
        XCTAssertEqual(store.activeSession?.type, .review)
        XCTAssertEqual(store.activeSession?.goal, "Review the change")
        XCTAssertNil(store.activeSession?.automationMetadata)
    }

    func testMenuBarAccessibilityStatusNamesProjectAndSessionType() throws {
        let project = try makeProject(name: "Accessibility Project")
        let persistence = PresetTestPersistence(AppState(projects: [project.record]))
        let clock = PresetTestClock(start)
        let store = makeStore(persistence: persistence, clock: clock)

        XCTAssertTrue(store.startSession(projectID: project.record.id, goal: nil, type: .review))
        XCTAssertTrue(store.menuBarAccessibilityText.contains("Accessibility Project"))
        XCTAssertTrue(store.menuBarAccessibilityText.contains(SessionType.review.title))
        XCTAssertTrue(store.menuBarAccessibilityText.contains("running"))
    }

    func testAutomationStatusExplainsGlobalOffAndUnavailableTargets() throws {
        let project = try makeProject(name: "Status Project")
        let preset = SessionPreset(name: "Status Preset", projectID: project.record.id)
        let rule = SessionAutomationRule(
            name: "Status Rule",
            trigger: .developerTool(.codex),
            presetID: preset.id,
            minimumSavedDuration: 0
        )
        let persistence = PresetTestPersistence(AppState(
            projects: [project.record],
            sessionPresets: [preset],
            automationRules: [rule]
        ))
        let store = makeStore(persistence: persistence, clock: PresetTestClock(start))

        var disabledRule = rule
        disabledRule.isEnabled = false
        XCTAssertEqual(store.automationRuleStatus(for: disabledRule), .disabled)
        XCTAssertEqual(store.automationRuleStatusLabel(for: disabledRule), "Disabled")

        XCTAssertEqual(store.automationRuleStatus(for: rule), .automationOff)
        XCTAssertEqual(store.automationRuleStatusLabel(for: rule), "Enabled · Automation Off")
        store.updateSettings { $0.automationEnabled = true }

        var invalidRule = rule
        invalidRule.name = String(repeating: "x", count: 201)
        XCTAssertEqual(store.automationRuleStatus(for: invalidRule), .invalidRule)
        XCTAssertEqual(store.automationRuleStatusLabel(for: invalidRule), "Needs attention · Invalid rule")

        let missingPresetRule = SessionAutomationRule(
            name: "Missing Preset Rule",
            trigger: .developerTool(.codex),
            presetID: UUID(),
            minimumSavedDuration: 0
        )
        XCTAssertEqual(store.automationRuleStatus(for: missingPresetRule), .missingPreset)
        XCTAssertEqual(store.automationRuleStatusLabel(for: missingPresetRule), "Needs attention · Missing preset")

        let missingProjectPreset = SessionPreset(
            name: "Missing Project Preset",
            projectID: UUID()
        )
        XCTAssertTrue(store.upsertSessionPreset(missingProjectPreset))
        let missingProjectRule = SessionAutomationRule(
            name: "Missing Project Rule",
            trigger: .developerTool(.codex),
            presetID: missingProjectPreset.id,
            minimumSavedDuration: 0
        )
        XCTAssertEqual(store.automationRuleStatus(for: missingProjectRule), .missingProject)
        XCTAssertEqual(store.automationRuleStatusLabel(for: missingProjectRule), "Needs attention · Missing project")

        XCTAssertEqual(store.automationRuleStatus(for: rule), .enabled)
        XCTAssertEqual(store.automationRuleStatusLabel(for: rule), "Enabled")

        _ = try store.archiveProject(id: project.record.id, at: start.addingTimeInterval(1))
        XCTAssertEqual(store.automationRuleStatus(for: rule), .projectArchived)
        XCTAssertEqual(store.automationRuleStatusLabel(for: rule), "Project Archived")

        _ = try store.restoreProject(id: project.record.id)
        let missingFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseStatusRelink-\(UUID().uuidString)", isDirectory: true)
        XCTAssertTrue(store.updateProjectFolder(id: project.record.id, folderURL: missingFolder))
        XCTAssertEqual(store.automationRuleStatus(for: rule), .needsRelink)
        XCTAssertEqual(store.automationRuleStatusLabel(for: rule), "Needs Relink")
    }

    func testUpsertAutomationRuleAcceptsNewRuleForUsablePreset() throws {
        let preset = SessionPreset(
            name: "Projectless Automation Template",
            projectID: nil,
            sessionType: .review,
            goal: "Use the runtime project"
        )
        let rule = SessionAutomationRule(
            name: "Usable automation rule",
            trigger: .developerTool(.codex),
            presetID: preset.id,
            minimumSavedDuration: 0
        )
        let persistence = PresetTestPersistence(AppState(
            sessionPresets: [preset]
        ))
        let store = makeStore(persistence: persistence, clock: PresetTestClock(start))

        XCTAssertFalse(store.isPresetUsableForAutomation(preset))
        XCTAssertTrue(store.isDeveloperToolPresetUsable(preset))
        XCTAssertTrue(store.upsertAutomationRule(rule))
        XCTAssertTrue(store.isAutomationRuleUsable(rule))
        XCTAssertEqual(persistence.state.automationRules, [rule])
    }

    func testUpsertAutomationRuleRejectsNewDeveloperRuleForProjectBackedPreset() throws {
        let project = try makeProject(name: "Hidden Scope Project")
        let preset = SessionPreset(name: "Project Backed Template", projectID: project.record.id)
        let rule = SessionAutomationRule(
            name: "New project-backed developer rule",
            trigger: .developerTool(.codex),
            presetID: preset.id,
            minimumSavedDuration: 0
        )
        let persistence = PresetTestPersistence(AppState(
            projects: [project.record],
            sessionPresets: [preset]
        ))
        let store = makeStore(persistence: persistence, clock: PresetTestClock(start))

        XCTAssertTrue(store.isDeveloperToolPresetUsable(preset))
        XCTAssertFalse(store.upsertAutomationRule(rule))
        XCTAssertTrue(persistence.state.automationRules.isEmpty)
    }

    func testExistingProjectlessDeveloperRuleRejectsAddingProjectBackedScope() throws {
        let project = try makeProject(name: "Hidden Scope Update Project")
        let projectlessPreset = SessionPreset(
            name: "Projectless Template",
            projectID: nil,
            sessionType: .review,
            goal: "Detected project"
        )
        let projectBackedPreset = SessionPreset(
            name: "Project Backed Template",
            projectID: project.record.id,
            sessionType: .debugging,
            goal: "Hidden project"
        )
        let rule = SessionAutomationRule(
            name: "Projectless developer rule",
            trigger: .developerTool(.codex),
            presetID: projectlessPreset.id,
            minimumSavedDuration: 0
        )
        let persistence = PresetTestPersistence(AppState(
            projects: [project.record],
            sessionPresets: [projectlessPreset, projectBackedPreset],
            automationRules: [rule]
        ))
        let store = makeStore(persistence: persistence, clock: PresetTestClock(start))

        var retargeted = rule
        retargeted.presetID = projectBackedPreset.id

        XCTAssertFalse(store.upsertAutomationRule(retargeted))
        XCTAssertEqual(persistence.state.automationRules, [rule])
    }

    func testUpsertAutomationRuleRejectsNewRuleForUnusablePresetTargets() throws {
        let validProject = try makeProject(name: "Valid Automation Project")
        let archivedFolder = try makeProject(name: "Archived Automation Project")
        let missingFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseMissingRelink-\(UUID().uuidString)", isDirectory: true)
        let archivedProject = ProjectRecord(
            id: archivedFolder.record.id,
            name: archivedFolder.record.name,
            folderPath: archivedFolder.url.path,
            createdAt: start,
            archivedAt: start.addingTimeInterval(-1)
        )
        let relinkProject = ProjectRecord(
            name: "Needs Relink Automation Project",
            folderPath: missingFolder.path,
            createdAt: start
        )
        let missingProjectID = UUID()
        let presets = [
            SessionPreset(name: "No Project", projectID: nil),
            SessionPreset(name: "Missing Project", projectID: missingProjectID),
            SessionPreset(name: "Archived Project", projectID: archivedProject.id),
            SessionPreset(name: "Needs Relink Project", projectID: relinkProject.id)
        ]
        let persistence = PresetTestPersistence(AppState(
            projects: [validProject.record, archivedProject, relinkProject],
            sessionPresets: presets
        ))
        let store = makeStore(persistence: persistence, clock: PresetTestClock(start))

        for preset in presets {
            let rule = SessionAutomationRule(
                name: "New \(preset.name) rule",
                trigger: .developerTool(.codex),
                presetID: preset.id,
                minimumSavedDuration: 0
            )

            if preset.projectID == nil {
                XCTAssertFalse(store.isPresetUsableForAutomation(preset), preset.name)
                XCTAssertTrue(store.isDeveloperToolPresetUsable(preset), preset.name)
                XCTAssertTrue(store.upsertAutomationRule(rule), preset.name)
            } else {
                XCTAssertFalse(store.isPresetUsableForAutomation(preset), preset.name)
                XCTAssertFalse(store.isDeveloperToolPresetUsable(preset), preset.name)
                XCTAssertFalse(store.upsertAutomationRule(rule), preset.name)
            }
        }
        XCTAssertEqual(persistence.state.automationRules.count, 1)
    }

    func testExistingRulePreservesArchivedAndNeedsRelinkPresetWhenEdited() throws {
        let project = try makeProject(name: "Preserved Automation Project")
        let preset = SessionPreset(name: "Preserved Automation Preset", projectID: project.record.id)
        let rule = SessionAutomationRule(
            id: UUID(),
            name: "Preserved automation rule",
            isEnabled: true,
            trigger: .developerTool(.codex),
            presetID: preset.id,
            minimumSavedDuration: 0
        )
        let persistence = PresetTestPersistence(AppState(
            projects: [project.record],
            sessionPresets: [preset],
            automationRules: [rule]
        ))
        let store = makeStore(persistence: persistence, clock: PresetTestClock(start))

        XCTAssertEqual(store.state.automationRules, [rule])
        XCTAssertTrue(store.isAutomationRuleUsable(rule))
        XCTAssertTrue(store.upsertAutomationRule(rule))

        _ = try store.archiveProject(id: project.record.id, at: start.addingTimeInterval(1))
        XCTAssertFalse(store.isAutomationRuleUsable(rule))
        var archivedEdit = rule
        archivedEdit.name = "Edited while archived"
        XCTAssertTrue(store.upsertAutomationRule(archivedEdit))
        XCTAssertEqual(persistence.state.automationRules.first?.id, rule.id)
        XCTAssertEqual(persistence.state.automationRules.first?.presetID, preset.id)

        _ = try store.restoreProject(id: project.record.id)
        let missingFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseRelinkFailure-\(UUID().uuidString)", isDirectory: true)
        XCTAssertTrue(store.updateProjectFolder(id: project.record.id, folderURL: missingFolder))
        XCTAssertFalse(store.isAutomationRuleUsable(archivedEdit))
        var relinkEdit = archivedEdit
        relinkEdit.name = "Edited while needing relink"
        XCTAssertTrue(store.upsertAutomationRule(relinkEdit))

        let savedRule = try XCTUnwrap(persistence.state.automationRules.first)
        XCTAssertEqual(savedRule.id, rule.id)
        XCTAssertEqual(savedRule.presetID, preset.id)
        XCTAssertTrue(savedRule.isEnabled)
    }

    func testExistingLegacyDeveloperRuleCanConvertToProjectlessPreset() throws {
        let project = try makeProject(name: "Legacy Conversion Project")
        let legacyPreset = SessionPreset(name: "Legacy Template", projectID: project.record.id)
        let projectlessPreset = SessionPreset(
            name: "Runtime Template",
            projectID: nil,
            sessionType: .debugging,
            goal: "Use the detected project"
        )
        let rule = SessionAutomationRule(
            name: "Convertible legacy rule",
            trigger: .developerTool(.codex),
            presetID: legacyPreset.id,
            minimumSavedDuration: 0
        )
        let persistence = PresetTestPersistence(AppState(
            projects: [project.record],
            sessionPresets: [legacyPreset, projectlessPreset],
            automationRules: [rule]
        ))
        let store = makeStore(persistence: persistence, clock: PresetTestClock(start))

        var converted = rule
        converted.presetID = projectlessPreset.id
        XCTAssertTrue(store.upsertAutomationRule(converted))
        XCTAssertEqual(persistence.state.automationRules.first?.presetID, projectlessPreset.id)
    }

    func testExistingLegacyRuleRejectsRetargetingToProjectBackedPresetTargets() throws {
        let validProject = try makeProject(name: "Retarget Source Project")
        let otherProject = try makeProject(name: "Retarget Other Project")
        let archivedFolder = try makeProject(name: "Retarget Archived Project")
        let archivedProject = ProjectRecord(
            id: archivedFolder.record.id,
            name: archivedFolder.record.name,
            folderPath: archivedFolder.url.path,
            createdAt: start,
            archivedAt: start.addingTimeInterval(-1)
        )
        let relinkProject = ProjectRecord(
            name: "Retarget Needs Relink Project",
            folderPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("CodePulseRetargetRelink-\(UUID().uuidString)", isDirectory: true)
                .path,
            createdAt: start
        )
        let validPreset = SessionPreset(name: "Retarget Source Preset", projectID: validProject.record.id)
        let otherPreset = SessionPreset(name: "Retarget Other Preset", projectID: otherProject.record.id)
        let unusablePresets = [
            SessionPreset(name: "Retarget No Project", projectID: nil),
            SessionPreset(name: "Retarget Missing Project", projectID: UUID()),
            SessionPreset(name: "Retarget Archived Project", projectID: archivedProject.id),
            SessionPreset(name: "Retarget Needs Relink Project", projectID: relinkProject.id)
        ]
        let rule = SessionAutomationRule(
            name: "Retargetable automation rule",
            trigger: .developerTool(.codex),
            presetID: validPreset.id,
            minimumSavedDuration: 0
        )
        let persistence = PresetTestPersistence(AppState(
            projects: [validProject.record, otherProject.record, archivedProject, relinkProject],
            sessionPresets: [validPreset, otherPreset] + unusablePresets,
            automationRules: [rule]
        ))
        let store = makeStore(persistence: persistence, clock: PresetTestClock(start))

        XCTAssertEqual(store.state.automationRules, [rule])
        var expectedRule = rule
        var retargetedToOtherProject = rule
        retargetedToOtherProject.presetID = otherPreset.id
        XCTAssertFalse(store.upsertAutomationRule(retargetedToOtherProject))
        XCTAssertEqual(store.state.automationRules, [rule])

        for preset in [unusablePresets[0], otherPreset] + Array(unusablePresets.dropFirst()) {
            var retargetedRule = rule
            retargetedRule.name = "Retargeted to \(preset.name)"
            retargetedRule.presetID = preset.id

            if preset.projectID == nil {
                XCTAssertTrue(store.upsertAutomationRule(retargetedRule), preset.name)
                expectedRule = retargetedRule
            } else {
                XCTAssertFalse(store.upsertAutomationRule(retargetedRule), preset.name)
            }
            XCTAssertEqual(persistence.state.automationRules, [expectedRule])
        }
    }

    func testPresetsForAutomationEditingFiltersUnusableTargetsExceptCurrentPreset() throws {
        let validProject = try makeProject(name: "Editor Valid Project")
        let unrelatedProject = try makeProject(name: "Editor Unrelated Project")
        let archivedFolder = try makeProject(name: "Editor Archived Project")
        let archivedProject = ProjectRecord(
            id: archivedFolder.record.id,
            name: archivedFolder.record.name,
            folderPath: archivedFolder.url.path,
            createdAt: start,
            archivedAt: start.addingTimeInterval(-1)
        )
        let relinkProject = ProjectRecord(
            name: "Editor Needs Relink Project",
            folderPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("CodePulseEditorRelink-\(UUID().uuidString)", isDirectory: true)
                .path,
            createdAt: start
        )
        let validPreset = SessionPreset(name: "Editor Valid Preset", projectID: validProject.record.id)
        let unrelatedPreset = SessionPreset(name: "Editor Unrelated Preset", projectID: unrelatedProject.record.id)
        let unusablePresets = [
            SessionPreset(name: "Editor No Project", projectID: nil),
            SessionPreset(name: "Editor Missing Project", projectID: UUID()),
            SessionPreset(name: "Editor Archived Project", projectID: archivedProject.id),
            SessionPreset(name: "Editor Needs Relink Project", projectID: relinkProject.id)
        ]
        let persistence = PresetTestPersistence(AppState(
            projects: [validProject.record, unrelatedProject.record, archivedProject, relinkProject],
            sessionPresets: [validPreset, unrelatedPreset] + unusablePresets
        ))
        let store = makeStore(persistence: persistence, clock: PresetTestClock(start))

        XCTAssertEqual(
            Set(store.sessionPresetsAvailableForAutomation.map(\.id)),
            Set([validPreset.id, unrelatedPreset.id])
        )
        XCTAssertEqual(
            Set(store.sessionPresetsAvailableForDeveloperAutomation.map(\.id)),
            Set([unusablePresets[0].id])
        )
        XCTAssertEqual(
            Set(store.presetsForAutomationEditing(nil).map(\.id)),
            Set([unusablePresets[0].id])
        )

        let legacyRule = SessionAutomationRule(
            name: "Current legacy rule",
            trigger: .developerTool(.codex),
            presetID: validPreset.id,
            minimumSavedDuration: 0
        )
        XCTAssertEqual(
            Set(store.presetsForAutomationEditing(legacyRule).map(\.id)),
            Set([validPreset.id, unusablePresets[0].id])
        )
        XCTAssertEqual(
            Set(store.developerToolPresetsForAutomationEditing(legacyRule).map(\.id)),
            Set([validPreset.id, unusablePresets[0].id])
        )
        XCTAssertEqual(
            Set(store.applicationPresetsForAutomationEditing(nil).map(\.id)),
            Set([validPreset.id, unrelatedPreset.id])
        )
    }

    func testDeveloperToolApplicationPresenceCannotProvideProjectAutomationContext() throws {
        let project = try makeProject(name: "Tool Presence Project")
        let preset = SessionPreset(name: "Tool Presence Preset", projectID: project.record.id)
        let applications = [
            ApplicationIdentity(bundleIdentifier: "com.openai.codex", displayName: "Codex"),
            ApplicationIdentity(bundleIdentifier: "com.example.opencode", displayName: "OpenCode")
        ]

        for application in applications {
            let rule = SessionAutomationRule(
                name: "\(application.displayName) presence",
                trigger: .applications(ApplicationAutomationTrigger(applications: [application])),
                presetID: preset.id,
                minimumSavedDuration: 0
            )
            let state = AppState(
                projects: [project.record],
                settings: CodePulseSettings(automationEnabled: true),
                sessionPresets: [preset],
                automationRules: [rule]
            )
            let store = makeStore(
                persistence: PresetTestPersistence(state),
                clock: PresetTestClock(start)
            )

            XCTAssertTrue(SessionAutomationCoordinator.isDeveloperToolApplication(application))
            XCTAssertFalse(store.isAutomationRuleUsable(rule))
            XCTAssertNil(SessionAutomationCoordinator().action(
                for: application,
                in: state,
                now: start
            ))
        }
    }

    func testDeveloperToolApplicationClassifierUsesExactNormalizedIdentitiesConsistently() throws {
        let exactIdentities = [
            ApplicationIdentity(bundleIdentifier: "com.openai.codex", displayName: "Desktop Client"),
            ApplicationIdentity(bundleIdentifier: "com.example.shell", displayName: "  OpenCode ")
        ]
        for identity in exactIdentities {
            XCTAssertTrue(SessionAutomationCoordinator.isDeveloperToolApplication(identity), identity.bundleIdentifier)
        }

        let nearMatches = [
            ApplicationIdentity(bundleIdentifier: "com.example.codex-helper", displayName: "Codex Helper"),
            ApplicationIdentity(bundleIdentifier: "com.example.opencode-tools", displayName: "OpenCode Tools"),
            ApplicationIdentity(bundleIdentifier: "com.example.editor", displayName: "Code X")
        ]
        for identity in nearMatches {
            XCTAssertFalse(SessionAutomationCoordinator.isDeveloperToolApplication(identity), identity.bundleIdentifier)
        }

        let project = try makeProject(name: "Classifier Project")
        let preset = SessionPreset(name: "Classifier Preset", projectID: project.record.id)
        let nearMatchRule = SessionAutomationRule(
            name: "Near match application",
            trigger: .applications(ApplicationAutomationTrigger(applications: [nearMatches[0]])),
            presetID: preset.id,
            minimumSavedDuration: 0
        )
        let state = AppState(
            projects: [project.record],
            settings: CodePulseSettings(automationEnabled: true),
            sessionPresets: [preset],
            automationRules: [nearMatchRule]
        )
        let store = makeStore(
            persistence: PresetTestPersistence(state),
            clock: PresetTestClock(start)
        )
        XCTAssertTrue(store.isAutomationRuleUsable(nearMatchRule))
        XCTAssertNotNil(SessionAutomationCoordinator().action(
            for: nearMatches[0],
            in: state,
            now: start
        ))
    }

    func testStaleDeveloperToolApplicationClaimIsRelinquishedOnReload() throws {
        let project = try makeProject(name: "Stale Claim Project")
        let preset = SessionPreset(name: "Stale Claim Preset", projectID: project.record.id)
        let codex = ApplicationIdentity(bundleIdentifier: "com.openai.codex", displayName: "Codex")
        let rule = SessionAutomationRule(
            name: "Legacy Codex application",
            trigger: .applications(ApplicationAutomationTrigger(applications: [codex])),
            presetID: preset.id,
            minimumSavedDuration: 0
        )
        let source = SessionAutomationClaimSource.application(bundleIdentifier: codex.bundleIdentifier)
        let metadata = SessionAutomationMetadata(
            startedByRuleID: rule.id,
            startedByRuleName: rule.name,
            startedBySource: source,
            lastMatchingSignalAt: start,
            pauseDelay: 60,
            finishDelay: 300,
            minimumSavedDuration: 0,
            claims: [SessionAutomationClaim(source: source, isActive: true, lastSignalAt: start)]
        )
        let state = AppState(
            projects: [project.record],
            activeSession: ActiveSession(
                projectID: project.record.id,
                projectName: project.record.name,
                startedAt: start,
                automationMetadata: metadata
            ),
            settings: CodePulseSettings(automationEnabled: true),
            sessionPresets: [preset],
            automationRules: [rule]
        )

        let store = makeStore(
            persistence: PresetTestPersistence(state),
            clock: PresetTestClock(start)
        )

        XCTAssertFalse(store.activeSession?.automationMetadata?.controlEnabled ?? true)
        XCTAssertTrue(store.activeSession?.automationMetadata?.claims.isEmpty == true)
        XCTAssertNil(SessionAutomationCoordinator().action(for: codex, in: store.state, now: start))
    }

    func testApplicationRuleStartsAndSwitchesWithinOneSession() async throws {
        let project = try makeProject(name: "Application Project")
        let preset = SessionPreset(name: "Application Coding", projectID: project.record.id)
        let xcode = ApplicationIdentity(bundleIdentifier: "com.apple.dt.Xcode", displayName: "Xcode")
        let terminal = ApplicationIdentity(bundleIdentifier: "com.apple.Terminal", displayName: "Terminal")
        let safari = ApplicationIdentity(bundleIdentifier: "com.apple.Safari", displayName: "Safari")
        let rule = SessionAutomationRule(
            name: "Apple Development Apps",
            trigger: .applications(ApplicationAutomationTrigger(applications: [xcode, terminal])),
            presetID: preset.id,
            pauseDelay: 10,
            finishDelay: 30,
            minimumSavedDuration: 0
        )
        let persistence = PresetTestPersistence(AppState(
            projects: [project.record],
            settings: CodePulseSettings(automationEnabled: true),
            sessionPresets: [preset],
            automationRules: [rule]
        ))
        let clock = PresetTestClock(start)
        let monitor = TestFrontmostApplicationMonitor(currentApplication: xcode)
        let store = makeStore(persistence: persistence, clock: clock, monitor: monitor)
        let sessionID = try XCTUnwrap(store.activeSession?.id)

        XCTAssertEqual(store.phase, .running)
        XCTAssertEqual(store.activeSession?.automationMetadata?.claims.count, 1)
        XCTAssertEqual(store.activeAutomationStatusLabel, "Automatic · Xcode")

        monitor.setCurrentApplication(terminal)
        XCTAssertEqual(store.activeSession?.id, sessionID)
        XCTAssertEqual(store.phase, .running)
        XCTAssertEqual(
            store.activeSession?.automationMetadata?.claims.first(where: { $0.source == .application(bundleIdentifier: "com.apple.Terminal") })?.isActive,
            true
        )
        XCTAssertEqual(
            store.activeSession?.automationMetadata?.claims.first(where: { $0.source == .application(bundleIdentifier: "com.apple.dt.Xcode") })?.isActive,
            false
        )

        monitor.setCurrentApplication(safari)
        XCTAssertEqual(store.activeAutomationStatusLabel, "Automatic · Xcode")
        XCTAssertEqual(
            try XCTUnwrap(store.activeSession?.automationMetadata).statusLabel(contexts: []),
            "Automatic · Application"
        )
        clock.now = start.addingTimeInterval(9)
        store.refresh()
        XCTAssertEqual(store.phase, .running)
        clock.now = start.addingTimeInterval(10)
        store.refresh()
        XCTAssertEqual(store.phase, .paused)

        monitor.setCurrentApplication(xcode)
        XCTAssertEqual(store.phase, .running)
        XCTAssertEqual(store.activeSession?.id, sessionID)

        monitor.setCurrentApplication(safari)
        clock.now = start.addingTimeInterval(20)
        store.refresh()
        XCTAssertEqual(store.phase, .paused)
        monitor.setCurrentApplication(terminal)
        XCTAssertEqual(store.phase, .running)
        XCTAssertEqual(store.activeSession?.id, sessionID)

        monitor.setCurrentApplication(safari)
        clock.now = start.addingTimeInterval(50)
        store.refresh()
        try await settle(store)
        XCTAssertEqual(store.phase, .idle)
        XCTAssertEqual(persistence.state.completedSessions.count, 1)
        XCTAssertEqual(persistence.state.completedSessions[0].id, sessionID)
    }

    func testApplicationIdentityDeduplicatesByBundleIdentifier() throws {
        let trigger = ApplicationAutomationTrigger(applications: [
            ApplicationIdentity(bundleIdentifier: "com.example.Editor", displayName: "Editor"),
            ApplicationIdentity(bundleIdentifier: "com.example.Editor", displayName: "Renamed Editor"),
            ApplicationIdentity(bundleIdentifier: "", displayName: "Missing")
        ])

        XCTAssertEqual(trigger.applications.count, 1)
        XCTAssertEqual(trigger.applications[0].displayName, "Editor")
        XCTAssertTrue(trigger.matches(bundleIdentifier: "com.example.Editor"))
        XCTAssertFalse(trigger.matches(bundleIdentifier: "Editor"))
    }

    func testDisabledApplicationRuleDoesNotStartFrontmostMonitoring() throws {
        let project = try makeProject(name: "Disabled Application Project")
        let preset = SessionPreset(name: "Disabled Application", projectID: project.record.id)
        let rule = SessionAutomationRule(
            name: "Disabled Editor",
            isEnabled: false,
            trigger: .applications(ApplicationAutomationTrigger(applications: [
                ApplicationIdentity(bundleIdentifier: "com.example.Editor", displayName: "Editor")
            ])),
            presetID: preset.id
        )
        let persistence = PresetTestPersistence(AppState(
            projects: [project.record],
            settings: CodePulseSettings(automationEnabled: true),
            sessionPresets: [preset],
            automationRules: [rule]
        ))
        let monitor = TestFrontmostApplicationMonitor(
            currentApplication: ApplicationIdentity(bundleIdentifier: "com.example.Editor", displayName: "Editor")
        )

        _ = makeStore(persistence: persistence, clock: PresetTestClock(start), monitor: monitor)

        XCTAssertFalse(monitor.isRunning)
    }

    func testDeletingPresetRelinquishesActiveAutomationWithoutFinishing() throws {
        let project = try makeProject(name: "Delete Preset Project")
        let preset = SessionPreset(name: "Delete Me", projectID: project.record.id)
        let application = ApplicationIdentity(bundleIdentifier: "com.example.Editor", displayName: "Editor")
        let rule = SessionAutomationRule(
            name: "Editor Rule",
            trigger: .applications(ApplicationAutomationTrigger(applications: [application])),
            presetID: preset.id,
            pauseDelay: 1,
            finishDelay: 2,
            minimumSavedDuration: 0
        )
        let persistence = PresetTestPersistence(AppState(
            projects: [project.record],
            settings: CodePulseSettings(automationEnabled: true),
            sessionPresets: [preset],
            automationRules: [rule]
        ))
        let clock = PresetTestClock(start)
        let monitor = TestFrontmostApplicationMonitor(currentApplication: application)
        let store = makeStore(persistence: persistence, clock: clock, monitor: monitor)
        XCTAssertEqual(store.phase, .running)

        store.deleteSessionPreset(id: preset.id)

        XCTAssertEqual(store.phase, .running)
        let activeSession = try XCTUnwrap(store.activeSession)
        let automationMetadata = try XCTUnwrap(activeSession.automationMetadata)
        XCTAssertFalse(automationMetadata.controlEnabled)
        clock.now = start.addingTimeInterval(5)
        store.refresh()
        XCTAssertEqual(store.phase, .running)
        XCTAssertTrue(persistence.state.completedSessions.isEmpty)
    }

    func testApplicationAndDeveloperClaimsCoexistAndKeepOneSessionAlive() throws {
        let project = try makeProject(name: "Mixed Claims Project")
        let preset = SessionPreset(name: "Mixed Coding", projectID: project.record.id)
        let xcode = ApplicationIdentity(bundleIdentifier: "com.apple.dt.Xcode", displayName: "Xcode")
        let appRule = SessionAutomationRule(
            name: "Xcode",
            trigger: .applications(ApplicationAutomationTrigger(applications: [xcode])),
            presetID: preset.id,
            pauseDelay: 20,
            finishDelay: 40,
            minimumSavedDuration: 0
        )
        let developerRule = SessionAutomationRule(
            name: "Codex",
            trigger: .developerTool(.codex),
            presetID: preset.id,
            pauseDelay: 20,
            finishDelay: 40,
            minimumSavedDuration: 0
        )
        let persistence = PresetTestPersistence(AppState(
            projects: [project.record],
            settings: CodePulseSettings(automationEnabled: true),
            sessionPresets: [preset],
            automationRules: [appRule, developerRule]
        ))
        let paths = DeveloperToolIntegrationPaths(
            applicationSupportDirectory: project.url.appendingPathComponent("support")
        )
        let inbox = DeveloperToolInbox(paths: paths)
        let clock = PresetTestClock(start)
        let monitor = TestFrontmostApplicationMonitor(currentApplication: xcode)
        let store = makeStore(
            persistence: persistence,
            clock: clock,
            monitor: monitor,
            inbox: inbox
        )
        let sessionID = try XCTUnwrap(store.activeSession?.id)

        clock.now = start.addingTimeInterval(5)
        try inbox.write(DeveloperToolEvent(
            tool: .codex,
            externalSessionID: "codex-mixed",
            eventType: .activity,
            timestamp: clock.now,
            workingDirectory: project.url.path
        ))
        store.refresh()

        XCTAssertEqual(store.activeSession?.id, sessionID)
        XCTAssertEqual(store.activeSession?.automationMetadata?.claims.count, 2)

        monitor.setCurrentApplication(ApplicationIdentity(bundleIdentifier: "com.apple.Safari", displayName: "Safari"))
        clock.now = start.addingTimeInterval(10)
        store.refresh()
        XCTAssertEqual(store.phase, .running)

        try inbox.write(DeveloperToolEvent(
            tool: .codex,
            externalSessionID: "codex-mixed",
            eventType: .sessionEnded,
            timestamp: clock.now,
            workingDirectory: project.url.path
        ))
        clock.now = start.addingTimeInterval(15)
        store.refresh()
        XCTAssertEqual(store.phase, .running)

        monitor.setCurrentApplication(xcode)
        XCTAssertEqual(store.phase, .running)
        XCTAssertEqual(store.activeSession?.id, sessionID)
        XCTAssertEqual(
            store.activeSession?.automationMetadata?.claims.first(where: { $0.source == .application(bundleIdentifier: xcode.bundleIdentifier) })?.isActive,
            true
        )
    }

    func testManualTakeoverPreventsApplicationAutoResume() throws {
        let project = try makeProject(name: "Manual Takeover Project")
        let preset = SessionPreset(name: "Manual Coding", projectID: project.record.id)
        let editor = ApplicationIdentity(bundleIdentifier: "com.example.Editor", displayName: "Editor")
        let rule = SessionAutomationRule(
            name: "Editor",
            trigger: .applications(ApplicationAutomationTrigger(applications: [editor])),
            presetID: preset.id,
            pauseDelay: 1,
            finishDelay: 3,
            minimumSavedDuration: 0
        )
        let persistence = PresetTestPersistence(AppState(
            projects: [project.record],
            settings: CodePulseSettings(automationEnabled: true),
            sessionPresets: [preset],
            automationRules: [rule]
        ))
        let clock = PresetTestClock(start)
        let monitor = TestFrontmostApplicationMonitor(currentApplication: editor)
        let store = makeStore(persistence: persistence, clock: clock, monitor: monitor)

        XCTAssertTrue(store.pause(at: start.addingTimeInterval(1)))
        monitor.setCurrentApplication(ApplicationIdentity(bundleIdentifier: "com.apple.Safari", displayName: "Safari"))
        clock.now = start.addingTimeInterval(2)
        store.refresh()
        monitor.setCurrentApplication(editor)

        XCTAssertEqual(store.phase, .paused)
        let activeSession = try XCTUnwrap(store.activeSession)
        let automationMetadata = try XCTUnwrap(activeSession.automationMetadata)
        XCTAssertFalse(automationMetadata.controlEnabled)
    }

    private func makeProject(name: String) throws -> (record: ProjectRecord, url: URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulsePresetTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return (ProjectRecord(name: name, folderPath: url.path, createdAt: start), url)
    }

    private func makeStore(
        persistence: PresetTestPersistence,
        clock: PresetTestClock,
        monitor: FrontmostApplicationMonitoring? = nil,
        inbox: DeveloperToolInbox? = nil
    ) -> SessionStore {
        SessionStore(
            persistence: persistence,
            clock: clock,
            gitService: PresetNoOpGitService(),
            developerToolEventConsumer: inbox.map { DeveloperToolEventConsumer(inbox: $0) } ?? DeveloperToolEventConsumer(),
            automaticallyRefresh: false,
            frontmostApplicationMonitor: monitor
        )
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func decodeState(_ data: Data) throws -> AppState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppState.self, from: data)
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: encode(value))
    }

    private func settle(_ store: SessionStore) async throws {
        for _ in 0..<200 {
            if !store.gitCaptureInProgress { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for Git capture")
    }
}

private final class PresetTestClock: SessionClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private final class PresetTestPersistence: StatePersisting {
    var state: AppState

    init(_ state: AppState) {
        self.state = state
    }

    func load() -> AppState { state }
    func save(_ state: AppState) { self.state = state }
}

private final class PresetNoOpGitService: GitServicing, @unchecked Sendable {
    func captureStartSnapshot(at folderURL: URL) -> GitStartSnapshot? { nil }
    func captureFinishSnapshot(for startSnapshot: GitStartSnapshot) -> GitFinishSnapshot? { nil }
}
