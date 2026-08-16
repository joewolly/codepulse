import Foundation

/// Deterministic identity strings for digest periods and due dates, formatted
/// in the local calendar. Identity is derived from the completed period, never
/// from wall-clock generation time, so a relaunch cannot re-notify a period
/// that was already delivered.
enum DigestIdentity {
    static func periodIdentifier(periodStart: Date, calendar: Calendar) -> String {
        identifier(for: periodStart, calendar: calendar)
    }

    static func dueIdentifier(date: Date, calendar: Calendar) -> String {
        identifier(for: date, calendar: calendar)
    }

    private static func identifier(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return formatter.string(from: date)
    }
}

/// Minimum persisted bookkeeping needed for reasonable delivery idempotency.
protocol DigestDeliveryLedgerStoring: AnyObject {
    func lastDeliveredPeriodIdentifier(for kind: DigestKind) -> String?
    func lastScheduledDueIdentifier(for kind: DigestKind) -> String?
    func recordDelivery(periodIdentifier: String, for kind: DigestKind)
    func recordScheduledDue(identifier: String, for kind: DigestKind)
}

/// UserDefaults-backed ledger. Kept out of the AppState file so delivery
/// bookkeeping never touches the critical session/persistence path and never
/// travels through backups.
final class UserDefaultsDigestDeliveryLedger: DigestDeliveryLedgerStoring {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func lastDeliveredPeriodIdentifier(for kind: DigestKind) -> String? {
        defaults.dictionary(forKey: Self.deliveredKey)?[kind.rawValue] as? String
    }

    func lastScheduledDueIdentifier(for kind: DigestKind) -> String? {
        defaults.dictionary(forKey: Self.scheduledDueKey)?[kind.rawValue] as? String
    }

    func recordDelivery(periodIdentifier: String, for kind: DigestKind) {
        var stored = defaults.dictionary(forKey: Self.deliveredKey) ?? [:]
        stored[kind.rawValue] = periodIdentifier
        defaults.set(stored, forKey: Self.deliveredKey)
    }

    func recordScheduledDue(identifier: String, for kind: DigestKind) {
        var stored = defaults.dictionary(forKey: Self.scheduledDueKey) ?? [:]
        stored[kind.rawValue] = identifier
        defaults.set(stored, forKey: Self.scheduledDueKey)
    }

    private static let deliveredKey = "CodePulseDigestDelivered.v1"
    private static let scheduledDueKey = "CodePulseDigestScheduledDue.v1"
}
