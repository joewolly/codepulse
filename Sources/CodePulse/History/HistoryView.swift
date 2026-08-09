import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var selectedSession: CompletedSession?
    @State private var sessionPendingDeletion: CompletedSession?

    var body: some View {
        Group {
            if store.historyGroups.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("No Sessions Yet")
                        .font(.headline)
                    Text("Saved coding sessions will appear here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.historyGroups) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                HistoryRow(session: session)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectedSession = session
                                    }
                                    .contextMenu {
                                        Button("View Details") {
                                            selectedSession = session
                                        }
                                        Divider()
                                        Button("Delete Session", role: .destructive) {
                                            sessionPendingDeletion = session
                                        }
                                    }
                            }
                        } header: {
                            HStack {
                                Text(CodePulseFormatting.day(group.id, calendar: store.calendar))
                                Spacer()
                                Text(CodePulseFormatting.duration(group.totalDuration))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("History")
        .sheet(item: $selectedSession) { session in
            SessionDetailView(session: session)
                .environmentObject(store)
        }
        .alert("Delete Session?", isPresented: Binding(
            get: { sessionPendingDeletion != nil },
            set: { if !$0 { sessionPendingDeletion = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let id = sessionPendingDeletion?.id {
                    store.deleteCompletedSession(id: id)
                }
                sessionPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                sessionPendingDeletion = nil
            }
        } message: {
            Text("This saved session will be removed from CodePulse.")
        }
        .frame(minWidth: 620, minHeight: 460)
    }
}

private struct HistoryRow: View {
    let session: CompletedSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.projectName ?? "Coding Session")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Text(CodePulseFormatting.duration(session.activeDuration))
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
            }

            Text("\(CodePulseFormatting.time(session.startedAt)) – \(CodePulseFormatting.time(session.endedAt))")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let goal = session.goal {
                Text(goal)
                    .font(.body)
                    .lineLimit(2)
            }
            if let outcome = session.outcome {
                Text(outcome)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens session details")
    }
}

private struct SessionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: SessionStore
    let session: CompletedSession
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(session.projectName ?? "Coding Session")
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                Button("Done") { dismiss() }
            }

            LabeledContent("Active Duration", value: CodePulseFormatting.duration(session.activeDuration, includeSeconds: true))
            LabeledContent("Started", value: CodePulseFormatting.time(session.startedAt))
            LabeledContent("Finished", value: CodePulseFormatting.time(session.endedAt))

            if let goal = session.goal {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Goal").font(.caption).foregroundStyle(.secondary)
                    Text(goal).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let outcome = session.outcome {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Outcome").font(.caption).foregroundStyle(.secondary)
                    Text(outcome).fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Button("Delete Session", role: .destructive) {
                showDeleteConfirmation = true
            }
        }
        .padding(24)
        .frame(width: 440, height: 360)
        .alert("Delete Session?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                store.deleteCompletedSession(id: session.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This saved session will be removed from CodePulse.")
        }
    }
}
