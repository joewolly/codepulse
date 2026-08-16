import Combine
import Foundation

/// Minimal state surface the digest coordinator needs from the app.
@MainActor
protocol DigestStateProviding: AnyObject {
    var digestAppState: AppState { get }
    var calendar: Calendar { get }
    var isInRecoveryMode: Bool { get }
}

@MainActor
final class DigestNotificationCoordinator: ObservableObject, LocalNotificationDelivering {
    @Published private(set) var authorizationStatus: DigestNotificationAuthorization = .notDetermined

    private let stateProvider: DigestStateProviding
    private let notifications: LocalNotificationScheduling
    private let ledger: DigestDeliveryLedgerStoring
    private let clock: SessionClock
    private var timer: Timer?

    static let pendingRequestPrefix = "codepulse-digest."
    static let userInfoPeriodStartKey = "periodStart"

    init(
        stateProvider: DigestStateProviding,
        notifications: LocalNotificationScheduling,
        ledger: DigestDeliveryLedgerStoring,
        clock: SessionClock = SystemSessionClock()
    ) {
        self.stateProvider = stateProvider
        self.notifications = notifications
        self.ledger = ledger
        self.clock = clock
    }

    deinit {
        timer?.invalidate()
    }

    func start() {
        guard timer == nil else { return }
        notifications.deliveryDelegate = self
        schedulePass()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.schedulePass()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Called when the user explicitly toggles a digest in Settings. Only this
    /// path requests notification authorization; launch-time scheduling never
    /// nags for permission.
    func handleDigestToggled(_ kind: DigestKind, enabled: Bool) async {
        if enabled {
            let status = await notifications.authorization()
            authorizationStatus = status
            if status == .notDetermined {
                _ = await notifications.requestAuthorization()
            }
        }
        await runSchedulingPass()
    }

    func refreshAuthorizationStatus() async {
        authorizationStatus = await notifications.authorization()
    }

    func schedulePass() {
        Task { @MainActor in
            await runSchedulingPass()
        }
    }

    func runSchedulingPass() async {
        for kind in DigestKind.allCases {
            await runPass(for: kind)
        }
    }

    // MARK: - Delivery

    func willPresent(request: DigestNotificationRequest) async -> Bool {
        guard request.identifier.hasPrefix(Self.pendingRequestPrefix) else { return false }
        await runSchedulingPass()
        return true
    }

    // MARK: - Per-kind scheduling

    private func runPass(for kind: DigestKind) async {
        guard !stateProvider.isInRecoveryMode else { return }

        let settings = stateProvider.digestAppState.settings.digests
        let identifier = Self.requestIdentifier(kind)
        guard settings.isEnabled(kind) else {
            notifications.removePending(withIdentifiers: [identifier])
            return
        }

        let status = await notifications.authorization()
        authorizationStatus = status
        guard status == .authorized else {
            if status == .denied {
                notifications.removePending(withIdentifiers: [identifier])
            }
            return
        }

        let calendar = stateProvider.calendar
        let now = clock.now
        let period = DigestPeriodCalculator.completedPeriod(kind: kind, referenceDate: now, calendar: calendar)
        guard let due = DigestPeriodCalculator.nextDeliveryDate(
            kind: kind,
            after: period.interval.end,
            settings: settings,
            calendar: calendar
        ) else { return }

        if now >= due {
            await handleOverdue(kind: kind, period: period, due: due, calendar: calendar)
        }
        await ensureScheduled(kind: kind, settings: settings, calendar: calendar)
    }

    private func handleOverdue(
        kind: DigestKind,
        period: DigestPeriod,
        due: Date,
        calendar: Calendar
    ) async {
        let identifier = Self.requestIdentifier(kind)
        let periodID = DigestIdentity.periodIdentifier(periodStart: period.interval.start, calendar: calendar)
        guard ledger.lastDeliveredPeriodIdentifier(for: kind) != periodID else { return }

        let pending = await notifications.pendingRequests()
        if let existing = pending.first(where: { $0.identifier == identifier }) {
            if calendar.isDate(existing.fireDate, equalTo: due, toGranularity: .minute) {
                // The request for this due date never fired (Mac asleep, app
                // relaunched past the minute). Deliver it now instead.
                notifications.removePending(withIdentifiers: [identifier])
                await deliverNow(kind: kind, period: period, calendar: calendar)
                ledger.recordDelivery(periodIdentifier: periodID, for: kind)
            } else {
                // A later request is pending; the due request already fired
                // and was presented by the system.
                ledger.recordDelivery(periodIdentifier: periodID, for: kind)
            }
        } else if ledger.lastScheduledDueIdentifier(for: kind) ==
            DigestIdentity.dueIdentifier(date: due, calendar: calendar) {
            // The pending request fired while CodePulse was not running.
            ledger.recordDelivery(periodIdentifier: periodID, for: kind)
        } else {
            // Nothing was ever scheduled for this due date (for example a
            // fresh enable): deliver the completed period now.
            await deliverNow(kind: kind, period: period, calendar: calendar)
            ledger.recordDelivery(periodIdentifier: periodID, for: kind)
        }
    }

    private func ensureScheduled(kind: DigestKind, settings: DigestSettings, calendar: Calendar) async {
        let identifier = Self.requestIdentifier(kind)
        guard let due = DigestPeriodCalculator.nextDeliveryDate(
            kind: kind,
            after: clock.now,
            settings: settings,
            calendar: calendar
        ) else { return }

        let pending = await notifications.pendingRequests()
        if let existing = pending.first(where: { $0.identifier == identifier }),
           calendar.isDate(existing.fireDate, equalTo: due, toGranularity: .minute) {
            return
        }

        let contentPeriod = DigestPeriodCalculator.completedPeriod(
            kind: kind,
            referenceDate: due,
            calendar: calendar
        )
        let summary = DigestCalculator.summary(
            state: stateProvider.digestAppState,
            period: contentPeriod,
            referenceDate: due,
            calendar: calendar
        )
        let content = DigestComposer.content(summary: summary, calendar: calendar)
        try? await notifications.add(DigestNotificationRequest(
            identifier: identifier,
            title: content.title,
            body: content.body,
            fireDate: due,
            userInfo: [
                Self.userInfoPeriodStartKey:
                    DigestIdentity.periodIdentifier(periodStart: contentPeriod.interval.start, calendar: calendar)
            ]
        ))
        ledger.recordScheduledDue(
            identifier: DigestIdentity.dueIdentifier(date: due, calendar: calendar),
            for: kind
        )
    }

    private func deliverNow(kind: DigestKind, period: DigestPeriod, calendar: Calendar) async {
        let summary = DigestCalculator.summary(
            state: stateProvider.digestAppState,
            period: period,
            referenceDate: clock.now,
            calendar: calendar
        )
        let content = DigestComposer.content(summary: summary, calendar: calendar)
        let periodID = DigestIdentity.periodIdentifier(periodStart: period.interval.start, calendar: calendar)
        try? await notifications.add(DigestNotificationRequest(
            identifier: "\(Self.pendingRequestPrefix)\(kind.rawValue).delivered.\(periodID)",
            title: content.title,
            body: content.body,
            fireDate: clock.now,
            userInfo: [Self.userInfoPeriodStartKey: periodID]
        ))
    }

    static func requestIdentifier(_ kind: DigestKind) -> String {
        "\(pendingRequestPrefix)\(kind.rawValue)"
    }
}

private extension DigestSettings {
    func isEnabled(_ kind: DigestKind) -> Bool {
        switch kind {
        case .daily: return dailyEnabled
        case .weekly: return weeklyEnabled
        }
    }
}
