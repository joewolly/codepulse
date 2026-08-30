import AppKit
import SwiftUI

enum MenuBarPopoverRoute: Equatable {
    case idle
    case soleSession(UUID)
    case activeSessionsHub
    case selectedSession(UUID)
    case newSession
}

struct MenuBarPopoverPresentation: Equatable {
    private(set) var selectedSessionID: UUID?
    private(set) var isPresentingNewSession = false

    mutating func selectSession(_ sessionID: UUID) {
        selectedSessionID = sessionID
        isPresentingNewSession = false
    }

    mutating func showNewSession(activeSessionIDs: [UUID]) {
        guard MenuBarNewSessionAvailability(activeSessionCount: activeSessionIDs.count).canStart else { return }
        isPresentingNewSession = true
        selectedSessionID = nil
    }

    mutating func closeNewSession() {
        isPresentingNewSession = false
    }

    mutating func didCreateSession() {
        isPresentingNewSession = false
        selectedSessionID = nil
    }

    mutating func clearSelection() {
        selectedSessionID = nil
    }

    mutating func reconcile(activeSessionIDs: [UUID]) {
        if activeSessionIDs.count <= 1 {
            selectedSessionID = nil
        } else if let selectedSessionID, !activeSessionIDs.contains(selectedSessionID) {
            self.selectedSessionID = nil
        }
        if activeSessionIDs.isEmpty ||
            !MenuBarNewSessionAvailability(activeSessionCount: activeSessionIDs.count).canStart {
            isPresentingNewSession = false
        }
    }

    func route(activeSessionIDs: [UUID]) -> MenuBarPopoverRoute {
        if isPresentingNewSession,
           !activeSessionIDs.isEmpty,
           MenuBarNewSessionAvailability(activeSessionCount: activeSessionIDs.count).canStart {
            return .newSession
        }
        if activeSessionIDs.count > 1,
           let selectedSessionID,
           activeSessionIDs.contains(selectedSessionID) {
            return .selectedSession(selectedSessionID)
        }
        switch activeSessionIDs.count {
        case 0: return .idle
        case 1: return .soleSession(activeSessionIDs[0])
        default: return .activeSessionsHub
        }
    }
}

struct MenuBarNewSessionAvailability: Equatable {
    let activeSessionCount: Int
    var canStart: Bool { activeSessionCount < ConcurrentSessionLimits.maximumActiveSessions }
    var capacityMessage: String? { canStart ? nil : "Session limit reached (16)" }
}

struct MenuBarPopoverView: View {
    static let standardWidth: CGFloat = 390
    private static let contentWidth: CGFloat = standardWidth - 32
    private static let exceptionalMaxHeight: CGFloat = 440

    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var windowCoordinator: AppWindowCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var presentation = MenuBarPopoverPresentation()

    private let onDismiss: (() -> Void)?
    private let onOpenInsights: (() -> Void)?

    init(onDismiss: (() -> Void)? = nil, onOpenInsights: (() -> Void)? = nil) {
        self.onDismiss = onDismiss
        self.onOpenInsights = onOpenInsights
    }

    var body: some View {
        let dismissPopover = onDismiss ?? { dismiss() }

        Group {
            if store.isInRecoveryMode || !store.state.activeSessions.isEmpty || store.lifecycleErrorMessage != nil {
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
        .onChange(of: store.state.activeSessions.map(\.id)) { sessionIDs in
            presentation.reconcile(activeSessionIDs: sessionIDs)
        }
    }

    @ViewBuilder
    private func popoverContent(dismissPopover: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let lifecycleErrorMessage = store.lifecycleErrorMessage,
               !store.isInRecoveryMode {
                MenuBarLifecycleErrorView(
                    message: scopedLifecycleErrorMessage(lifecycleErrorMessage),
                    dismiss: store.dismissLifecycleError
                )
                .padding(.bottom, 10)
            }

            if store.isInRecoveryMode {
                RecoveryUnavailablePopoverView {
                    windowCoordinator.showRecovery()
                }
            } else {
                routedContent

                Divider()
                    .padding(.vertical, 14)

                MenuBarFooterView(onDismiss: dismissPopover, onOpenInsights: onOpenInsights)
            }
        }
        .frame(width: Self.contentWidth, alignment: .leading)
        .padding(.horizontal, 16)
    }

    private func scopedLifecycleErrorMessage(_ message: String) -> String {
        guard let sessionID = store.lifecycleErrorSessionID,
              let session = store.state.activeSession(id: sessionID) else { return message }
        let name = session.projectName.flatMap { $0.isEmpty ? nil : $0 } ?? "No Project"
        return "\(name): \(message)"
    }

    @ViewBuilder
    private var routedContent: some View {
        let sessions = store.state.activeSessions
        switch presentation.route(activeSessionIDs: sessions.map(\.id)) {
        case .newSession:
            navigationHeader(title: "New Session") { presentation.closeNewSession() }
            MenuBarManualStartView(mode: .concurrent) { _ in
                presentation.didCreateSession()
            }
        case .selectedSession(let sessionID):
            if let session = store.state.activeSession(id: sessionID) {
            navigationHeader(title: session.projectName ?? "No Project") {
                    presentation.clearSelection()
                }
                sessionDetail(session)
            }
        case .idle:
            MenuBarIdleView()
        case .soleSession(let sessionID):
            if let session = store.state.activeSession(id: sessionID) {
                HStack {
                    Spacer()
                    Button { presentation.showNewSession(activeSessionIDs: sessions.map(\.id)) } label: {
                        Label("New Session…", systemImage: "plus")
                    }
                    .disabled(!MenuBarNewSessionAvailability(activeSessionCount: sessions.count).canStart)
                    .accessibilityIdentifier("new-session-button")
                }
                sessionDetail(session)
            }
        case .activeSessionsHub:
            MenuBarActiveSessionsHubView(
                selectSession: { presentation.selectSession($0) },
                newSession: { presentation.showNewSession(activeSessionIDs: sessions.map(\.id)) }
            )
        }
    }

    @ViewBuilder
    private func sessionDetail(_ session: ActiveSession) -> some View {
        switch session.phase {
        case .running, .paused:
            MenuBarActiveView(sessionID: session.id)
        case .finishing:
            MenuBarFinishingView(sessionID: session.id)
        case .idle:
            EmptyView()
        }
    }

    private func navigationHeader(title: String, back: @escaping () -> Void) -> some View {
        HStack {
            Button(action: back) {
                Label("Back to Active Sessions", systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("back-to-active-sessions")
            Spacer()
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.bottom, 10)
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
            .accessibilityHint("Dismisses this error without changing session state")
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
