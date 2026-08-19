import CodePulseIntegration
import SwiftUI

struct HistoryDetailPane: View {
    let session: CompletedSession?
    let calendar: Calendar
    let hasAnySessions: Bool
    let canClearFilters: Bool
    let clearFilters: () -> Void

    @State private var developerToolsExpanded = false

    var body: some View {
        Group {
            if let session {
                ScrollView(.vertical) {
                    HistorySessionDetail(
                        session: session,
                        calendar: calendar,
                        developerToolsExpanded: $developerToolsExpanded
                    )
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            } else if !hasAnySessions || canClearFilters {
                HistoryEmptyState(
                    hasAnySessions: hasAnySessions,
                    canClearFilters: canClearFilters,
                    clearFilters: clearFilters
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.left")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("Select a Session")
                        .font(.headline)
                    Text("Choose a saved session from the sidebar to inspect its details.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Select a session from the sidebar to inspect its details")
            }
        }
        .onChange(of: session?.id) { _ in
            developerToolsExpanded = false
        }
    }
}

private struct HistorySessionDetail: View {
    let session: CompletedSession
    let calendar: Calendar
    @Binding var developerToolsExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SessionSummaryCard(session: session, calendar: calendar)

            if HistoryDetailAvailability.hasJournal(session) {
                SessionJournalCard(session: session)
            }

            if let gitContext = session.gitContext {
                SessionGitCard(context: gitContext)
            }

            if !session.developerToolContexts.isEmpty {
                SessionDeveloperToolCard(
                    contexts: session.developerToolContexts,
                    isExpanded: $developerToolsExpanded
                )
            }

            if let githubContext = session.githubContext {
                SessionGitHubCard(context: githubContext)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Details for \(projectTitle) session")
    }

    private var projectTitle: String {
        session.projectName ?? "No Project"
    }
}

private struct HistoryDetailCard<Content: View>: View {
    let title: String
    let systemImage: String
    let content: Content

    init(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

private struct SessionSummaryCard: View {
    let session: CompletedSession
    let calendar: Calendar

    var body: some View {
        HistoryDetailCard(title: "Session Summary", systemImage: session.type.systemImage) {
            VStack(alignment: .leading, spacing: 7) {
                Text(session.projectName ?? "No Project")
                    .font(.title2.weight(.bold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Label(session.type.title, systemImage: session.type.systemImage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text(
                    "\(HistoryDateFormatting.fullDay(session.startedAt, calendar: calendar)) · " +
                    "\(CodePulseFormatting.time(session.startedAt)) – \(CodePulseFormatting.time(session.endedAt))"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Active Duration")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(CodePulseFormatting.duration(session.activeDuration, includeSeconds: true))
                        .font(.title3)
                        .monospacedDigit()
                }
                .padding(.top, 2)
            }
        }
    }
}

private struct SessionJournalCard: View {
    let session: CompletedSession

    var body: some View {
        HistoryDetailCard(title: "Journal", systemImage: "book") {
            VStack(alignment: .leading, spacing: 10) {
                if let goal = session.goal, MeaningfulText.exists(goal) {
                    DetailTextBlock(title: "Goal", text: goal)
                }

                if let outcome = session.outcome, MeaningfulText.exists(outcome) {
                    DetailTextBlock(title: "Outcome", text: outcome)
                }

                if HistoryDetailAvailability.needsFollowUp(session) {
                    Label(
                        "No outcome recorded · Edit session to close the loop",
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Needs Outcome. No outcome recorded.")
                }
            }
        }
    }
}

private struct SessionGitCard: View {
    let context: GitSessionContext

    var body: some View {
        HistoryDetailCard(title: "Git Context", systemImage: "arrow.triangle.branch") {
            VStack(alignment: .leading, spacing: 9) {
                HistoryDetailValueRow(label: "Repository", value: context.repositoryRoot)

                if let branch = context.branchDisplay {
                    HistoryDetailValueRow(label: "Branch", value: branch)
                }

                if let commits = HistoryGitFormatting.commitCount(context.commitCount) {
                    HistoryDetailValueRow(label: "Commits", value: commits)
                }

                if let changes = HistoryGitFormatting.changes(
                    filesChanged: context.filesChanged,
                    insertions: context.insertions,
                    deletions: context.deletions
                ) {
                    HistoryDetailValueRow(label: "Changes", value: changes)
                }

                if let head = context.headDisplay {
                    HistoryDetailValueRow(label: "HEAD", value: head)
                }
            }
        }
    }
}

private struct SessionDeveloperToolCard: View {
    let contexts: [DeveloperToolSessionContext]
    @Binding var isExpanded: Bool

    private var visibleContexts: [DeveloperToolSessionContext] {
        HistoryDeveloperToolPresentation.visibleContexts(contexts, isExpanded: isExpanded)
    }

    private var remainingCount: Int {
        HistoryDeveloperToolPresentation.remainingCount(contexts)
    }

    var body: some View {
        HistoryDetailCard(title: "Developer Tools", systemImage: "wrench.and.screwdriver") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(visibleContexts) { context in
                    DeveloperToolContextDetailRow(context: context)
                }

                if remainingCount > 0 {
                    Button {
                        isExpanded.toggle()
                    } label: {
                        Label(
                            isExpanded
                                ? "Show fewer developer tool contexts"
                                : "Show \(remainingCount) more developer tool contexts",
                            systemImage: isExpanded ? "chevron.up" : "chevron.down"
                        )
                    }
                    .buttonStyle(.link)
                    .accessibilityLabel(
                        isExpanded
                            ? "Show fewer developer tool contexts"
                            : "Show \(remainingCount) more developer tool contexts"
                    )
                }
            }
        }
    }
}

private struct DeveloperToolContextDetailRow: View {
    let context: DeveloperToolSessionContext

    private var modelAndProfile: String? {
        [context.model, context.profile]
            .compactMap { value in
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return value
            }
            .joined(separator: " · ")
            .nilIfEmpty
    }

    private var eventCountDescription: String {
        let noun = context.eventCount == 1 ? "activity event" : "activity events"
        return "\(context.eventCount) \(noun)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: context.tool.systemImage)
                    .foregroundStyle(.secondary)
                Text(context.tool.title)
                    .fontWeight(.semibold)
                if let modelAndProfile {
                    Text(modelAndProfile)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            .font(.subheadline)

            Text(
                "\(eventCountDescription) · " +
                "Activity span \(CodePulseFormatting.time(context.firstActivityAt)) to " +
                "\(CodePulseFormatting.time(context.lastActivityAt))"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            Text(context.endedAt == nil ? "End event not observed" : "Ended")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var values = [context.tool.title]
        if let modelAndProfile { values.append(modelAndProfile) }
        values.append(eventCountDescription)
        values.append(
            "Activity span \(CodePulseFormatting.time(context.firstActivityAt)) to " +
            CodePulseFormatting.time(context.lastActivityAt)
        )
        values.append(context.endedAt == nil ? "End event not observed" : "Ended")
        return values.joined(separator: ", ")
    }
}

private struct SessionGitHubCard: View {
    let context: GitHubSessionContext

    var body: some View {
        HistoryDetailCard(title: "GitHub Context", systemImage: "chevron.left.forwardslash.chevron.right") {
            GitHubContextView(context: context, compact: true, showsTitle: false)
        }
    }
}

private struct HistoryDetailValueRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label), \(value)")
    }
}

private struct DetailTextBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
