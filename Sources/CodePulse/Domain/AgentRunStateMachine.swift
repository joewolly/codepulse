import CodePulseIntegration
import Foundation

/// Persisted lifecycle state for one agent run. The state is derived only from
/// validated DeveloperEventV2 lifecycle kinds; adapters do not calculate time.
enum AgentRunState: String, Codable, CaseIterable, Equatable {
    case new
    case active
    case awaitingPermission
    case reviewGrace
    case waiting
    case ended
    case orphaned
}

struct AgentRunMetadata: Codable, Equatable {
    let integration: DeveloperEventIntegration
    let sessionFingerprint: String
    let parentSessionFingerprint: String?
    var model: String?
    var state: AgentRunState
    var lastEventAt: Date
    var reviewGraceDeadline: Date?

    init(
        integration: DeveloperEventIntegration,
        sessionFingerprint: String,
        parentSessionFingerprint: String? = nil,
        model: String? = nil,
        state: AgentRunState = .new,
        lastEventAt: Date,
        reviewGraceDeadline: Date? = nil
    ) {
        self.integration = integration
        self.sessionFingerprint = sessionFingerprint
        self.parentSessionFingerprint = parentSessionFingerprint
        self.model = model
        self.state = state
        self.lastEventAt = lastEventAt
        self.reviewGraceDeadline = reviewGraceDeadline
    }
}

enum AgentRunStateReducer {
    /// Transition precedence is terminal > explicit lifecycle > activity.
    /// Events earlier than the last accepted event are ignored, which makes
    /// duplicated and out-of-order delivery safe.
    static func reduce(
        state: AgentRunState,
        eventKind: DeveloperEventKindV2,
        observedAt: Date,
        lastEventAt: Date
    ) -> AgentRunState? {
        guard observedAt >= lastEventAt else { return nil }
        guard state != .ended && state != .orphaned else { return nil }

        switch eventKind {
        case .sessionEnded:
            return .ended
        case .permissionRequested:
            return state == .awaitingPermission ? nil : .awaitingPermission
        case .sessionStopped:
            return state == .reviewGrace ? nil : .reviewGrace
        case .sessionIdle:
            return state == .waiting ? nil : .waiting
        case .sessionStarted, .activityObserved:
            return state == .active ? nil : .active
        case .integrationError:
            return nil
        }
    }
}

enum AgentRunLifecycle {
    static let defaultReviewGrace: TimeInterval = 3 * 60
    static let defaultStaleRunTimeout: TimeInterval = 15 * 60

    /// Applies one normalized event to a known agent run, closing/opening
    /// immutable intervals as the reducer changes state.
    @discardableResult
    static func apply(
        _ event: DeveloperEventV2,
        to run: inout Run,
        reviewGrace: TimeInterval
    ) -> Bool {
        guard var metadata = run.agentMetadata,
              metadata.integration == event.integration,
              event.observedAt >= run.startedAt,
              let next = AgentRunStateReducer.reduce(
                state: metadata.state,
                eventKind: event.eventKind,
                observedAt: event.observedAt,
                lastEventAt: metadata.lastEventAt
              ) else {
            return false
        }

        materialize(next, in: &run, at: event.observedAt, reason: event.eventKind.rawValue)
        metadata.state = next
        metadata.lastEventAt = event.observedAt
        metadata.reviewGraceDeadline = next == .reviewGrace
            ? event.observedAt.addingTimeInterval(max(0, reviewGrace))
            : nil
        run.agentMetadata = metadata
        return true
    }

    /// Advances review grace without an incoming event. A grace timeout opens
    /// a waiting interval exactly at the deadline, never at the later refresh
    /// time, so long pauses cannot become active time.
    @discardableResult
    static func advanceTime(
        in run: inout Run,
        now: Date,
        staleAfter: TimeInterval = defaultStaleRunTimeout
    ) -> Bool {
        guard var metadata = run.agentMetadata,
              run.endedAt == nil else { return false }
        var changed = false

        if metadata.state == .reviewGrace,
           let deadline = metadata.reviewGraceDeadline,
           now >= deadline {
            materialize(.waiting, in: &run, at: deadline, reason: "reviewGraceExpired")
            metadata.state = .waiting
            metadata.lastEventAt = deadline
            metadata.reviewGraceDeadline = nil
            changed = true
        }

        guard now.timeIntervalSince(metadata.lastEventAt) >= staleAfter else {
            run.agentMetadata = metadata
            return changed
        }

        // No event supports extending an open run past its final known
        // lifecycle time. Mark it orphaned and close it there instead.
        materialize(.orphaned, in: &run, at: metadata.lastEventAt, reason: "staleRun")
        metadata.state = .orphaned
        metadata.reviewGraceDeadline = nil
        run.agentMetadata = metadata
        return true
    }

    static func timingMetrics(for run: Run, at now: Date) -> AgentRunTimingMetrics {
        let active = run.intervals
            .filter { $0.state == .active }
            .reduce(0) { $0 + $1.duration(at: now) }
        let reviewGrace = run.intervals
            .filter { $0.state == .reviewGrace }
            .reduce(0) { $0 + $1.duration(at: now) }
        let waiting = run.intervals
            .filter { $0.state == .waiting }
            .reduce(0) { $0 + $1.duration(at: now) }
        return AgentRunTimingMetrics(
            agentRuntime: active,
            reviewGrace: reviewGrace,
            waiting: waiting,
            elapsed: max(0, min(run.endedAt ?? now, now).timeIntervalSince(run.startedAt))
        )
    }

    private static func materialize(_ state: AgentRunState, in run: inout Run, at date: Date, reason: String) {
        guard date >= run.startedAt else { return }
        if let index = run.intervals.firstIndex(where: \.isOpen) {
            run.intervals[index] = run.intervals[index].closed(at: date)
        }
        switch state {
        case .active:
            run.intervals.append(Interval(state: .active, startedAt: date, reason: reason))
        case .awaitingPermission, .waiting:
            run.intervals.append(Interval(state: .waiting, startedAt: date, reason: reason))
        case .reviewGrace:
            run.intervals.append(Interval(state: .reviewGrace, startedAt: date, reason: reason))
        case .ended, .orphaned:
            run.endedAt = date
        case .new:
            break
        }
    }
}

struct AgentRunTimingMetrics: Equatable {
    let agentRuntime: TimeInterval
    let reviewGrace: TimeInterval
    let waiting: TimeInterval
    let elapsed: TimeInterval

    /// Review grace is visible separately, but counts as eligible active time
    /// for the limited post-stop period configured by the user.
    var eligibleActive: TimeInterval { agentRuntime + reviewGrace }
}
