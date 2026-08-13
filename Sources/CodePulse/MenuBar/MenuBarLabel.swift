import SwiftUI

struct MenuBarLabel: View {
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        let phase = store.phase
        let symbol = phase == .paused ? "pause.fill" : (phase == .idle ? "circle" : "circle.fill")

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
        switch store.phase {
        case .idle:
            return store.state.settings.idleAppearance == .code
        case .running, .paused, .finishing:
            return store.state.settings.menuBarDisplay != .iconOnly
        }
    }

    private var labelText: String {
        switch store.phase {
        case .idle:
            return "Code"
        case .running, .paused, .finishing:
            let duration = CodePulseFormatting.menuBarDuration(store.elapsedDuration)
            switch store.state.settings.menuBarDisplay {
            case .projectAndTimer:
                if let projectName = store.activeSession?.projectName, !projectName.isEmpty {
                    return "\(projectName) · \(duration)"
                }
                return duration
            case .timerOnly, .iconOnly:
                return duration
            }
        }
    }

    private var accessibilityText: String {
        let automationStatus: String? = {
            guard let session = store.activeSession,
                  let metadata = session.automationMetadata,
                  metadata.controlEnabled else { return nil }
            return metadata.statusLabel(contexts: session.developerToolContexts)
        }()

        switch store.phase {
        case .idle:
            return "CodePulse, ready to start a session"
        case .running:
            return "CodePulse, running, \(CodePulseFormatting.duration(store.elapsedDuration, includeSeconds: true))" + (automationStatus.map { ", \($0)" } ?? "")
        case .paused:
            return "CodePulse, paused, \(CodePulseFormatting.duration(store.elapsedDuration, includeSeconds: true))" + (automationStatus.map { ", \($0)" } ?? "")
        case .finishing:
            return "CodePulse, session complete, \(CodePulseFormatting.duration(store.elapsedDuration, includeSeconds: true))"
        }
    }
}
