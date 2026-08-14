import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RecoveryView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var restoreCandidate: BackupRestoreCandidate?
    @State private var restoreError: String?

    private let onRecovered: () -> Void
    private let onDismiss: () -> Void

    init(onRecovered: @escaping () -> Void, onDismiss: @escaping () -> Void) {
        self.onRecovered = onRecovered
        self.onDismiss = onDismiss
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("CodePulse Couldn't Read Its Saved Data", systemImage: "exclamationmark.triangle")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            Text("Your existing state file has been left unchanged. CodePulse is in read-only recovery mode until you choose a valid backup.")
                .fixedSize(horizontal: false, vertical: true)

            Text("Restore a backup to continue using CodePulse, or open the data folder to preserve and inspect the original file yourself.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let restoreError {
                Label(restoreError, systemImage: "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Recovery error: \(restoreError)")
            }

            HStack(spacing: 12) {
                Button("Restore Backup…") {
                    chooseBackup()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Selects and reviews a valid CodePulse backup before replacing the unreadable saved data")

                Button("Show Data Folder") {
                    showDataFolder()
                }
                .buttonStyle(.bordered)
                .accessibilityHint("Reveals the local CodePulse data folder without changing its contents")

                Spacer()

                Button("Quit CodePulse") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.link)
                .accessibilityLabel("Quit CodePulse")
                .accessibilityHint("Quits CodePulse without changing the unreadable saved data")
            }
        }
        .padding(30)
        .frame(
            minWidth: 620,
            idealWidth: 620,
            maxWidth: 620,
            minHeight: 300,
            alignment: .topLeading
        )
        .alert(
            "Restore CodePulse Backup?",
            isPresented: Binding(
                get: { restoreCandidate != nil },
                set: { if !$0 { restoreCandidate = nil } }
            )
        ) {
            Button("Restore Backup", role: .destructive) {
                guard let candidate = restoreCandidate else { return }
                restoreCandidate = nil
                do {
                    _ = try store.restoreBackup(candidate)
                    onRecovered()
                } catch {
                    restoreError = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {
                restoreCandidate = nil
            }
        } message: {
            Text(restoreConfirmationMessage)
        }
        .onExitCommand {
            onDismiss()
        }
    }

    private var restoreConfirmationMessage: String {
        guard let candidate = restoreCandidate else {
            return "Select a CodePulse backup to review."
        }

        let preview = candidate.preview
        var lines = [
            "Format: \(preview.format) v\(preview.version)",
            "Exported: \(preview.exportedAt.formatted(date: .abbreviated, time: .shortened))",
            "\(preview.projectCount) \(preview.projectCount == 1 ? "project" : "projects")",
            "\(preview.completedSessionCount) \(preview.completedSessionCount == 1 ? "saved session" : "saved sessions")"
        ]
        if preview.includesActiveSession {
            lines.append("1 active session")
        }
        return lines.joined(separator: "\n")
    }

    private func chooseBackup() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Review Backup"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            restoreError = nil
            restoreCandidate = try store.inspectBackup(at: url)
        } catch {
            restoreError = error.localizedDescription
        }
    }

    private func showDataFolder() {
        guard let stateURL = (store.persistence as? StateRestoring)?.fileURL else {
            return
        }

        let folderURL = stateURL.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: stateURL.path) {
            NSWorkspace.shared.selectFile(
                stateURL.path,
                inFileViewerRootedAtPath: folderURL.path
            )
        } else {
            NSWorkspace.shared.open(folderURL)
        }
    }
}
