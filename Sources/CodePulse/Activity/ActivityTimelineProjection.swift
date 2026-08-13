import Foundation

struct ActivityTimelineEntry: Equatable, Identifiable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date?
    let state: IntervalState
    let runLabel: String

    var stateLabel: String {
        switch state {
        case .active: return "Active"
        case .waiting: return "Waiting"
        case .reviewGrace: return "Review grace"
        case .ended: return "Ended"
        }
    }
}

enum ActivityTimelineProjection {
    /// Produces display-safe interval rows. Raw event bodies, session
    /// fingerprints, interval reasons, and filesystem identities are not part
    /// of this projection.
    static func entries(activityID: UUID, in graph: ActivityGraph) -> [ActivityTimelineEntry] {
        graph.runs
            .filter { $0.activityID == activityID }
            .flatMap { run in
                run.intervals.map { interval in
                    ActivityTimelineEntry(
                        id: interval.id,
                        startedAt: interval.startedAt,
                        endedAt: interval.endedAt,
                        state: interval.state,
                        runLabel: label(for: run)
                    )
                }
            }
            .sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    private static func label(for run: Run) -> String {
        guard let metadata = run.agentMetadata else { return "Manual timer" }
        if let model = metadata.model, !model.isEmpty {
            return "\(metadata.integration.title) · \(model)"
        }
        return metadata.integration.title
    }
}
