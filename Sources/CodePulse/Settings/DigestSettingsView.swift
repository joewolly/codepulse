import SwiftUI

/// Actionable Insights local digest settings. Both digest kinds are opt-in and
/// disabled by default; everything is computed locally and delivered as native
/// macOS notifications.
struct DigestSettingsView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var digestCoordinator: DigestNotificationCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Daily and weekly digests summarize your local CodePulse data — active time, sessions, projects, work types, and developer-tool participation. Everything is computed on this Mac and delivered as local macOS notifications; no data leaves your device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Send daily digest", isOn: dailyEnabledBinding)
                    .accessibilityLabel("Send daily digest")
                    .accessibilityHint("Requests a daily local notification summarizing the previous completed day")

                if store.state.settings.digests.dailyEnabled {
                    DigestTimeEditor(title: "Time", time: dailyTimeBinding)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Send weekly digest", isOn: weeklyEnabledBinding)
                    .accessibilityLabel("Send weekly digest")
                    .accessibilityHint("Requests a weekly local notification summarizing the previous completed week")

                if store.state.settings.digests.weeklyEnabled {
                    Picker("Day", selection: weeklyWeekdayBinding) {
                        ForEach(DigestWeekday.allCases) { weekday in
                            Text(weekdaySymbol(for: weekday)).tag(weekday)
                        }
                    }
                    .accessibilityLabel("Weekly digest delivery day")
                    .accessibilityValue(weekdaySymbol(for: store.state.settings.digests.weeklyWeekday))

                    DigestTimeEditor(title: "Time", time: weeklyTimeBinding)
                }
            }

            if let unavailableMessage {
                Text(unavailableMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            await digestCoordinator.refreshAuthorizationStatus()
        }
    }

    private var dailyEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.state.settings.digests.dailyEnabled },
            set: { value in
                store.updateSettings { $0.digests.dailyEnabled = value }
                Task { await digestCoordinator.handleDigestToggled(.daily, enabled: value) }
            }
        )
    }

    private var weeklyEnabledBinding: Binding<Bool> {
        Binding(
            get: { store.state.settings.digests.weeklyEnabled },
            set: { value in
                store.updateSettings { $0.digests.weeklyEnabled = value }
                Task { await digestCoordinator.handleDigestToggled(.weekly, enabled: value) }
            }
        )
    }

    private var dailyTimeBinding: Binding<DigestDeliveryTime> {
        Binding(
            get: { store.state.settings.digests.dailyTime },
            set: { value in
                store.updateSettings { $0.digests.dailyTime = value }
                Task { digestCoordinator.schedulePass() }
            }
        )
    }

    private var weeklyTimeBinding: Binding<DigestDeliveryTime> {
        Binding(
            get: { store.state.settings.digests.weeklyTime },
            set: { value in
                store.updateSettings { $0.digests.weeklyTime = value }
                Task { digestCoordinator.schedulePass() }
            }
        )
    }

    private var weeklyWeekdayBinding: Binding<DigestWeekday> {
        Binding(
            get: { store.state.settings.digests.weeklyWeekday },
            set: { value in
                store.updateSettings { $0.digests.weeklyWeekday = value }
                Task { digestCoordinator.schedulePass() }
            }
        )
    }

    private var unavailableMessage: String? {
        switch digestCoordinator.authorizationStatus {
        case .denied:
            return "Notifications are turned off for CodePulse. Allow notifications in System Settings to receive digests."
        case .notDetermined:
            if store.state.settings.digests.dailyEnabled || store.state.settings.digests.weeklyEnabled {
                return "Digests will be delivered once notifications are allowed."
            }
            return nil
        case .authorized:
            return nil
        }
    }

    private func weekdaySymbol(for weekday: DigestWeekday) -> String {
        store.calendar.weekdaySymbols[weekday.rawValue - 1]
    }
}

private struct DigestTimeEditor: View {
    let title: String
    @Binding var time: DigestDeliveryTime

    var body: some View {
        DatePicker(title, selection: dateBinding, displayedComponents: .hourAndMinute)
            .accessibilityLabel("\(title) for digest delivery")
    }

    private var dateBinding: Binding<Date> {
        Binding(
            get: {
                var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
                components.hour = time.hour
                components.minute = time.minute
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { date in
                let components = Calendar.current.dateComponents([.hour, .minute], from: date)
                time = DigestDeliveryTime(
                    hour: components.hour ?? time.hour,
                    minute: components.minute ?? time.minute
                )
            }
        )
    }
}
