import CodePulseIntegration
import Foundation

/// Pure presentation decisions used by the History browser. Keeping these
/// decisions outside the SwiftUI view makes the nil-vs-zero and selection
/// contracts straightforward to regression-test without rendering a window.
enum HistorySelectionResolver {
    static func resolve(
        currentID: UUID?,
        preferredID: UUID? = nil,
        visibleIDs: [UUID]
    ) -> UUID? {
        guard !visibleIDs.isEmpty else { return nil }

        if let preferredID, visibleIDs.contains(preferredID) {
            return preferredID
        }
        if let currentID, visibleIDs.contains(currentID) {
            return currentID
        }
        return visibleIDs[0]
    }

    /// Chooses the nearest surviving row after deleting a selected session.
    /// The row that shifted into the deleted row's position wins; when the
    /// deleted row was last, the new last row is selected instead.
    static func afterDeletion(
        deletedID: UUID,
        currentID: UUID?,
        visibleIDsBeforeDeletion: [UUID],
        visibleIDsAfterDeletion: [UUID]
    ) -> UUID? {
        guard currentID == deletedID else {
            return resolve(currentID: currentID, visibleIDs: visibleIDsAfterDeletion)
        }
        guard !visibleIDsAfterDeletion.isEmpty else { return nil }

        guard let deletedIndex = visibleIDsBeforeDeletion.firstIndex(of: deletedID) else {
            return visibleIDsAfterDeletion[0]
        }
        if deletedIndex < visibleIDsAfterDeletion.count {
            return visibleIDsAfterDeletion[deletedIndex]
        }
        return visibleIDsAfterDeletion.last
    }
}

enum HistoryGitFormatting {
    static func commitCount(_ count: Int?) -> String? {
        guard let count else { return nil }
        let noun = count == 1 ? "commit" : "commits"
        return "\(count) \(noun)"
    }

    static func changes(
        filesChanged: Int?,
        insertions: Int?,
        deletions: Int?
    ) -> String? {
        guard let filesChanged else { return nil }
        guard filesChanged != 0 else { return "0 files changed" }

        let fileLabel = filesChanged == 1 ? "file" : "files"
        var result = "\(filesChanged) \(fileLabel)"
        var diffParts: [String] = []
        if let insertions {
            diffParts.append("+\(insertions)")
        }
        if let deletions {
            diffParts.append("-\(deletions)")
        }
        if !diffParts.isEmpty {
            result += " · \(diffParts.joined(separator: " / "))"
        }
        return result
    }
}

enum HistoryDeveloperToolPresentation {
    static let initialLimit = 8

    static func visibleContexts(
        _ contexts: [DeveloperToolSessionContext],
        isExpanded: Bool
    ) -> [DeveloperToolSessionContext] {
        isExpanded ? contexts : Array(contexts.prefix(initialLimit))
    }

    static func remainingCount(_ contexts: [DeveloperToolSessionContext]) -> Int {
        max(0, contexts.count - initialLimit)
    }
}

enum HistoryDetailAvailability {
    static func hasJournal(_ session: CompletedSession) -> Bool {
        MeaningfulText.exists(session.goal) || MeaningfulText.exists(session.outcome)
    }

    static func needsFollowUp(_ session: CompletedSession) -> Bool {
        MeaningfulText.exists(session.goal) && !MeaningfulText.exists(session.outcome)
    }
}

enum HistoryDateFormatting {
    static func fullDay(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEEE, MMMM d, yyyy"
        return formatter.string(from: date)
    }
}
