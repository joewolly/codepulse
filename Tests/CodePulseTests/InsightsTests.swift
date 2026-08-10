import Foundation
import XCTest
@testable import CodePulse

private final class InsightsTestClock: SessionClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

@MainActor
final class InsightsTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 1
        return calendar
    }()

    func testCurrentWeekApportionsBoundaryPauseAndActiveSession() {
        let reference = date(year: 2023, month: 1, day: 4, hour: 13)
        let crossingDayStart = date(year: 2023, month: 1, day: 3, hour: 23, minute: 30)
        let crossingDay = CompletedSession(
            id: UUID(),
            projectID: UUID(),
            projectName: "CodePulse",
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: crossingDayStart,
            endedAt: date(year: 2023, month: 1, day: 4, hour: 1, minute: 30),
            pauseIntervals: [
                PauseInterval(
                    startedAt: date(year: 2023, month: 1, day: 3, hour: 23, minute: 45),
                    endedAt: date(year: 2023, month: 1, day: 4, hour: 0, minute: 15)
                )
            ]
        )
        let crossingWeek = CompletedSession(
            id: UUID(),
            projectID: UUID(),
            projectName: "Boundary",
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 1, hour: 23),
            endedAt: date(year: 2023, month: 1, day: 2, hour: 1),
            pauseIntervals: []
        )
        let previousWeek = CompletedSession(
            id: UUID(),
            projectID: UUID(),
            projectName: "Earlier",
            type: .planning,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2022, month: 12, day: 30, hour: 10),
            endedAt: date(year: 2022, month: 12, day: 30, hour: 12),
            pauseIntervals: []
        )
        let active = ActiveSession(
            projectID: nil,
            projectName: nil,
            type: .research,
            goal: nil,
            startedAt: date(year: 2023, month: 1, day: 4, hour: 12)
        )
        var state = AppState()
        state.completedSessions = [crossingDay, crossingWeek, previousWeek]
        state.activeSession = active

        let summary = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: reference
        )

        XCTAssertEqual(summary.interval.start, date(year: 2023, month: 1, day: 2, hour: 0))
        XCTAssertEqual(summary.totalDuration, 12_600, accuracy: 0.001) // 1.5h + 1h + 1h
        XCTAssertEqual(summary.comparisonDuration, 10_800, accuracy: 0.001) // 1h boundary + 2h prior
        XCTAssertEqual(summary.difference, 1_800, accuracy: 0.001)

        XCTAssertEqual(summary.projectBreakdown.map(\.label), ["CodePulse", "Boundary", "No Project"])
        XCTAssertEqual(summary.projectBreakdown.map(\.duration), [5_400, 3_600, 3_600])
        XCTAssertEqual(summary.typeBreakdown.map(\.label), ["Coding", "Research"])

        let jan3 = summary.dailyActivity.first { calendar.isDate($0.date, inSameDayAs: crossingDayStart) }
        let jan4 = summary.dailyActivity.first { calendar.isDate($0.date, inSameDayAs: reference) }
        XCTAssertEqual(try XCTUnwrap(jan3?.duration), 900, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(jan4?.duration), 8_100, accuracy: 0.001) // 1h 15m crossing-day + 1h active
    }

    func testPreviousWeekAndEmptyStateAreDeterministic() {
        let reference = date(year: 2023, month: 1, day: 4, hour: 13)
        let session = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2022, month: 12, day: 28, hour: 10),
            endedAt: date(year: 2022, month: 12, day: 28, hour: 11),
            pauseIntervals: []
        )
        var state = AppState()
        state.completedSessions = [session]

        let lastWeek = InsightsCalculator.summary(
            state: state,
            calendar: calendar,
            referenceDate: reference,
            timeframe: .lastWeek
        )
        XCTAssertEqual(lastWeek.totalDuration, 3_600, accuracy: 0.001)
        XCTAssertEqual(lastWeek.projectBreakdown.first?.label, "No Project")
        XCTAssertEqual(lastWeek.typeBreakdown.first?.label, "Coding")

        let empty = InsightsCalculator.summary(
            state: AppState(),
            calendar: calendar,
            referenceDate: reference
        )
        XCTAssertFalse(empty.hasActivity)
        XCTAssertTrue(empty.projectBreakdown.isEmpty)
        XCTAssertTrue(empty.typeBreakdown.isEmpty)
        XCTAssertEqual(empty.dailyActivity.count, 7)
        XCTAssertTrue(empty.dailyActivity.allSatisfy { $0.duration == 0 })

        let last30 = InsightsCalculator.summary(
            state: AppState(),
            calendar: calendar,
            referenceDate: reference,
            timeframe: .last30Days
        )
        XCTAssertEqual(last30.dailyActivity.count, 30)
    }

    func testLegacySessionTypeCountsAsCodingInInsights() throws {
        let reference = date(year: 2023, month: 1, day: 4, hour: 13)
        let session = CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: date(year: 2023, month: 1, day: 4, hour: 10),
            endedAt: date(year: 2023, month: 1, day: 4, hour: 11),
            pauseIntervals: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try JSONSerialization.jsonObject(with: encoder.encode(session)) as! [String: Any]
        object.removeValue(forKey: "type")
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(CompletedSession.self, from: data)

        var state = AppState()
        state.completedSessions = [legacy]
        let summary = InsightsCalculator.summary(state: state, calendar: calendar, referenceDate: reference)
        XCTAssertEqual(summary.typeBreakdown.first?.label, "Coding")
    }

    private func date(year: Int, month: Int, day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}
