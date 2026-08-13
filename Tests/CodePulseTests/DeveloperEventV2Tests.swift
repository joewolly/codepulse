import CodePulseIntegration
import Foundation
import XCTest
@testable import CodePulse

final class DeveloperEventV2Tests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSchemaRoundTripsAndRejectsContentBearingFields() throws {
        let event = makeEvent()
        let encoded = try DeveloperEventV2Codec.encode(event)
        XCTAssertEqual(try DeveloperEventV2Codec.decode(encoded), event)
        XCTAssertEqual(try DeveloperEventV2Validator.sanitized(event, now: now).workingDirectory, "/tmp/codepulse/Sources")

        let unsafe = Data(#"{"schemaVersion":2,"integration":"codex","eventKind":"activity.observed","observedAt":"2027-01-15T08:00:00Z","idempotencyKey":"codex-0123456789abcdef","externalSessionKey":"session-1","workingDirectory":"/tmp/codepulse","parserVersion":"1","integrationVersion":"1","prompt":"do not store me"}"#.utf8)
        XCTAssertThrowsError(try DeveloperEventV2Codec.decode(unsafe)) { error in
            XCTAssertEqual(error as? DeveloperEventV2Codec.Error, .forbiddenField("prompt"))
        }

        let nestedUnsafe = Data(#"{"schemaVersion":2,"integration":"codex","eventKind":"activity.observed","observedAt":"2027-01-15T08:00:00Z","idempotencyKey":"codex-0123456789abcdef","externalSessionKey":"session-1","workingDirectory":"/tmp/codepulse","parserVersion":"1","integrationVersion":"1","metadata":{"content":"do not store me"}}"#.utf8)
        XCTAssertThrowsError(try DeveloperEventV2Codec.decode(nestedUnsafe)) { error in
            XCTAssertEqual(error as? DeveloperEventV2Codec.Error, .forbiddenField("content"))
        }
    }

    func testReceiverRejectsOversizedClockSkewAndDeduplicates() throws {
        let root = try temporaryDirectory()
        let inbox = DeveloperEventV2Inbox(paths: DeveloperToolIntegrationPaths(applicationSupportDirectory: root))
        let event = makeEvent()
        let data = try DeveloperEventV2Codec.encode(event)

        XCTAssertEqual(try inbox.receive(data, now: now), .accepted)
        XCTAssertEqual(try inbox.receive(data, now: now), .duplicate)
        XCTAssertEqual(inbox.pendingEventURLs().count, 1)

        XCTAssertThrowsError(try inbox.receive(Data(repeating: 0, count: DeveloperToolIntegrationLimits.maximumEventBytes + 1), now: now)) { error in
            XCTAssertEqual(error as? DeveloperEventV2ValidationError, .eventTooLarge)
        }
        let future = makeEvent(idempotencyKey: "future-0123456789abcdef", observedAt: now.addingTimeInterval(DeveloperToolIntegrationLimits.maximumFutureSkew + 1))
        XCTAssertThrowsError(try inbox.receive(DeveloperEventV2Codec.encode(future), now: now)) { error in
            XCTAssertEqual(error as? DeveloperEventV2ValidationError, .timestampInFuture)
        }
        XCTAssertThrowsError(try inbox.receive(data, allowedIntegrations: [.openCode], now: now)) { error in
            XCTAssertEqual(error as? DeveloperEventV2ValidationError, .integrationNotAllowed(.codex))
        }
        XCTAssertEqual(inbox.pendingReceiptURLs().count, 5)
    }

    func testReceiverReceiptsPersistEveryOutcomeWithoutInputContent() throws {
        let root = try temporaryDirectory()
        let paths = DeveloperToolIntegrationPaths(applicationSupportDirectory: root)
        let inbox = DeveloperEventV2Inbox(paths: paths, fingerprintSalt: Data(repeating: 7, count: 32))
        let event = makeEvent()
        let encoded = try DeveloperEventV2Codec.encode(event)
        XCTAssertEqual(try inbox.receive(encoded, now: now), .accepted)
        XCTAssertEqual(try inbox.receive(encoded, now: now), .duplicate)
        XCTAssertThrowsError(try inbox.receive(Data(#"{"prompt":"must never persist"}"#.utf8), now: now))

        let receipts = try inbox.pendingReceiptURLs().map { try inbox.readReceipt(from: $0) }
        XCTAssertTrue(receipts.contains(where: { $0.status == .accepted }))
        XCTAssertTrue(receipts.contains(where: { $0.status == .duplicate }))
        XCTAssertTrue(receipts.contains(where: { $0.status == .rejected }))
        let accepted = try XCTUnwrap(receipts.first(where: { $0.status == .accepted }))
        XCTAssertEqual(accepted.integration, .codex)
        XCTAssertEqual(accepted.eventFingerprint, inbox.fingerprint(for: event.idempotencyKey))
        XCTAssertEqual(receipts.first(where: { $0.status == .rejected })?.rejectionCode, "schema-rejected")
        let receiptText = try inbox.pendingReceiptURLs().compactMap { String(data: try Data(contentsOf: $0), encoding: .utf8) }.joined()
        XCTAssertFalse(receiptText.contains("must never persist"))
        XCTAssertFalse(receiptText.contains(event.idempotencyKey))
    }

    func testFingerprintsAreInstallationScoped() {
        let key = "codex-0123456789abcdef"
        XCTAssertNotEqual(
            DeveloperEventV2Fingerprint.make(for: key, salt: Data(repeating: 1, count: 32)),
            DeveloperEventV2Fingerprint.make(for: key, salt: Data(repeating: 2, count: 32))
        )
    }

    func testDiagnosticsAreBoundedRedactedAndRestartSafe() throws {
        let root = try temporaryDirectory()
        let paths = DeveloperToolIntegrationPaths(applicationSupportDirectory: root)
        let inbox = DeveloperEventV2Inbox(paths: paths)
        let consumer = DeveloperEventV2Consumer(inbox: inbox)
        var state = AppState()

        let first = makeEvent()
        XCTAssertEqual(try inbox.receive(DeveloperEventV2Codec.encode(first), now: now), .accepted)
        XCTAssertTrue(consumer.processPending(state: &state, now: now))
        XCTAssertEqual(state.developerEventDiagnostics?.entries.last?.status, .accepted)

        try FileManager.default.createDirectory(at: paths.eventV2InboxURL, withIntermediateDirectories: true)
        try DeveloperEventV2Codec.encode(first).write(
            to: paths.eventV2InboxURL.appendingPathComponent("same-event-again.json"),
            options: .atomic
        )
        try Data(#"{"prompt":"private hook content"}"#.utf8).write(
            to: paths.eventV2InboxURL.appendingPathComponent("malformed.json"),
            options: .atomic
        )
        XCTAssertTrue(consumer.processPending(state: &state, now: now.addingTimeInterval(1)))
        XCTAssertTrue(state.developerEventDiagnostics?.entries.contains(where: { $0.status == .duplicate }) == true)
        XCTAssertTrue(state.developerEventDiagnostics?.entries.contains(where: { $0.status == .rejected && $0.rejectionCode == "schema-rejected" }) == true)

        for index in 0...DeveloperEventDiagnosticsJournal.maximumEntries {
            let event = makeEvent(idempotencyKey: "event-\(index)-0123456789abcdef")
            _ = try inbox.receive(DeveloperEventV2Codec.encode(event), now: now)
            _ = consumer.processPending(state: &state, now: now)
        }
        XCTAssertEqual(state.developerEventDiagnostics?.entries.count, DeveloperEventDiagnosticsJournal.maximumEntries)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let saved = try encoder.encode(state)
        let savedText = try XCTUnwrap(String(data: saved, encoding: .utf8))
        XCTAssertFalse(savedText.contains("private hook content"))
        XCTAssertFalse(savedText.contains("prompt"))
        XCTAssertFalse(savedText.contains(first.idempotencyKey))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restarted = try decoder.decode(AppState.self, from: saved)
        XCTAssertEqual(restarted.developerEventDiagnostics, state.developerEventDiagnostics)
    }

    func testLegacyEventsNormalizeIntoV2WithoutRetainingLegacyEnvelope() throws {
        let legacy = DeveloperToolEvent(
            tool: .opencode,
            externalSessionID: "legacy-session",
            eventType: .sessionIdle,
            timestamp: now,
            workingDirectory: "/tmp/codepulse",
            model: "model",
            profile: "local"
        )
        let normalized = DeveloperEventV2(legacy: legacy)
        XCTAssertEqual(normalized.integration, .openCode)
        XCTAssertEqual(normalized.eventKind, .sessionIdle)
        XCTAssertEqual(normalized.externalSessionKey, legacy.externalSessionID)
        XCTAssertEqual(normalized.serviceMode, "local")
        XCTAssertEqual(normalized.metadata?.sourceKind, "legacy-hook")
    }

    func testCanonicalCodexClaudeAndOpenCodeFixturesNormalize() throws {
        for (name, integration) in [
            ("codex-event-v2", DeveloperEventIntegration.codex),
            ("claude-code-event-v2", .claudeCode),
            ("opencode-event-v2", .openCode)
        ] {
            let url = try XCTUnwrap(Bundle.module.url(
                forResource: name,
                withExtension: "json",
                subdirectory: "developer-events-v2"
            ))
            let event = try DeveloperEventV2Validator.validateEncodedData(Data(contentsOf: url), now: now)
            XCTAssertEqual(event.integration, integration)
            XCTAssertFalse(event.externalSessionKey.isEmpty)
            XCTAssertNil(event.parentSessionKey)
        }
    }

    private func makeEvent(
        idempotencyKey: String = "codex-0123456789abcdef",
        observedAt: Date? = nil
    ) -> DeveloperEventV2 {
        DeveloperEventV2(
            integration: .codex,
            eventKind: .activityObserved,
            observedAt: observedAt ?? now,
            idempotencyKey: idempotencyKey,
            externalSessionKey: "session-1",
            workingDirectory: "/tmp/codepulse/./Sources/../Sources",
            model: "GPT-5.6",
            effort: "high",
            serviceMode: "priority",
            parserVersion: "1",
            integrationVersion: "1",
            metadata: DeveloperEventMetadataV2(adapterVersion: "1", eventSequence: 1, sourceKind: "hook")
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodePulseDeveloperEventV2Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
