import CodePulseIntegration
import Foundation

enum ActivityGraphError: Error, Equatable {
    case workspaceNotFound
    case activityNotFound
    case runNotFound
    case activityWorkspaceMismatch
    case runAlreadyEnded
    case openIntervalExists
    case intervalNotFound
    case invalidInterval
}

struct ActivityGraphRepository {
    static func createActivity(
        in graph: inout ActivityGraph,
        workspaceID: UUID,
        title: String,
        workType: SessionType,
        domain: ActivityDomain,
        at date: Date
    ) throws -> Activity {
        guard graph.workspaces.contains(where: { $0.id == workspaceID }) else {
            throw ActivityGraphError.workspaceNotFound
        }
        let activity = Activity(workspaceID: workspaceID, title: title, workType: workType, domain: domain, createdAt: date)
        graph.activities.append(activity)
        return activity
    }

    static func updateActivity(
        in graph: inout ActivityGraph,
        id: UUID,
        title: String? = nil,
        workType: SessionType? = nil,
        domain: ActivityDomain? = nil,
        at date: Date
    ) throws {
        guard let index = graph.activities.firstIndex(where: { $0.id == id }) else {
            throw ActivityGraphError.activityNotFound
        }
        if let title { graph.activities[index].title = title }
        if let workType { graph.activities[index].workType = workType }
        if let domain { graph.activities[index].domain = domain }
        graph.activities[index].updatedAt = max(graph.activities[index].createdAt, date)
    }

    static func startRun(
        in graph: inout ActivityGraph,
        activityID: UUID,
        kind: RunKind,
        at date: Date,
        initialState: IntervalState = .active,
        agentMetadata: AgentRunMetadata? = nil
    ) throws -> Run {
        guard graph.activities.contains(where: { $0.id == activityID }) else {
            throw ActivityGraphError.activityNotFound
        }
        let run = Run(
            activityID: activityID,
            kind: kind,
            startedAt: date,
            intervals: agentMetadata?.state == .new ? [] : [Interval(state: initialState, startedAt: date)],
            agentMetadata: agentMetadata
        )
        graph.runs.append(run)
        return run
    }

    @discardableResult
    static func applyAgentEvent(
        in graph: inout ActivityGraph,
        runID: UUID,
        event: DeveloperEventV2,
        reviewGrace: TimeInterval
    ) -> Bool {
        guard let index = graph.runs.firstIndex(where: { $0.id == runID }) else { return false }
        return AgentRunLifecycle.apply(event, to: &graph.runs[index], reviewGrace: reviewGrace)
    }

    @discardableResult
    static func reconcileAgentRuns(
        in graph: inout ActivityGraph,
        now: Date,
        staleAfter: TimeInterval = AgentRunLifecycle.defaultStaleRunTimeout
    ) -> Bool {
        var changed = false
        for index in graph.runs.indices where graph.runs[index].kind == .agent {
            changed = AgentRunLifecycle.advanceTime(in: &graph.runs[index], now: now, staleAfter: staleAfter) || changed
        }
        return changed
    }

    static func beginInterval(
        in graph: inout ActivityGraph,
        runID: UUID,
        state: IntervalState,
        at date: Date,
        reason: String? = nil
    ) throws {
        guard let index = graph.runs.firstIndex(where: { $0.id == runID }) else {
            throw ActivityGraphError.runNotFound
        }
        guard graph.runs[index].endedAt == nil else { throw ActivityGraphError.runAlreadyEnded }
        guard graph.runs[index].openInterval == nil else { throw ActivityGraphError.openIntervalExists }
        guard date >= graph.runs[index].startedAt else { throw ActivityGraphError.invalidInterval }
        graph.runs[index].intervals.append(Interval(state: state, startedAt: date, reason: reason))
    }

    static func closeOpenInterval(in graph: inout ActivityGraph, runID: UUID, at date: Date) throws {
        guard let runIndex = graph.runs.firstIndex(where: { $0.id == runID }) else { throw ActivityGraphError.runNotFound }
        guard let intervalIndex = graph.runs[runIndex].intervals.firstIndex(where: \.isOpen) else {
            throw ActivityGraphError.intervalNotFound
        }
        graph.runs[runIndex].intervals[intervalIndex] = graph.runs[runIndex].intervals[intervalIndex].closed(at: date)
    }

    static func endRun(in graph: inout ActivityGraph, runID: UUID, at date: Date) throws {
        guard let index = graph.runs.firstIndex(where: { $0.id == runID }) else { throw ActivityGraphError.runNotFound }
        guard graph.runs[index].endedAt == nil else { throw ActivityGraphError.runAlreadyEnded }
        guard date >= graph.runs[index].startedAt else { throw ActivityGraphError.invalidInterval }
        if let intervalIndex = graph.runs[index].intervals.firstIndex(where: \.isOpen) {
            graph.runs[index].intervals[intervalIndex] = graph.runs[index].intervals[intervalIndex].closed(at: date)
        }
        graph.runs[index].endedAt = date
    }

    static func runs(in graph: ActivityGraph, workspaceID: UUID? = nil, activityID: UUID? = nil) -> [Run] {
        graph.runs.filter { run in
            guard activityID == nil || run.activityID == activityID else { return false }
            guard let workspaceID else { return true }
            return graph.activities.first(where: { $0.id == run.activityID })?.workspaceID == workspaceID
        }
    }
}
