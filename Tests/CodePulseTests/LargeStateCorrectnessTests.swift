import Foundation
import CodePulseIntegration
import XCTest
@testable import CodePulse

@MainActor
final class LargeStateCorrectnessTests: XCTestCase {
    func testTenThousandSessionStateRemainsCorrectAcrossHistoryInsightsAndExports() {
        assertLargeState(sessionCount: 10_000)
    }

    func testFiftyThousandSessionStateRemainsCorrectAcrossHistoryInsightsAndExports() {
        assertLargeState(sessionCount: 50_000)
    }

    func testLongContentFixtureStaysWithinPersistedLimitsAndRoundTrips() throws {
        let state = LargeStateFixture.makeLongContentState()
        let project = try XCTUnwrap(state.projects.first)
        let session = try XCTUnwrap(state.completedSessions.first)
        let preset = try XCTUnwrap(state.sessionPresets.first)
        let rule = try XCTUnwrap(state.automationRules.first)

        XCTAssertLessThanOrEqual(project.name.count, 200)
        XCTAssertLessThanOrEqual(session.goal?.count ?? 0, 4_096)
        XCTAssertLessThanOrEqual(session.outcome?.count ?? 0, 4_096)
        XCTAssertLessThanOrEqual(preset.name.count, 200)
        XCTAssertLessThanOrEqual(preset.goal?.count ?? 0, 4_096)
        XCTAssertLessThanOrEqual(rule.name.count, 200)
        XCTAssertNotNil(session.githubContext?.pullRequest)
        XCTAssertNotNil(session.developerToolContexts.first?.model)
        XCTAssertGreaterThan(LargeStateFixture.longRecoveryError.count, 200)
        XCTAssertGreaterThan(LargeStateFixture.longRecoveryPath.count, 200)
        XCTAssertEqual(
            try LargeStateFixture.decodedState(from: LargeStateFixture.encodedData(for: state)),
            state
        )
    }

    private func assertLargeState(sessionCount: Int) {
        let state = LargeStateFixture.makeState(sessionCount: sessionCount)
        let persistence = LargeStatePersistence(state)
        let store = SessionStore(
            persistence: persistence,
            clock: LargeStateClock(LargeStateFixture.referenceDate),
            calendar: largeStateCalendar,
            developerToolEventConsumer: LargeStateNoOpEventConsumer(),
            automaticallyRefresh: false
        )

        XCTAssertEqual(store.state.completedSessions.count, sessionCount)

        let history = store.historySessions(for: HistoryQuery(), referenceDate: LargeStateFixture.referenceDate)
        XCTAssertEqual(history.count, sessionCount)
        XCTAssertTrue(history.indices.dropFirst().allSatisfy { index in
            let previous = history[index - 1]
            let current = history[index]
            return previous.startedAt > current.startedAt ||
                (previous.startedAt == current.startedAt && previous.id.uuidString < current.id.uuidString)
        })

        let groups = store.historyGroups(for: HistoryQuery(), referenceDate: LargeStateFixture.referenceDate)
        XCTAssertEqual(groups.flatMap(\.sessions).count, sessionCount)
        XCTAssertTrue(groups.indices.dropFirst().allSatisfy { index in
            groups[index - 1].id > groups[index].id
        })

        let summary = InsightsCalculator.summary(
            state: state,
            calendar: largeStateCalendar,
            referenceDate: LargeStateFixture.referenceDate,
            timeframe: .allTime
        )
        XCTAssertEqual(summary.sessionCount, sessionCount)
        XCTAssertGreaterThan(summary.totalDuration, 0)
        XCTAssertGreaterThanOrEqual(summary.longestSessionDuration, summary.averageSessionDuration)
        XCTAssertTrue(summary.dailyActivity.allSatisfy { $0.duration >= 0 })

        let expectedDuration = history.reduce(into: 0) { total, session in
            total += session.activeDuration
        }
        XCTAssertEqual(summary.totalDuration, expectedDuration, accuracy: 0.001)

        let csv = HistoryCSVExporter.csv(for: history)
        XCTAssertEqual(csv.split(separator: "\r\n", omittingEmptySubsequences: true).count, sessionCount + 1)
        XCTAssertTrue(csv.hasPrefix(HistoryCSVExporter.columns.joined(separator: ",")))

        let markdown = InsightsMarkdownExporter.markdown(
            summary: summary,
            projectTitle: "All Projects",
            calendar: largeStateCalendar
        )
        XCTAssertTrue(markdown.hasPrefix("# CodePulse Report\n"))
        XCTAssertTrue(markdown.contains("## Summary"))

        let encoded = try? LargeStateFixture.encodedData(for: state)
        XCTAssertNotNil(encoded)
        XCTAssertEqual(try? LargeStateFixture.decodedState(from: encoded ?? Data()), state)
    }

    private var largeStateCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 1
        return calendar
    }
}

final class LargeStatePersistence: StatePersisting {
    var state: AppState

    init(_ state: AppState) {
        self.state = state
    }

    func load() -> AppState { state }

    func save(_ state: AppState) {
        self.state = state
    }
}

final class LargeStateClock: SessionClock {
    let now: Date

    init(_ now: Date) {
        self.now = now
    }
}

final class LargeStateNoOpEventConsumer: DeveloperToolEventConsuming {
    func drainPending(state: inout AppState, now: Date) -> [ValidatedDeveloperToolEvent] { [] }

    func attach(_ event: DeveloperToolEvent, to state: inout AppState, now: Date) -> Bool { false }

    func markProcessed(
        _ pending: ValidatedDeveloperToolEvent,
        in state: inout AppState,
        at date: Date
    ) -> Bool { false }

    func cleanup(_ pending: ValidatedDeveloperToolEvent) {}

    func processPending(state: inout AppState, now: Date) -> Bool { false }
}
