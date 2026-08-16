import Foundation
import CodePulseIntegration
import XCTest
@testable import CodePulse

private final class DigestTestClock: SessionClock {
    var now: Date

    init(_ now: Date) {
        self.now = now
    }
}

private final class FakeNotificationScheduler: LocalNotificationScheduling {
    weak var deliveryDelegate: LocalNotificationDelivering?

    var authorizationResult: DigestNotificationAuthorization = .authorized
    private(set) var authorizationRequestCount = 0
    private(set) var addCount = 0
    private(set) var requests: [String: DigestNotificationRequest] = [:]
    private(set) var removedIdentifiers: [String] = []

    func authorization() async -> DigestNotificationAuthorization { authorizationResult }

    func requestAuthorization() async -> Bool {
        authorizationRequestCount += 1
        authorizationResult = .authorized
        return true
    }

    func add(_ request: DigestNotificationRequest) async throws {
        addCount += 1
        requests[request.identifier] = request
    }

    func removePending(withIdentifiers identifiers: [String]) {
        removedIdentifiers.append(contentsOf: identifiers)
        for identifier in identifiers {
            requests.removeValue(forKey: identifier)
        }
    }

    func pendingRequests() async -> [DigestNotificationRequest] {
        Array(requests.values)
    }
}

private final class FakeDeliveryLedger: DigestDeliveryLedgerStoring {
    var delivered: [String: String] = [:]
    var scheduledDue: [String: String] = [:]

    func lastDeliveredPeriodIdentifier(for kind: DigestKind) -> String? { delivered[kind.rawValue] }
    func lastScheduledDueIdentifier(for kind: DigestKind) -> String? { scheduledDue[kind.rawValue] }
    func recordDelivery(periodIdentifier: String, for kind: DigestKind) {
        delivered[kind.rawValue] = periodIdentifier
    }
    func recordScheduledDue(identifier: String, for kind: DigestKind) {
        scheduledDue[kind.rawValue] = identifier
    }
}

@MainActor
private final class DigestTestStateProvider: DigestStateProviding {
    var digestAppState: AppState
    let calendar: Calendar
    var isInRecoveryMode = false

    init(state: AppState, calendar: Calendar) {
        self.digestAppState = state
        self.calendar = calendar
    }
}

@MainActor
final class DigestNotificationCoordinatorTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 1
        return calendar
    }()

    private func makeCoordinator(
        state: AppState,
        clock: DigestTestClock,
        scheduler: FakeNotificationScheduler = FakeNotificationScheduler(),
        ledger: FakeDeliveryLedger = FakeDeliveryLedger()
    ) -> (DigestNotificationCoordinator, DigestTestStateProvider, FakeNotificationScheduler, FakeDeliveryLedger) {
        let provider = DigestTestStateProvider(state: state, calendar: calendar)
        let coordinator = DigestNotificationCoordinator(
            stateProvider: provider,
            notifications: scheduler,
            ledger: ledger,
            clock: clock
        )
        return (coordinator, provider, scheduler, ledger)
    }

    func testEnablingDailySchedulesNextDueRequestWithCompletedPeriodContent() async {
        let clock = DigestTestClock(date(year: 2023, month: 1, day: 4, hour: 8))
        var state = AppState()
        state.settings.digests.dailyEnabled = true
        state.completedSessions = [completedSession(
            startedAt: date(year: 2023, month: 1, day: 3, hour: 10),
            endedAt: date(year: 2023, month: 1, day: 3, hour: 11)
        )]
        let (coordinator, _, scheduler, _) = makeCoordinator(state: state, clock: clock)

        await coordinator.runSchedulingPass()

        let daily = try! XCTUnwrap(scheduler.requests["codepulse-digest.daily"])
        XCTAssertEqual(daily.fireDate, date(year: 2023, month: 1, day: 4, hour: 9))
        XCTAssertEqual(daily.title, "Your CodePulse day")
        XCTAssertEqual(daily.body, "1h 00m across 1 session, +1h 00m from the previous day. Coding was your top work type at 1h 00m.")
        XCTAssertEqual(daily.userInfo["periodStart"], "2023-01-03T00:00")
    }

    func testScheduledContentRefreshesWithoutChangingIdentityOrFireDate() async {
        let clock = DigestTestClock(date(year: 2023, month: 1, day: 2, hour: 9, minute: 1))
        var state = AppState()
        state.settings.digests.dailyEnabled = true
        let (coordinator, provider, scheduler, _) = makeCoordinator(state: state, clock: clock)

        await coordinator.runSchedulingPass()

        let original = try! XCTUnwrap(scheduler.requests["codepulse-digest.daily"])
        let initialAddCount = scheduler.addCount

        provider.digestAppState.completedSessions = [completedSession(
            startedAt: date(year: 2023, month: 1, day: 2, hour: 10),
            endedAt: date(year: 2023, month: 1, day: 2, hour: 11)
        )]
        clock.now = date(year: 2023, month: 1, day: 2, hour: 11, minute: 1)

        await coordinator.runSchedulingPass()

        let updated = try! XCTUnwrap(scheduler.requests["codepulse-digest.daily"])
        XCTAssertEqual(scheduler.requests.values.filter { $0.identifier == "codepulse-digest.daily" }.count, 1)
        XCTAssertEqual(updated.identifier, original.identifier)
        XCTAssertEqual(updated.fireDate, original.fireDate)
        XCTAssertNotEqual(updated.body, original.body)
        XCTAssertTrue(updated.body.contains("1h 00m across 1 session"))
        XCTAssertEqual(scheduler.addCount, initialAddCount + 1)
    }

    func testScheduledActiveSessionUsesCurrentTimeNotFutureFireDate() async {
        let clock = DigestTestClock(date(year: 2023, month: 1, day: 2, hour: 9, minute: 1))
        var state = AppState()
        state.settings.digests.dailyEnabled = true
        state.activeSession = ActiveSession(
            startedAt: date(year: 2023, month: 1, day: 2, hour: 9)
        )
        let (coordinator, _, scheduler, _) = makeCoordinator(state: state, clock: clock)

        await coordinator.runSchedulingPass()

        let daily = try! XCTUnwrap(scheduler.requests["codepulse-digest.daily"])
        XCTAssertTrue(daily.body.hasPrefix("1m across 1 session"))
        XCTAssertFalse(daily.body.contains("15h"))
    }

    func testEnablingWeeklySchedulesWeekdayAndTime() async {
        let clock = DigestTestClock(date(year: 2023, month: 1, day: 4, hour: 8))
        var state = AppState()
        state.settings.digests.weeklyEnabled = true
        state.settings.digests.weeklyWeekday = .friday
        state.settings.digests.weeklyTime = DigestDeliveryTime(hour: 17, minute: 30)
        let (coordinator, _, scheduler, _) = makeCoordinator(state: state, clock: clock)

        await coordinator.runSchedulingPass()

        let weekly = try! XCTUnwrap(scheduler.requests["codepulse-digest.weekly"])
        XCTAssertEqual(weekly.fireDate, date(year: 2023, month: 1, day: 6, hour: 17, minute: 30))
        XCTAssertEqual(weekly.title, "Your CodePulse week")
    }

    func testDisabledDigestRemovesPendingRequest() async {
        let clock = DigestTestClock(date(year: 2023, month: 1, day: 4, hour: 8))
        var state = AppState()
        state.settings.digests.dailyEnabled = true
        let (coordinator, provider, scheduler, _) = makeCoordinator(state: state, clock: clock)
        await coordinator.runSchedulingPass()
        XCTAssertNotNil(scheduler.requests["codepulse-digest.daily"])

        provider.digestAppState.settings.digests.dailyEnabled = false
        await coordinator.runSchedulingPass()
        XCTAssertNil(scheduler.requests["codepulse-digest.daily"])
        XCTAssertTrue(scheduler.removedIdentifiers.contains("codepulse-digest.daily"))
    }

    func testChangingTimeReplacesRequestWithoutDuplicates() async {
        let clock = DigestTestClock(date(year: 2023, month: 1, day: 4, hour: 8))
        var state = AppState()
        state.settings.digests.dailyEnabled = true
        let (coordinator, provider, scheduler, _) = makeCoordinator(state: state, clock: clock)
        await coordinator.runSchedulingPass()
        XCTAssertEqual(scheduler.requests.count, 1)

        provider.digestAppState.settings.digests.dailyTime = DigestDeliveryTime(hour: 10, minute: 0)
        await coordinator.runSchedulingPass()

        XCTAssertEqual(scheduler.requests.count, 1)
        let daily = try! XCTUnwrap(scheduler.requests["codepulse-digest.daily"])
        XCTAssertEqual(daily.fireDate, date(year: 2023, month: 1, day: 4, hour: 10))
    }

    func testDailyAndWeeklyOperateIndependently() async {
        let clock = DigestTestClock(date(year: 2023, month: 1, day: 4, hour: 8))
        var state = AppState()
        state.settings.digests.dailyEnabled = true
        state.settings.digests.weeklyEnabled = true
        state.settings.digests.weeklyWeekday = .friday
        let (coordinator, _, scheduler, _) = makeCoordinator(state: state, clock: clock)

        await coordinator.runSchedulingPass()

        XCTAssertNotNil(scheduler.requests["codepulse-digest.daily"])
        XCTAssertNotNil(scheduler.requests["codepulse-digest.weekly"])
        XCTAssertEqual(scheduler.requests.count, 2)
    }

    func testStableIdentifiersAcrossReschedules() async {
        let clock = DigestTestClock(date(year: 2023, month: 1, day: 4, hour: 8))
        var state = AppState()
        state.settings.digests.dailyEnabled = true
        let (coordinator, _, scheduler, _) = makeCoordinator(state: state, clock: clock)

        await coordinator.runSchedulingPass()
        await coordinator.runSchedulingPass()
        await coordinator.runSchedulingPass()

        XCTAssertEqual(scheduler.requests.count, 1)
        XCTAssertEqual(Set(scheduler.requests.keys), ["codepulse-digest.daily"])
        XCTAssertEqual(scheduler.addCount, 1)
    }

    func testAuthorizationDeniedIsFailSoft() async {
        let clock = DigestTestClock(date(year: 2023, month: 1, day: 4, hour: 8))
        var state = AppState()
        state.settings.digests.dailyEnabled = true
        let scheduler = FakeNotificationScheduler()
        scheduler.authorizationResult = .denied
        let (coordinator, _, _, _) = makeCoordinator(state: state, clock: clock, scheduler: scheduler)

        await coordinator.runSchedulingPass()

        XCTAssertTrue(scheduler.requests.isEmpty)
        XCTAssertEqual(coordinator.authorizationStatus, .denied)
        XCTAssertEqual(scheduler.authorizationRequestCount, 0)
    }

    func testNotDeterminedAtLaunchDoesNotRequestOrSchedule() async {
        let clock = DigestTestClock(date(year: 2023, month: 1, day: 4, hour: 8))
        var state = AppState()
        state.settings.digests.dailyEnabled = true
        let scheduler = FakeNotificationScheduler()
        scheduler.authorizationResult = .notDetermined
        let (coordinator, _, _, _) = makeCoordinator(state: state, clock: clock, scheduler: scheduler)

        await coordinator.runSchedulingPass()

        XCTAssertTrue(scheduler.requests.isEmpty)
        XCTAssertEqual(scheduler.authorizationRequestCount, 0)
    }

    func testUserToggleRequestsAuthorizationOnlyWhenNotDetermined() async {
        let clock = DigestTestClock(date(year: 2023, month: 1, day: 4, hour: 8))
        var state = AppState()
        state.settings.digests.dailyEnabled = true
        let scheduler = FakeNotificationScheduler()
        scheduler.authorizationResult = .notDetermined
        let (coordinator, _, _, _) = makeCoordinator(state: state, clock: clock, scheduler: scheduler)

        await coordinator.handleDigestToggled(.daily, enabled: true)

        XCTAssertEqual(scheduler.authorizationRequestCount, 1)
        XCTAssertNotNil(scheduler.requests["codepulse-digest.daily"])
    }

    func testUserToggleDoesNotRequestWhenAlreadyAuthorized() async {
        let clock = DigestTestClock(date(year: 2023, month: 1, day: 4, hour: 8))
        var state = AppState()
        state.settings.digests.dailyEnabled = true
        let scheduler = FakeNotificationScheduler()
        scheduler.authorizationResult = .authorized
        let (coordinator, _, _, _) = makeCoordinator(state: state, clock: clock, scheduler: scheduler)

        await coordinator.handleDigestToggled(.daily, enabled: true)

        XCTAssertEqual(scheduler.authorizationRequestCount, 0)
    }

    func testOverdueWithPendingRequestDeliversNowAndSchedulesNext() async {
        let clock = DigestTestClock(date(year: 2023, month: 1, day: 4, hour: 9, minute: 30))
        var state = AppState()
        state.settings.digests.dailyEnabled = true
        let (coordinator, _, scheduler, ledger) = makeCoordinator(state: state, clock: clock)
        // Simulate a request scheduled earlier for today 9:00.
        let pending = DigestNotificationRequest(
            identifier: "codepulse-digest.daily",
            title: "Your CodePulse day",
            body: "placeholder",
            fireDate: date(year: 2023, month: 1, day: 4, hour: 9),
            userInfo: ["periodStart": "2023-01-03T00:00"]
        )
        try! await scheduler.add(pending)

        await coordinator.runSchedulingPass()

        // The overdue request was removed and delivered immediately.
        XCTAssertTrue(scheduler.removedIdentifiers.contains("codepulse-digest.daily"))
        let delivered = scheduler.requests.values.filter { $0.identifier.contains(".delivered.") }
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(ledger.delivered["daily"], "2023-01-03T00:00")
        // The next delivery is scheduled for tomorrow 9:00.
        let next = try! XCTUnwrap(scheduler.requests["codepulse-digest.daily"])
        XCTAssertEqual(next.fireDate, date(year: 2023, month: 1, day: 5, hour: 9))
    }

    func testRelaunchDoesNotDuplicateDeliveredPeriod() async {
        let clock = DigestTestClock(date(year: 2023, month: 1, day: 4, hour: 9, minute: 30))
        var state = AppState()
        state.settings.digests.dailyEnabled = true
        let (coordinator, _, scheduler, ledger) = makeCoordinator(state: state, clock: clock)
        // The system delivered the 9:00 request while the app was away; the
        // ledger already records the period.
        ledger.recordDelivery(periodIdentifier: "2023-01-03T00:00", for: .daily)
        ledger.recordScheduledDue(identifier: "2023-01-04T09:00", for: .daily)

        await coordinator.runSchedulingPass()

        XCTAssertFalse(scheduler.requests.values.contains { $0.identifier.contains(".delivered.") })
        XCTAssertEqual(ledger.delivered["daily"], "2023-01-03T00:00")
        let next = try! XCTUnwrap(scheduler.requests["codepulse-digest.daily"])
        XCTAssertEqual(next.fireDate, date(year: 2023, month: 1, day: 5, hour: 9))
    }

    func testFreshEnableWithOverduePeriodDeliversImmediately() async {
        let clock = DigestTestClock(date(year: 2023, month: 1, day: 4, hour: 9, minute: 30))
        var state = AppState()
        state.settings.digests.dailyEnabled = true
        let (coordinator, _, scheduler, ledger) = makeCoordinator(state: state, clock: clock)

        await coordinator.runSchedulingPass()

        XCTAssertTrue(scheduler.requests.values.contains { $0.identifier.contains(".delivered.") })
        XCTAssertEqual(ledger.delivered["daily"], "2023-01-03T00:00")
    }

    func testWillPresentRecordsDeliveryAndSchedulesNext() async {
        let clock = DigestTestClock(date(year: 2023, month: 1, day: 4, hour: 9))
        var state = AppState()
        state.settings.digests.dailyEnabled = true
        let (coordinator, _, scheduler, ledger) = makeCoordinator(state: state, clock: clock)
        // The request was scheduled yesterday for today 9:00.
        ledger.recordScheduledDue(identifier: "2023-01-04T09:00", for: .daily)
        let request = DigestNotificationRequest(
            identifier: "codepulse-digest.daily",
            title: "Your CodePulse day",
            body: "placeholder",
            fireDate: date(year: 2023, month: 1, day: 4, hour: 9),
            userInfo: ["periodStart": "2023-01-03T00:00"]
        )

        let shouldPresent = await coordinator.willPresent(request: request)

        XCTAssertTrue(shouldPresent)
        XCTAssertEqual(ledger.delivered["daily"], "2023-01-03T00:00")
        XCTAssertFalse(scheduler.requests.values.contains { $0.identifier.contains(".delivered.") })
        let next = try! XCTUnwrap(scheduler.requests["codepulse-digest.daily"])
        XCTAssertEqual(next.fireDate, date(year: 2023, month: 1, day: 5, hour: 9))
    }

    func testWeeklyOverdueAcrossMultipleDaysSchedulesNextWeek() async {
        let clock = DigestTestClock(date(year: 2023, month: 1, day: 11, hour: 13))
        var state = AppState()
        state.settings.digests.weeklyEnabled = true
        let (coordinator, _, scheduler, ledger) = makeCoordinator(state: state, clock: clock)
        // A weekly request due Monday Jan 9 9:00 fired while the app was away.
        ledger.recordScheduledDue(identifier: "2023-01-09T09:00", for: .weekly)

        await coordinator.runSchedulingPass()

        XCTAssertEqual(ledger.delivered["weekly"], "2023-01-02T00:00")
        XCTAssertFalse(scheduler.requests.values.contains { $0.identifier.contains(".delivered.") })
        let next = try! XCTUnwrap(scheduler.requests["codepulse-digest.weekly"])
        XCTAssertEqual(next.fireDate, date(year: 2023, month: 1, day: 16, hour: 9))
    }

    func testRecoveryModeSkipsScheduling() async {
        let clock = DigestTestClock(date(year: 2023, month: 1, day: 4, hour: 8))
        var state = AppState()
        state.settings.digests.dailyEnabled = true
        let provider = DigestTestStateProvider(state: state, calendar: calendar)
        provider.isInRecoveryMode = true
        let scheduler = FakeNotificationScheduler()
        let coordinator = DigestNotificationCoordinator(
            stateProvider: provider,
            notifications: scheduler,
            ledger: FakeDeliveryLedger(),
            clock: clock
        )

        await coordinator.runSchedulingPass()

        XCTAssertTrue(scheduler.requests.isEmpty)
    }

    private func completedSession(startedAt: Date, endedAt: Date) -> CompletedSession {
        CompletedSession(
            id: UUID(),
            projectID: nil,
            projectName: nil,
            type: .coding,
            goal: nil,
            outcome: nil,
            startedAt: startedAt,
            endedAt: endedAt,
            pauseIntervals: []
        )
    }

    private func date(year: Int, month: Int, day: Int, hour: Int = 0, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}
