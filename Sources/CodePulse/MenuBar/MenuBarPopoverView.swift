import AppKit
import SwiftUI

struct MenuBarPopoverView: View {
    static let standardWidth: CGFloat = 390
    private static let contentWidth: CGFloat = standardWidth - 32
    private static let exceptionalMaxHeight: CGFloat = 440

    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var windowCoordinator: AppWindowCoordinator
    @Environment(\.dismiss) private var dismiss

    private let onDismiss: (() -> Void)?
    private let onOpenInsights: (() -> Void)?

    init(onDismiss: (() -> Void)? = nil, onOpenInsights: (() -> Void)? = nil) {
        self.onDismiss = onDismiss
        self.onOpenInsights = onOpenInsights
    }

    var body: some View {
        let dismissPopover = onDismiss ?? { dismiss() }

        Group {
            if store.isInRecoveryMode || store.phase == .finishing || store.lifecycleErrorMessage != nil {
                ScrollView(.vertical) {
                    popoverContent(dismissPopover: dismissPopover)
                }
                .frame(maxHeight: Self.exceptionalMaxHeight)
            } else {
                popoverContent(dismissPopover: dismissPopover)
            }
        }
        .frame(width: Self.standardWidth, alignment: .leading)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private func popoverContent(dismissPopover: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lifecycleErrorMessage = store.lifecycleErrorMessage,
               !store.isInRecoveryMode {
                MenuBarLifecycleErrorView(
                    message: lifecycleErrorMessage,
                    dismiss: store.dismissLifecycleError
                )
                .padding(.bottom, 10)
            }

            if store.isInRecoveryMode {
                RecoveryUnavailablePopoverView {
                    windowCoordinator.showRecovery()
                }
            } else {
                switch store.phase {
                case .idle:
                    MenuBarIdleView()
                case .running, .paused:
                    MenuBarActiveView()
                case .finishing:
                    MenuBarFinishingView()
                }

                Divider()
                    .padding(.vertical, 14)

                MenuBarFooterView(onDismiss: dismissPopover, onOpenInsights: onOpenInsights)
            }
        }
        .frame(width: Self.contentWidth, alignment: .leading)
        .padding(.horizontal, 16)
    }
}

private struct MenuBarLifecycleErrorView: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Label {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss lifecycle error")
            .accessibilityHint("Dismisses this save error without changing the current session")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.red.opacity(0.08))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.red.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct RecoveryUnavailablePopoverView: View {
    let showRecovery: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Saved data unavailable", systemImage: "lock.trianglebadge.exclamationmark")
                .font(.headline)

            Text("CodePulse is read-only until you restore a valid backup.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Recovery…", action: showRecovery)
                .buttonStyle(.borderedProminent)
                .tint(Color.accentColor)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .controlSize(.large)
                .accessibilityHint("Opens options to restore a backup or show the local data folder")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
