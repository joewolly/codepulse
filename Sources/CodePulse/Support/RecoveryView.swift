import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RecoveryView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var restoreCandidate: BackupRestoreCandidate?
    @State private var restoreError: String?

    private let onRecovered: () -> Void
    private let onDismiss: () -> Void
    private let onCheckForUpdates: (() -> Void)?

    init(
        onRecovered: @escaping () -> Void,
        onDismiss: @escaping () -> Void,
        onCheckForUpdates: (() -> Void)? = nil
    ) {
        self.onRecovered = onRecovered
        self.onDismiss = onDismiss
        self.onCheckForUpdates = onCheckForUpdates
    }

    private var presentation: RecoveryPresentation {
        RecoveryPresentation.forStatus(store.persistence.loadStatus)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
            Label(presentation.title, systemImage: presentation.systemImage)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            Text(presentation.explanation)
                .fixedSize(horizontal: false, vertical: true)

            Text(presentation.guidance)
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
                if presentation.showsUpdateAction, let onCheckForUpdates {
                    Button("Check for Updates…", action: onCheckForUpdates)
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint("Checks for a newer CodePulse version without changing the saved data")
                }

                if presentation.restoreButtonIsProminent {
                    restoreButton
                        .buttonStyle(.borderedProminent)
                } else {
                    restoreButton
                        .buttonStyle(.bordered)
                }

                Button("Show Data Folder") {
                    showDataFolder()
                }
                .buttonStyle(.bordered)
                .accessibilityHint(presentation.dataFolderAccessibilityHint)

                Spacer()

                Button("Quit CodePulse") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.link)
                .accessibilityLabel("Quit CodePulse")
                .accessibilityHint(presentation.quitAccessibilityHint)
            }
            }
            .padding(30)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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
        return RecoveryPresentation.backupConfirmationMessage(for: candidate.preview)
    }

    private var restoreButton: some View {
        Button("Restore Backup…") {
            chooseBackup()
        }
        .accessibilityHint(presentation.restoreAccessibilityHint)
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
