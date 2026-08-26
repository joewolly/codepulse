import AppKit
import SwiftUI

struct MenuBarFooterView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var windowCoordinator: AppWindowCoordinator

    let onDismiss: () -> Void
    let onOpenInsights: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            let todayDuration = CodePulseFormatting.menuBarDuration(store.todayTotal())
            Text("Today: \(todayDuration)")
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel("Today's focus time")
                .accessibilityValue(todayDuration)

            Spacer(minLength: 4)

            HStack(spacing: 8) {
                Button("Dashboard") {
                    windowCoordinator.showWorkspaceDashboard()
                    onDismiss()
                    activateApp()
                }
                .buttonStyle(.link)
                .accessibilityLabel("Workspace Dashboard")
                .accessibilityValue("Workspace Dashboard")
                .accessibilityHint("Opens a read-only summary of the selected Workspace")
                .accessibilityIdentifier("workspace-dashboard-entry")

                Button("History") {
                    windowCoordinator.showHistory()
                    onDismiss()
                    activateApp()
                }
                .buttonStyle(.link)
                .accessibilityLabel("History")
                .accessibilityValue("History")
                .accessibilityHint("Opens saved sessions")

                Button("Insights") {
                    if let onOpenInsights {
                        onOpenInsights()
                    } else {
                        windowCoordinator.showInsights()
                    }
                    onDismiss()
                    activateApp()
                }
                .buttonStyle(.link)
                .accessibilityLabel("Insights")
                .accessibilityValue("Insights")
                .accessibilityHint("Opens local coding insights")

                MenuBarSettingsButton(onDismiss: onDismiss)

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.link)
                .accessibilityLabel("Quit CodePulse")
                .accessibilityValue("Quit CodePulse")
                .accessibilityHint("Quits CodePulse")
            }
            .font(.caption)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
        }
        .accessibilityElement(children: .contain)
    }

    private func activateApp() {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct MenuBarSettingsButton: View {
    @EnvironmentObject private var windowCoordinator: AppWindowCoordinator
    let onDismiss: () -> Void

    var body: some View {
        Button("Settings") {
            windowCoordinator.showSettings()
            onDismiss()
        }
        .buttonStyle(.link)
        .accessibilityLabel("Settings")
        .accessibilityValue("Settings")
        .accessibilityHint("Opens CodePulse settings")
    }
}
