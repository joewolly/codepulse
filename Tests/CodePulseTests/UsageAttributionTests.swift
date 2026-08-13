import Foundation
import XCTest
@testable import CodePulse

final class UsageAttributionTests: XCTestCase {
    func testAttributionMatrixKeepsExactDelayedAmbiguousAndMissingSamplesDistinct() {
        let fixture = Fixture()
        let exact = fixture.sample(runID: fixture.run.id, workspaceID: fixture.workspace.id, observedAt: fixture.date("2026-08-13T12:00:00Z"), model: "gpt-5", provider: "openai")
        let delayed = fixture.sample(runID: nil, workspaceID: fixture.workspace.id, observedAt: fixture.date("2026-08-13T12:01:00Z"), model: "gpt-5", provider: "openai")
        let conflicting = fixture.sample(runID: fixture.run.id, workspaceID: UUID(), observedAt: fixture.date("2026-08-13T12:02:00Z"), model: nil, provider: nil)
        let missing = fixture.sample(runID: nil, workspaceID: nil, observedAt: fixture.date("2026-08-13T12:03:00Z"), model: nil, provider: nil)
        let graph = ActivityGraph(workspaces: [fixture.workspace], activities: [fixture.activity], runs: [fixture.run])

        let attributed = UsageAttributionService.attribute(samples: [exact, delayed, conflicting, missing], graph: graph)

        XCTAssertEqual(attributed[0].workspace?.id, fixture.workspace.id)
        XCTAssertEqual(attributed[0].activity?.id, fixture.activity.id)
        XCTAssertEqual(attributed[1].workspace?.id, fixture.workspace.id)
        XCTAssertNil(attributed[1].activity)
        XCTAssertNil(attributed[2].activity)
        XCTAssertNil(attributed[2].workspace)
        XCTAssertTrue(attributed[3].isUnassigned)
        XCTAssertEqual(attributed[3].value(for: .domain).label, "Unknown")
    }

    func testCustomWindowAggregatesTokensCostsDimensionsAndNonInflatedTiming() {
        let fixture = Fixture()
        let end = fixture.date("2026-08-13T13:00:00Z")
        let secondRun = Run(
            activityID: fixture.activity.id,
            kind: .agent,
            startedAt: fixture.date("2026-08-13T12:15:00Z"),
            endedAt: end,
            intervals: [
                Interval(state: .active, startedAt: fixture.date("2026-08-13T12:15:00Z"), endedAt: fixture.date("2026-08-13T12:45:00Z")),
                Interval(state: .waiting, startedAt: fixture.date("2026-08-13T12:45:00Z"), endedAt: end)
            ]
        )
        let cost = CalculatedUsageCost(
            amount: Decimal(string: "3.50")!,
            currency: "USD",
            provenance: CostCalculationProvenance(
                representation: .apiEquivalentEstimate,
                catalogVersion: 1,
                catalogEffectiveDate: fixture.date("2026-01-01T00:00:00Z"),
                catalogOrigin: .bundled,
                modelID: "gpt-5",
                serviceMode: nil,
                priceSourceURL: "https://example.test/rates",
                calculationMethod: "token-rates",
                confidence: "published",
                calculatedAt: end
            )
        )
        let sample = fixture.sample(
            runID: fixture.run.id,
            workspaceID: fixture.workspace.id,
            observedAt: fixture.date("2026-08-13T12:30:00Z"),
            model: "gpt-5",
            provider: "openai",
            tokens: UsageTokenCounts(input: 10, output: 5, cachedInput: 3),
            reportedCost: Decimal(string: "1.25"),
            calculatedCosts: [cost]
        )
        let state = AppState(
            activityGraph: ActivityGraph(workspaces: [fixture.workspace], activities: [fixture.activity], runs: [fixture.run, secondRun]),
            usageSamples: [sample]
        )
        let window = DateInterval(start: fixture.date("2026-08-13T12:00:00Z"), end: end)
        let report = UsageAttributionService.report(state: state, calendar: fixture.calendar, referenceDate: end, window: .custom(window))

        XCTAssertEqual(report.tokens.total, 18)
        XCTAssertEqual(report.costs, [
            UsageMoneyTotal(representation: .apiEquivalentEstimate, currency: "USD", amount: Decimal(string: "3.50")!),
            UsageMoneyTotal(representation: .providerReported, currency: "USD", amount: Decimal(string: "1.25")!)
        ])
        XCTAssertEqual(report.dimensions[.provider]?.first?.label, "openai")
        XCTAssertEqual(report.timing.agentRuntime, 5_400, accuracy: 0.001)
        XCTAssertEqual(report.timing.agentWaiting, 900, accuracy: 0.001)
        XCTAssertEqual(report.timing.combinedWallActive, 3_600, accuracy: 0.001)
    }

    func testCalendarWindowsRespectDayAndMonthBoundaries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        let reference = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 15))!

        let day = UsageAnalyticsWindow.day.interval(calendar: calendar, referenceDate: reference)
        let month = UsageAnalyticsWindow.month.interval(calendar: calendar, referenceDate: reference)

        XCTAssertEqual(day.start, calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!)
        XCTAssertEqual(day.duration, 82_800, accuracy: 0.001)
        XCTAssertEqual(month.start, calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!)
        XCTAssertEqual(month.end, calendar.date(from: DateComponents(year: 2026, month: 4, day: 1))!)
    }

    func testReconciliationRowsNeverExposeExternalSessionFingerprints() {
        let fixture = Fixture()
        let sample = UsageSample(
            integration: .codex,
            observedAt: fixture.date("2026-08-13T12:30:00Z"),
            sessionFingerprint: "private-session-fingerprint",
            runID: fixture.run.id,
            workspaceID: fixture.workspace.id,
            model: "gpt-5",
            tokens: UsageTokenCounts(input: 1)
        )
        let state = AppState(activityGraph: ActivityGraph(workspaces: [fixture.workspace], activities: [fixture.activity], runs: [fixture.run]), usageSamples: [sample])
        let report = UsageAttributionService.report(
            state: state,
            calendar: fixture.calendar,
            referenceDate: fixture.date("2026-08-13T13:00:00Z"),
            window: .day
        )

        XCTAssertEqual(report.reconciliation.first?.id, "sample-1")
        XCTAssertFalse(String(describing: report.reconciliation).contains("private-session-fingerprint"))
        XCTAssertEqual(report.reconciliation.first?.workspace, "Workspace")
        XCTAssertEqual(report.reconciliation.first?.activity, "Activity")
    }

    func testIndexedReportPreservesEveryLargeHistorySample() {
        let fixture = Fixture()
        let observedAt = fixture.date("2026-08-13T12:30:00Z")
        let samples = (0..<2_000).map { index in
            UsageSample(
                integration: index.isMultiple(of: 2) ? .codex : .opencode,
                observedAt: observedAt,
                runID: fixture.run.id,
                workspaceID: fixture.workspace.id,
                model: "gpt-5",
                provider: index.isMultiple(of: 2) ? nil : "openai",
                tokens: UsageTokenCounts(input: 1)
            )
        }
        let state = AppState(activityGraph: ActivityGraph(workspaces: [fixture.workspace], activities: [fixture.activity], runs: [fixture.run]), usageSamples: samples)
        let report = UsageAttributionService.report(state: state, calendar: fixture.calendar, referenceDate: fixture.date("2026-08-13T13:00:00Z"), window: .day)

        XCTAssertEqual(report.samples.count, 2_000)
        XCTAssertEqual(report.tokens.total, 2_000)
        XCTAssertEqual(report.dimensions[.integration]?.map(\.sampleCount).reduce(0, +), 2_000)
    }
}

private struct Fixture {
    let calendar = Calendar(identifier: .gregorian)
    let workspace = Workspace(name: "Workspace", createdAt: ISO8601DateFormatter().date(from: "2026-08-13T12:00:00Z")!, source: .manual)
    let activity: Activity
    let run: Run

    init() {
        let start = Self.makeDate("2026-08-13T12:00:00Z")
        let end = Self.makeDate("2026-08-13T13:00:00Z")
        activity = Activity(workspaceID: workspace.id, title: "Activity", workType: .review, domain: .documentation, createdAt: start)
        run = Run(
            activityID: activity.id,
            kind: .agent,
            startedAt: start,
            endedAt: end,
            intervals: [Interval(state: .active, startedAt: start, endedAt: end)]
        )
    }

    func sample(
        runID: UUID?,
        workspaceID: UUID?,
        observedAt: Date,
        model: String?,
        provider: String?,
        tokens: UsageTokenCounts = UsageTokenCounts(input: 1),
        reportedCost: Decimal? = nil,
        calculatedCosts: [CalculatedUsageCost] = []
    ) -> UsageSample {
        UsageSample(
            integration: .opencode,
            observedAt: observedAt,
            sessionFingerprint: "session-fingerprint",
            runID: runID,
            workspaceID: workspaceID,
            model: model,
            provider: provider,
            effort: "high",
            serviceMode: "default",
            tokens: tokens,
            providerReportedCost: reportedCost,
            providerReportedCurrency: reportedCost == nil ? nil : "USD",
            calculatedCosts: calculatedCosts
        )
    }

    func date(_ string: String) -> Date { Self.makeDate(string) }

    private static func makeDate(_ string: String) -> Date { ISO8601DateFormatter().date(from: string)! }
}
