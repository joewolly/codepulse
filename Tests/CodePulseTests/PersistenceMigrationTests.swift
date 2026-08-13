import Foundation
import XCTest
@testable import CodePulse

final class PersistenceMigrationTests: XCTestCase {
    func testLegacyV1FixtureDecodesAndMigratesToVersionedEnvelope() throws {
        let directory = try makeTemporaryDirectory()
        let stateURL = directory.appendingPathComponent("state.json")
        let fixture = try fixtureData(named: "v1-state")
        try fixture.write(to: stateURL)
        let migrationDate = Date(timeIntervalSince1970: 1_700_000_000)
        let persistence = JSONFilePersistence(fileURL: stateURL, now: { migrationDate })

        let state = persistence.load()

        XCTAssertEqual(state.projects.map(\.name), ["Example Project"])
        XCTAssertEqual(state.completedSessions.first?.type, .review)
        XCTAssertEqual(state.completedSessions.first?.goal, "Review a migration")
        XCTAssertEqual(try Data(contentsOf: persistence.backupURL), fixture)

        let envelope = try decodeEnvelope(at: stateURL)
        XCTAssertEqual(envelope.schemaVersion, StatePersistenceEnvelope.currentSchemaVersion)
        XCTAssertEqual(envelope.createdAt, migrationDate)
        XCTAssertEqual(envelope.payload, state)
        XCTAssertEqual(envelope.migrationHistory, [StateMigrationRecord(
            identifier: "legacy-state-to-envelope",
            fromVersion: 1,
            toVersion: StatePersistenceEnvelope.currentSchemaVersion,
            migratedAt: migrationDate
        )])
    }

    func testMigrationIsIdempotent() throws {
        let directory = try makeTemporaryDirectory()
        let stateURL = directory.appendingPathComponent("state.json")
        try fixtureData(named: "v1-state").write(to: stateURL)
        let persistence = JSONFilePersistence(fileURL: stateURL, now: { Date(timeIntervalSince1970: 1_700_000_000) })

        let first = persistence.load()
        let migratedData = try Data(contentsOf: stateURL)
        let second = persistence.load()

        XCTAssertEqual(second, first)
        XCTAssertEqual(try Data(contentsOf: stateURL), migratedData)
    }

    func testSaveRetainsMigrationHistoryAndOriginalEnvelopeCreationTime() throws {
        let directory = try makeTemporaryDirectory()
        let stateURL = directory.appendingPathComponent("state.json")
        try fixtureData(named: "v1-state").write(to: stateURL)
        let migrationDate = Date(timeIntervalSince1970: 1_700_000_000)
        let persistence = JSONFilePersistence(fileURL: stateURL, now: { migrationDate })
        var state = persistence.load()
        state.settings.globalShortcutEnabled = false

        persistence.save(state)

        let envelope = try decodeEnvelope(at: stateURL)
        XCTAssertEqual(envelope.createdAt, migrationDate)
        XCTAssertEqual(envelope.migrationHistory.map(\.identifier), ["legacy-state-to-envelope"])
        XCTAssertFalse(envelope.payload.settings.globalShortcutEnabled)
    }

    func testFutureVersionIsRejectedWithoutReplacingPreviouslyLoadedState() throws {
        let directory = try makeTemporaryDirectory()
        let stateURL = directory.appendingPathComponent("state.json")
        let persistence = JSONFilePersistence(fileURL: stateURL)
        var existing = AppState()
        existing.projects = [ProjectRecord(
            name: "Keep me",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )]
        persistence.save(existing)
        XCTAssertEqual(persistence.load(), existing)

        let future = StatePersistenceEnvelope(
            schemaVersion: StatePersistenceEnvelope.currentSchemaVersion + 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            migrationHistory: [],
            payload: AppState()
        )
        try encode(future).write(to: stateURL, options: .atomic)

        XCTAssertEqual(persistence.load(), existing)
        XCTAssertEqual(persistence.recoveryIssue?.kind, .unsupportedFutureVersion(3))
        XCTAssertEqual(try Data(contentsOf: stateURL), try encode(future))
    }

    func testFailedAtomicMigrationPreservesLegacyStateAndOffersRecoveryCopy() throws {
        let directory = try makeTemporaryDirectory()
        let stateURL = directory.appendingPathComponent("state.json")
        let fixture = try fixtureData(named: "v1-state")
        try fixture.write(to: stateURL)
        let persistence = JSONFilePersistence(
            fileURL: stateURL,
            atomicWrite: { data, target in
                if target == stateURL {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try data.write(to: target, options: .atomic)
            }
        )

        XCTAssertEqual(persistence.load().projects.map(\.name), ["Example Project"])
        XCTAssertEqual(persistence.recoveryIssue?.kind, .recoveredFromBackup)
        XCTAssertEqual(try Data(contentsOf: stateURL), fixture)

        let recoveryURL = directory.appendingPathComponent("recovery.json")
        try persistence.exportRecoveryCopy(to: recoveryURL)
        XCTAssertEqual(try Data(contentsOf: recoveryURL), fixture)
    }

    func testSaveFailureKeepsExistingStateAndLastKnownGoodBackup() throws {
        let directory = try makeTemporaryDirectory()
        let stateURL = directory.appendingPathComponent("state.json")
        let original = AppState(projects: [ProjectRecord(name: "Original")])
        let replacement = AppState(projects: [ProjectRecord(name: "Replacement")])
        let seed = JSONFilePersistence(fileURL: stateURL)
        seed.save(original)
        let originalData = try Data(contentsOf: stateURL)

        let persistence = JSONFilePersistence(
            fileURL: stateURL,
            atomicWrite: { data, target in
                if target == stateURL {
                    throw CocoaError(.fileWriteNoPermission)
                }
                try data.write(to: target, options: .atomic)
            }
        )
        persistence.save(replacement)

        XCTAssertEqual(persistence.recoveryIssue?.kind, .writeFailed)
        XCTAssertEqual(try Data(contentsOf: stateURL), originalData)
        XCTAssertEqual(try Data(contentsOf: persistence.backupURL), originalData)
    }

    private func fixtureData(named name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: "persistence"
        ))
        return try Data(contentsOf: url)
    }

    private func decodeEnvelope(at url: URL) throws -> StatePersistenceEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StatePersistenceEnvelope.self, from: Data(contentsOf: url))
    }

    private func encode(_ envelope: StatePersistenceEnvelope) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulsePersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
