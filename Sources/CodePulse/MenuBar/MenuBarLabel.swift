import SwiftUI

enum MenuBarLabelPresentation {
    static func text(state: AppState, now: Date) -> String {
        if state.activeSessions.count > 1 { return "\(state.activeSessions.count) sessions" }
        guard let session = state.activeSessions.first else { return "Code" }
        let duration = CodePulseFormatting.menuBarDuration(session.activeDuration(at: now))
        switch state.settings.menuBarDisplay {
        case .projectAndTimer:
            if let projectName = session.projectName, !projectName.isEmpty {
                return "\(projectName) · \(duration)"
            }
            return duration
        case .timerOnly, .iconOnly:
            return duration
        }
    }

    static func shouldRenderText(state: AppState) -> Bool {
        if state.activeSessions.count > 1 {
            return state.settings.menuBarDisplay != .iconOnly
        }
        switch state.activeSessions.first?.phase ?? .idle {
        case .idle:
            return state.settings.idleAppearance == .code
        case .running, .paused, .finishing:
            return state.settings.menuBarDisplay != .iconOnly
        }
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        let phase = store.state.activeSessions.first?.phase ?? .idle
        let symbol = store.state.activeSessions.count > 1
            ? "circle.fill"
            : (phase == .paused ? "pause.fill" : (phase == .idle ? "circle" : "circle.fill"))

        HStack(spacing: 4) {
            Image(systemName: symbol)
            if shouldShowText {
                Text(labelText)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var shouldShowText: Bool {
        MenuBarLabelPresentation.shouldRenderText(state: store.state)
    }

    private var labelText: String {
        MenuBarLabelPresentation.text(state: store.state, now: store.now)
    }

    private var accessibilityText: String {
        store.menuBarAccessibilityText
    }
}
