import CodePulseIntegration
import Foundation

protocol DeveloperToolEventConsuming: AnyObject {
    func drainPending(state: inout AppState, now: Date) -> [ValidatedDeveloperToolEvent]
    func attach(_ event: DeveloperToolEvent, to state: inout AppState, now: Date) -> Bool
    func attach(
        _ event: DeveloperToolEvent,
        toSessionID sessionID: UUID,
        in state: inout AppState,
        now: Date
    ) -> Bool
    func markProcessed(
        _ pending: ValidatedDeveloperToolEvent,
        in state: inout AppState,
        at date: Date
    ) -> Bool
    func cleanup(_ pending: ValidatedDeveloperToolEvent)
    func processPending(state: inout AppState, now: Date) -> Bool
}

extension DeveloperToolEventConsuming {
    func attach(
        _ event: DeveloperToolEvent,
        toSessionID sessionID: UUID,
        in state: inout AppState,
        now: Date
    ) -> Bool {
        guard state.soleActiveSession?.id == sessionID else { return false }
        return attach(event, to: &state, now: now)
    }
}

final class DeveloperToolEventConsumer: DeveloperToolEventConsuming {
    private let reader: DeveloperToolEventReader

    init(inbox: DeveloperToolInbox = DeveloperToolInbox()) {
        self.reader = DeveloperToolEventReader(inbox: inbox)
    }

    func drainPending(state: inout AppState, now: Date) -> [ValidatedDeveloperToolEvent] {
        reader.drainPending(state: &state, now: now)
    }

    @discardableResult
    func attach(_ event: DeveloperToolEvent, to state: inout AppState, now: Date) -> Bool {
        guard let sessionID = state.soleActiveSession?.id else { return false }
        return attach(event, toSessionID: sessionID, in: &state, now: now)
    }

    @discardableResult
    func attach(
        _ event: DeveloperToolEvent,
        toSessionID sessionID: UUID,
        in state: inout AppState,
        now: Date
    ) -> Bool {
        guard var session = state.activeSession(id: sessionID),
              session.projectID != nil,
              let resolvedProjectID = DeveloperToolProjectResolver.projectID(
                  for: event.workingDirectory,
                  in: state.projects
              ),
              resolvedProjectID == session.projectID,
              event.timestamp >= session.startedAt,
              event.timestamp <= session.endedAt ?? now else {
            return false
        }

        if let index = session.developerToolContexts.firstIndex(where: {
            $0.tool == event.tool && $0.externalSessionID == event.externalSessionID
        }) {
            var context = session.developerToolContexts[index]
            guard context.eventCount < DeveloperToolIntegrationLimits.maximumEventsPerContext else {
                return false
            }
            context.firstActivityAt = min(context.firstActivityAt, event.timestamp)
            context.lastActivityAt = max(context.lastActivityAt, event.timestamp)
            let isNewestEvent = event.timestamp >= context.lastActivityAt
            if isNewestEvent {
                context.model = event.model ?? context.model
                context.profile = event.profile ?? context.profile
            }
            context.eventCount += 1
            if isNewestEvent {
                if event.eventType == .sessionEnded {
                    context.endedAt = event.timestamp
                } else if event.eventType == .sessionStarted || event.eventType == .activity {
                    context.endedAt = nil
                }
            }
            session.developerToolContexts[index] = context
        } else {
            guard session.developerToolContexts.count < DeveloperToolIntegrationLimits.maximumContextsPerSession else {
                return false
            }
            let context = DeveloperToolSessionContext(
                id: DeveloperToolEventID.stable(
                    tool: event.tool,
                    externalSessionID: event.externalSessionID,
                    eventType: .activity,
                    workingDirectory: event.workingDirectory,
                    discriminator: "context"
                ),
                tool: event.tool,
                externalSessionID: event.externalSessionID,
                workingDirectory: event.workingDirectory,
                firstActivityAt: event.timestamp,
                lastActivityAt: event.timestamp,
                model: event.model,
                profile: event.profile,
                eventCount: 1,
                endedAt: event.eventType == .sessionEnded ? event.timestamp : nil
            )
            session.developerToolContexts.append(context)
        }

        guard let index = state.activeSessionIndex(id: sessionID) else { return false }
        var candidate = state
        candidate.activeSessions[index] = session
        do {
            try AppStateIntegrityValidator.validate(candidate)
        } catch {
            return false
        }
        state = candidate
        return true
    }

    @discardableResult
    func markProcessed(
        _ pending: ValidatedDeveloperToolEvent,
        in state: inout AppState,
        at date: Date
    ) -> Bool {
        reader.markProcessed(pending, in: &state, at: date)
    }

    func cleanup(_ pending: ValidatedDeveloperToolEvent) {
        reader.cleanup(pending)
    }

    /// Compatibility path for callers that only need the original context
    /// enrichment behavior. SessionStore uses the staged methods above so
    /// automation runs before the event is acknowledged.
    @discardableResult
    func processPending(state: inout AppState, now: Date) -> Bool {
        let original = state
        let pending = drainPending(state: &state, now: now)
        for item in pending {
            _ = attach(item.event, to: &state, now: now)
            _ = markProcessed(item, in: &state, at: now)
            cleanup(item)
        }
        return state != original
    }
}
