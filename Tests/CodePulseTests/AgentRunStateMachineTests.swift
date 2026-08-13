import CodePulseIntegration
import Foundation
import XCTest
@testable import CodePulse

final class AgentRunStateMachineTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testReducerTransitionTableIsExplicitAndTerminalStatesIgnoreEvents() {
        let lifecycleKinds = DeveloperEventKindV2.allCases.filter { $0 != .integrationError }
        for state in AgentRunState.allCases {
            for kind in lifecycleKinds {
                let result = AgentRunStateReducer.reduce(
                    state: state,
                    eventKind: kind,
                    observedAt: start,
                    lastEventAt: start
                )
                if state == .ended || state == .orphaned || kind == .integrationError {
                    XCTAssertNil(result, "\(state) + \(kind)")
                    continue
                }
                switch kind {
                case .sessionEnded:
                    XCTAssertEqual(result, .ended, "\(state) + \(kind)")
                case .permissionRequested:
                    XCTAssertEqual(result, state == .awaitingPermission ? nil : .awaitingPermission, "\(state) + \(kind)")
                case .sessionStopped:
                    XCTAssertEqual(result, state == .reviewGrace ? nil : .reviewGrace, "\(state) + \(kind)")
                case .sessionIdle:
                    XCTAssertEqual(result, state == .waiting ? nil : .waiting, "\(state) + \(kind)")
                case .sessionStarted, .activityObserved:
                    XCTAssertEqual(result, state == .active ? nil : .active, "\(state) + \(kind)")
                case .integrationError:
                    XCTFail("Filtered above")
                }
            }
        }
        XCTAssertNil(AgentRunStateReducer.reduce(
            state: .active,
            eventKind: .activityObserved,
            observedAt: start.addingTimeInterval(-1),
            lastEventAt: start
        ))
    }

    func testNormalizedEventsMaterializeIntervalsAndSeparateMetrics() {
        var run = makeRun()
        XCTAssertTrue(AgentRunLifecycle.apply(event(.sessionStarted, at: 0), to: &run, reviewGrace: 180))
        XCTAssertTrue(AgentRunLifecycle.apply(event(.permissionRequested, at: 60), to: &run, reviewGrace: 180))
        XCTAssertTrue(AgentRunLifecycle.apply(event(.activityObserved, at: 120), to: &run, reviewGrace: 180))
        XCTAssertTrue(AgentRunLifecycle.apply(event(.sessionStopped, at: 180), to: &run, reviewGrace: 180))
        XCTAssertTrue(AgentRunLifecycle.advanceTime(in: &run, now: start.addingTimeInterval(400), staleAfter: 900))

        XCTAssertEqual(run.agentMetadata?.state, .waiting)
        XCTAssertEqual(run.intervals.map(\.state), [.active, .waiting, .active, .reviewGrace, .waiting])
        let metrics = AgentRunLifecycle.timingMetrics(for: run, at: start.addingTimeInterval(400))
        XCTAssertEqual(metrics.agentRuntime, 120, accuracy: 0.001)
        XCTAssertEqual(metrics.reviewGrace, 180, accuracy: 0.001)
        XCTAssertEqual(metrics.waiting, 100, accuracy: 0.001)
        XCTAssertEqual(metrics.eligibleActive, 300, accuracy: 0.001)
        XCTAssertEqual(metrics.elapsed, 400, accuracy: 0.001)

        XCTAssertTrue(AgentRunLifecycle.apply(event(.sessionEnded, at: 500), to: &run, reviewGrace: 180))
        XCTAssertEqual(run.agentMetadata?.state, .ended)
        XCTAssertEqual(run.endedAt, start.addingTimeInterval(500))
        XCTAssertTrue(run.intervals.allSatisfy { !$0.isOpen })
    }

    func testReviewGraceDefaultsToThreeMinutesAndIsCancelledByLifecycleEvents() throws {
        let decoder = JSONDecoder()
        let legacySettings = try decoder.decode(CodePulseSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(legacySettings.agentReviewGraceSeconds, 180)

        var run = makeRun()
        XCTAssertTrue(AgentRunLifecycle.apply(event(.sessionStarted, at: 0), to: &run, reviewGrace: 180))
        XCTAssertTrue(AgentRunLifecycle.apply(event(.sessionStopped, at: 10), to: &run, reviewGrace: 180))
        XCTAssertEqual(run.agentMetadata?.reviewGraceDeadline, start.addingTimeInterval(190))
        XCTAssertTrue(AgentRunLifecycle.apply(event(.permissionRequested, at: 100), to: &run, reviewGrace: 180))
        XCTAssertEqual(run.agentMetadata?.state, .awaitingPermission)
        XCTAssertNil(run.agentMetadata?.reviewGraceDeadline)
        XCTAssertTrue(AgentRunLifecycle.apply(event(.activityObserved, at: 110), to: &run, reviewGrace: 180))
        XCTAssertEqual(run.agentMetadata?.state, .active)

        XCTAssertTrue(AgentRunLifecycle.apply(event(.sessionStopped, at: 200), to: &run, reviewGrace: 180))
        XCTAssertTrue(AgentRunLifecycle.advanceTime(in: &run, now: start.addingTimeInterval(380), staleAfter: 900))
        XCTAssertEqual(run.agentMetadata?.state, .waiting)
        XCTAssertEqual(run.intervals.last?.startedAt, start.addingTimeInterval(380))
    }

    func testRelaunchReconciliationOrphansStaleRunsWithoutInventingActiveTime() {
        var active = makeRun()
        XCTAssertTrue(AgentRunLifecycle.apply(event(.sessionStarted, at: 0), to: &active, reviewGrace: 180))
        XCTAssertTrue(AgentRunLifecycle.advanceTime(in: &active, now: start.addingTimeInterval(901), staleAfter: 900))
        XCTAssertEqual(active.agentMetadata?.state, .orphaned)
        XCTAssertEqual(active.endedAt, start)
        XCTAssertEqual(AgentRunLifecycle.timingMetrics(for: active, at: start.addingTimeInterval(901)).agentRuntime, 0)

        var stopped = makeRun()
        XCTAssertTrue(AgentRunLifecycle.apply(event(.sessionStarted, at: 0), to: &stopped, reviewGrace: 180))
        XCTAssertTrue(AgentRunLifecycle.apply(event(.sessionStopped, at: 10), to: &stopped, reviewGrace: 180))
        XCTAssertTrue(AgentRunLifecycle.advanceTime(in: &stopped, now: start.addingTimeInterval(4 * 60 * 60), staleAfter: 900))
        XCTAssertEqual(stopped.agentMetadata?.state, .orphaned)
        XCTAssertEqual(stopped.endedAt, start.addingTimeInterval(190))
        let metrics = AgentRunLifecycle.timingMetrics(for: stopped, at: start.addingTimeInterval(4 * 60 * 60))
        XCTAssertEqual(metrics.reviewGrace, 180, accuracy: 0.001)
        XCTAssertEqual(metrics.waiting, 0, accuracy: 0.001)
    }

    func testAgentRunMetadataRoundTripsWithoutBreakingExistingRuns() throws {
        let agentRun = makeRun()
        let manual = Run(activityID: UUID(), kind: .manual, startedAt: start, intervals: [Interval(state: .active, startedAt: start)])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(Run.self, from: encoder.encode(agentRun)), agentRun)
        XCTAssertNil(try decoder.decode(Run.self, from: encoder.encode(manual)).agentMetadata)
    }

    private func makeRun() -> Run {
        Run(
            activityID: UUID(),
            kind: .agent,
            startedAt: start,
            agentMetadata: AgentRunMetadata(
                integration: .codex,
                sessionFingerprint: "fingerprint",
                lastEventAt: start
            )
        )
    }

    private func event(_ kind: DeveloperEventKindV2, at offset: TimeInterval) -> DeveloperEventV2 {
        DeveloperEventV2(
            integration: .codex,
            eventKind: kind,
            observedAt: start.addingTimeInterval(offset),
            idempotencyKey: "event-\(kind.rawValue)-\(offset)-0123456789",
            externalSessionKey: "session",
            workingDirectory: "/tmp/codepulse",
            parserVersion: "1",
            integrationVersion: "1"
        )
    }
}
