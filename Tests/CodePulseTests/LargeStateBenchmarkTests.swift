#if CODEPULSE_BENCHMARKS
import Foundation
import XCTest
@testable import CodePulse

@MainActor
final class LargeStateBenchmarkTests: XCTestCase {
    func testLargeStateBenchmarks() throws {
        for sessionCount in [10_000, 50_000] {
            let state = LargeStateFixture.makeState(sessionCount: sessionCount)
            let calendar = benchmarkCalendar
            let referenceDate = LargeStateFixture.referenceDate
            let query = HistoryQuery(searchText: "fixture-model-2")

            let encode = timed {
                _ = try? LargeStateFixture.encodedData(for: state)
            }
            let encoded = try LargeStateFixture.encodedData(for: state)
            let decode = timed {
                _ = try? LargeStateFixture.decodedState(from: encoded)
            }

            let storeInit = timed {
                _ = SessionStore(
                    persistence: LargeStatePersistence(state),
                    clock: LargeStateClock(referenceDate),
                    calendar: calendar,
                    developerToolEventConsumer: LargeStateNoOpEventConsumer(),
                    automaticallyRefresh: false
                )
            }
            let store = SessionStore(
                persistence: LargeStatePersistence(state),
                clock: LargeStateClock(referenceDate),
                calendar: calendar,
                developerToolEventConsumer: LargeStateNoOpEventConsumer(),
                automaticallyRefresh: false
            )
            let historyQuery = timed {
                _ = store.historySessions(for: query, referenceDate: referenceDate)
            }
            let historyGrouping = timed {
                _ = store.historyGroups(for: HistoryQuery(), referenceDate: referenceDate)
            }
            let insights = timed {
                _ = InsightsCalculator.summary(
                    state: state,
                    calendar: calendar,
                    referenceDate: referenceDate,
                    timeframe: .allTime
                )
            }
            let summary = InsightsCalculator.summary(
                state: state,
                calendar: calendar,
                referenceDate: referenceDate,
                timeframe: .allTime
            )
            let csv = timed {
                _ = HistoryCSVExporter.data(for: state.completedSessions)
            }
            let markdown = timed {
                _ = InsightsMarkdownExporter.data(
                    summary: summary,
                    projectTitle: "All Projects",
                    calendar: calendar
                )
            }

            print([
                "M3-BENCH",
                "sessions=\(sessionCount)",
                "stateBytes=\(encoded.count)",
                "encodeMs=\(format(encode))",
                "decodeMs=\(format(decode))",
                "storeInitMs=\(format(storeInit))",
                "historyQueryMs=\(format(historyQuery))",
                "historyGroupingMs=\(format(historyGrouping))",
                "insightsMs=\(format(insights))",
                "csvMs=\(format(csv))",
                "markdownMs=\(format(markdown))"
            ].joined(separator: " "))
        }
    }

    private var benchmarkCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 1
        return calendar
    }

    private func timed(_ operation: () -> Void) -> TimeInterval {
        let start = DispatchTime.now().uptimeNanoseconds
        operation()
        let end = DispatchTime.now().uptimeNanoseconds
        return Double(end - start) / 1_000_000
    }

    private func format(_ value: TimeInterval) -> String {
        String(format: "%.2f", value)
    }
}
#endif
