import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case workspaces
    case projects
    case automation
    case data

    var id: Self { self }

    var title: String {
        switch self {
        case .general: return "General"
        case .workspaces: return "Workspaces"
        case .projects: return "Projects"
        case .automation: return "Automation"
        case .data: return "Data"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .workspaces: return "square.grid.2x2"
        case .projects: return "folder"
        case .automation: return "bolt.circle"
        case .data: return "externaldrive"
        }
    }
}

enum SettingsStatusStyle {
    case success
    case neutral
    case warning
    case error

    var foreground: Color {
        switch self {
        case .success:
            return .green
        case .neutral:
            return .secondary
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}

struct SettingsStatusBadge: View {
    let text: String
    let style: SettingsStatusStyle
    let systemImage: String?

    init(
        _ text: String,
        style: SettingsStatusStyle,
        systemImage: String? = nil
    ) {
        self.text = text
        self.style = style
        self.systemImage = systemImage
    }

    var body: some View {
        Group {
            if let systemImage {
                Label(text, systemImage: systemImage)
            } else {
                Text(text)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(style.foreground)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(style.foreground.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}
