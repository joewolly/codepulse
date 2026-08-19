import Foundation
import XCTest
@testable import CodePulse

final class InsightsPresentationTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 1
        return calendar
    }()

    func testSummaryLayoutUsesTwoByTwoAtMinimumAndFourAcrossAtDefault() {
        XCTAssertEqual(InsightsPresentation.summaryColumnCount(for: 740), 2)
        XCTAssertEqual(InsightsPresentation.summaryColumnCount(for: 799), 2)
        XCTAssertEqual(InsightsPresentation.summaryColumnCount(for: 800), 4)
        XCTAssertEqual(InsightsPresentation.summaryColumnCount(for: 880), 4)
    }

    func testActivityBucketChoiceKeepsAllTimeThresholdAtFortyFiveDays() {
        XCTAssertFalse(
            InsightsPresentation.usesWeeklyActivityBuckets(
                timeframe: .allTime,
                dailyBucketCount: 45
            )
        )
        XCTAssertTrue(
            InsightsPresentation.usesWeeklyActivityBuckets(
                timeframe: .allTime,
                dailyBucketCount: 46
            )
        )
        XCTAssertTrue(
            InsightsPresentation.usesWeeklyActivityBuckets(
                timeframe: .last90Days,
                dailyBucketCount: 1
            )
        )
        XCTAssertFalse(
            InsightsPresentation.usesWeeklyActivityBuckets(
                timeframe: .last30Days,
                dailyBucketCount: 30
            )
        )
    }

    func testWeeklyBucketsUseInjectedFirstWeekdayAndPreserveZeroIndependentGrouping() throws {
        let activity = [
            DailyActivity(date: date(year: 2024, month: 1, day: 1), duration: 3_600),
            DailyActivity(date: date(year: 2024, month: 1, day: 7), duration: 7_200),
            DailyActivity(date: date(year: 2024, month: 1, day: 8), duration: 10_800),
            DailyActivity(date: date(year: 2024, month: 1, day: 13), duration: 14_400)
        ]

        let buckets = InsightsPresentation.activityBuckets(
            activity: activity,
            timeframe: .last90Days,
            calendar: calendar
        )

        XCTAssertEqual(buckets.count, 2)
        XCTAssertEqual(buckets.map(\.duration), [10_800, 25_200])
        XCTAssertTrue(buckets.allSatisfy(\.isWeekly))
        XCTAssertEqual(buckets.first?.date, date(year: 2024, month: 1, day: 1))
        XCTAssertEqual(buckets.last?.date, date(year: 2024, month: 1, day: 8))
    }

    func testComparisonCopyIsSuppressedForAllTime() {
        XCTAssertEqual(
            InsightsPresentation.comparisonLabel(for: .thisWeek),
            "vs last week"
        )
        XCTAssertEqual(
            InsightsPresentation.comparisonLabel(for: .last90Days),
            "vs the previous 90 days"
        )
        XCTAssertNil(InsightsPresentation.comparisonLabel(for: .allTime))
    }

    func testVisualBoundsPreserveCanonicalOrderAndExposeOverflow() {
        let breakdowns = (0..<10).map {
            InsightsBreakdown(id: "project-\($0)", label: "Project \($0)", duration: Double(10 - $0))
        }
        let metadata = (0..<8).map {
            InsightsCountBreakdown(id: "model-\($0)", label: "Model \($0)", count: 8 - $0)
        }

        let projects = InsightsPresentation.boundedBreakdown(
            breakdowns,
            limit: InsightsPresentation.projectBreakdownLimit
        )
        let models = InsightsPresentation.boundedMetadata(
            metadata,
            limit: InsightsPresentation.modelBreakdownLimit
        )

        XCTAssertEqual(projects.visible.map(\.id), breakdowns.prefix(8).map(\.id))
        XCTAssertEqual(projects.overflow, 2)
        XCTAssertEqual(models.visible.map(\.id), metadata.prefix(6).map(\.id))
        XCTAssertEqual(models.overflow, 2)
        XCTAssertEqual(
            InsightsPresentation.outcomeLimits(isAllProjects: true).entries,
            1
        )
        XCTAssertEqual(
            InsightsPresentation.outcomeLimits(isAllProjects: false).entries,
            3
        )
    }

    func testGitPresentationKeepsNilDistinctFromExplicitZero() {
        XCTAssertEqual(InsightsPresentation.gitMetricText(nil), "Unavailable")
        XCTAssertEqual(InsightsPresentation.gitMetricText(0), "0")
        XCTAssertEqual(
            InsightsPresentation.unavailableGitTotalsCopy,
            "Detailed Git totals unavailable for these session snapshots."
        )
    }

    private func date(year: Int, month: Int, day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}
