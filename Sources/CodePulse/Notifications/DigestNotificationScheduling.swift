import Foundation
import UserNotifications

enum DigestNotificationAuthorization: Equatable {
    case notDetermined
    case denied
    case authorized

    init(status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional, .ephemeral:
            self = .authorized
        case .denied:
            self = .denied
        case .notDetermined:
            self = .notDetermined
        @unknown default:
            self = .notDetermined
        }
    }
}

/// A value-type description of a pending local notification request. This
/// isolates the deterministic scheduling logic from the macOS notification
/// daemon so it can be tested with fakes.
struct DigestNotificationRequest: Equatable {
    let identifier: String
    let title: String
    let body: String
    let fireDate: Date
    let userInfo: [String: String]
}

/// Forwards notification-center delivery events to the coordinator without
/// exposing UserNotifications types.
protocol LocalNotificationDelivering: AnyObject {
    /// Called when a pending request fires while the app is running. Returns
    /// whether the system should present the request.
    func willPresent(request: DigestNotificationRequest) async -> Bool
}

/// System-facing notification surface. The coordinator depends on this
/// protocol only, so scheduling logic is testable without the real daemon.
protocol LocalNotificationScheduling: AnyObject {
    var deliveryDelegate: LocalNotificationDelivering? { get set }

    func authorization() async -> DigestNotificationAuthorization
    func requestAuthorization() async -> Bool
    func add(_ request: DigestNotificationRequest) async throws
    func removePending(withIdentifiers identifiers: [String])
    func pendingRequests() async -> [DigestNotificationRequest]
}

/// Production implementation backed by UNUserNotificationCenter.
final class SystemLocalNotificationScheduler: NSObject, LocalNotificationScheduling, UNUserNotificationCenterDelegate {
    weak var deliveryDelegate: LocalNotificationDelivering?

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        center.delegate = self
    }

    func authorization() async -> DigestNotificationAuthorization {
        let settings = await center.notificationSettings()
        return DigestNotificationAuthorization(status: settings.authorizationStatus)
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func add(_ request: DigestNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.userInfo = request.userInfo
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: request.fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let native = UNNotificationRequest(
            identifier: request.identifier,
            content: content,
            trigger: trigger
        )
        try await center.add(native)
    }

    func removePending(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func pendingRequests() async -> [DigestNotificationRequest] {
        let pending = await center.pendingNotificationRequests()
        return pending.compactMap { request in
            guard let fireDate = fireDate(for: request) else { return nil }
            return DigestNotificationRequest(
                identifier: request.identifier,
                title: request.content.title,
                body: request.content.body,
                fireDate: fireDate,
                userInfo: request.content.userInfo as? [String: String] ?? [:]
            )
        }
    }

    private func fireDate(for request: UNNotificationRequest) -> Date? {
        guard let trigger = request.trigger as? UNCalendarNotificationTrigger else { return nil }
        return trigger.nextTriggerDate()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let request = notification.request
        let mapped = DigestNotificationRequest(
            identifier: request.identifier,
            title: request.content.title,
            body: request.content.body,
            fireDate: notification.date,
            userInfo: request.content.userInfo as? [String: String] ?? [:]
        )
        Task {
            let shouldPresent = await deliveryDelegate?.willPresent(request: mapped) ?? false
            completionHandler(shouldPresent ? [.banner, .list, .sound] : [])
        }
    }
}
