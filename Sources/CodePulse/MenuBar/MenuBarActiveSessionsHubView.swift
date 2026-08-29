import SwiftUI

struct MenuBarSessionPresentation: Identifiable, Equatable {
    let session: ActiveSession
    let workspaceID: UUID?
    let workspaceName: String?
    let projectName: String
    let developerToolLabel: String?

    var id: UUID { session.id }

    var phaseTitle: String {
        switch session.phase {
        case .running: return "Running"
        case .paused: return "Paused"
        case .finishing: return "Finishing"
        case .idle: return "Idle"
        }
    }

    static func sorted(state: AppState) -> [Self] {
        let projects = Dictionary(uniqueKeysWithValues: state.projects.map { ($0.id, $0) })
        let workspaces = Dictionary(uniqueKeysWithValues: state.workspaces.map { ($0.id, $0) })
        return state.activeSessions.map { session in
            let project = session.projectID.flatMap { projects[$0] }
            let workspace = project.flatMap { workspaces[$0.workspaceID] }
            var toolNames = Set(session.developerToolContexts.map { $0.tool.title })
            if let metadata = session.automationMetadata {
                for claim in metadata.claims {
                    if case .developerTool(let tool, _) = claim.source { toolNames.insert(tool.title) }
                }
                if case .developerTool(let tool, _) = metadata.startedBySource { toolNames.insert(tool.title) }
            }
            let label = toolNames.isEmpty ? nil : toolNames.sorted().joined(separator: " + ")
            return Self(
                session: session,
                workspaceID: workspace?.id,
                workspaceName: workspace?.name,
                projectName: session.projectName.flatMap { $0.isEmpty ? nil : $0 } ?? "No Project",
                developerToolLabel: label
            )
        }.sorted { lhs, rhs in
            let lhsWorkspace = lhs.workspaceName ?? "\u{10FFFF}"
            let rhsWorkspace = rhs.workspaceName ?? "\u{10FFFF}"
            let workspaceOrder = lhsWorkspace.localizedCaseInsensitiveCompare(rhsWorkspace)
            if workspaceOrder != .orderedSame { return workspaceOrder == .orderedAscending }
            if lhs.workspaceID != rhs.workspaceID {
                return (lhs.workspaceID?.uuidString ?? "\u{10FFFF}") < (rhs.workspaceID?.uuidString ?? "\u{10FFFF}")
            }
            let projectOrder = lhs.projectName.localizedCaseInsensitiveCompare(rhs.projectName)
            if projectOrder != .orderedSame { return projectOrder == .orderedAscending }
            if lhs.session.startedAt != rhs.session.startedAt { return lhs.session.startedAt < rhs.session.startedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

struct MenuBarActiveSessionsHubView: View {
    @EnvironmentObject private var store: SessionStore
    let selectSession: (UUID) -> Void
    let newSession: () -> Void

    private var rows: [MenuBarSessionPresentation] {
        MenuBarSessionPresentation.sorted(state: store.state)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                MenuBarAppIcon()
                VStack(alignment: .leading, spacing: 1) {
                    Text("CodePulse").font(.headline.weight(.semibold))
                    Text("Active Sessions").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: newSession) {
                    Label("New Session…", systemImage: "plus")
                }
                .disabled(store.state.activeSessions.count >= ConcurrentSessionLimits.maximumActiveSessions)
                .accessibilityIdentifier("new-session-button")
            }

            let counts = store.activeSessionCounts
            Text("\(counts.total) sessions · \(counts.running) running · \(counts.paused) paused · \(counts.finishing) finishing")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("active-session-count")

            if store.state.activeSessions.count >= ConcurrentSessionLimits.maximumActiveSessions {
                Label("Session limit reached (16)", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVStack(alignment: .leading, spacing: 8, pinnedViews: [.sectionHeaders]) {
                ForEach(groupedRows, id: \.id) { group in
                    Section {
                        ForEach(group.rows) { row in
                            sessionRow(row)
                        }
                    } header: {
                        Text(group.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(store.menuBarAccessibilityText)
        .accessibilityIdentifier("active-sessions-hub")
    }

    private struct SessionGroup {
        let id: String
        let title: String
        var rows: [MenuBarSessionPresentation]
    }

    private var groupedRows: [SessionGroup] {
        var groups: [SessionGroup] = []
        for row in rows {
            let title = row.workspaceName ?? "No Project"
            let id = row.workspaceID?.uuidString ?? "no-project"
            if groups.last?.id == id {
                groups[groups.count - 1].rows.append(row)
            } else {
                groups.append(SessionGroup(id: id, title: title, rows: [row]))
            }
        }
        return groups
    }

    private func sessionRow(_ row: MenuBarSessionPresentation) -> some View {
        Button { selectSession(row.id) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.projectName).font(.subheadline.weight(.semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        if let tool = row.developerToolLabel { Text(tool) }
                        Text(row.session.type.title)
                        Text(row.phaseTitle)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(CodePulseFormatting.menuBarDuration(store.elapsedDuration(for: row.id)))
                    .font(.system(.caption, design: .monospaced).weight(.medium))
                    .monospacedDigit()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(9)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityLabel(row))
        .accessibilityIdentifier("active-session-row-\(row.id.uuidString.lowercased())")
    }

    private func rowAccessibilityLabel(_ row: MenuBarSessionPresentation) -> String {
        [
            row.projectName,
            row.workspaceName.map { "\($0) workspace" },
            row.developerToolLabel,
            row.session.type.title,
            row.phaseTitle,
            CodePulseFormatting.duration(store.elapsedDuration(for: row.id), includeSeconds: false)
        ].compactMap { $0 }.joined(separator: ", ")
    }
}
