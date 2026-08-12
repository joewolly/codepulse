import CodePulseIntegration
import Foundation

protocol DeveloperToolEventConsuming: AnyObject {
    func processPending(state: inout AppState, now: Date) -> Bool
}

final class DeveloperToolEventConsumer: DeveloperToolEventConsuming {
    private let inbox: DeveloperToolInbox

    init(inbox: DeveloperToolInbox = DeveloperToolInbox()) {
        self.inbox = inbox
    }

    @discardableResult
    func processPending(state: inout AppState, now: Date) -> Bool {
        var changed = pruneProcessedEvents(in: &state, now: now)
        var processing = state.developerToolIntegration ?? DeveloperToolIntegrationProcessingState()
        var processedIDs = Set(processing.processedEvents.map(\.id))

        for url in inbox.pendingEventURLs() {
            guard let event = try? inbox.readEvent(from: url, now: now) else {
                // Do not quarantine malformed input: it may contain data that
                // is outside CodePulse's privacy boundary. Best-effort cleanup
                // keeps it out of CodePulse state without interrupting timing.
                inbox.remove(url)
                continue
            }

            if processedIDs.contains(event.id) {
                inbox.remove(url)
                continue
            }

            if attach(event, to: &state, now: now) {
                changed = true
            }

            processing.processedEvents.append(
                DeveloperToolProcessedEvent(id: event.id, processedAt: now)
            )
            processedIDs.insert(event.id)
            changed = true
            inbox.remove(url)
        }

        if processing.processedEvents.isEmpty {
            if state.developerToolIntegration != nil {
                state.developerToolIntegration = nil
                changed = true
            }
        } else if state.developerToolIntegration != processing {
            state.developerToolIntegration = processing
            changed = true
        }
        return changed
    }

    private func attach(
        _ event: DeveloperToolEvent,
        to state: inout AppState,
        now: Date
    ) -> Bool {
        guard var session = state.activeSession,
              session.projectID != nil,
              let project = state.projects.first(where: { $0.id == session.projectID }),
              let projectPath = projectFolderPath(for: project),
              DeveloperToolProjectPathMatcher.matches(
                projectPath: projectPath,
                workingDirectory: event.workingDirectory
              ),
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
            context.model = event.model ?? context.model
            context.profile = event.profile ?? context.profile
            context.eventCount += 1
            if event.eventType == .sessionEnded {
                context.endedAt = max(context.endedAt ?? event.timestamp, event.timestamp)
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

        state.activeSession = session
        return true
    }

    private func pruneProcessedEvents(in state: inout AppState, now: Date) -> Bool {
        guard var processing = state.developerToolIntegration else { return false }
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        processing.processedEvents.removeAll { $0.processedAt < cutoff }
        if processing.processedEvents.count > 2_048 {
            processing.processedEvents.sort { $0.processedAt > $1.processedAt }
            processing.processedEvents.removeLast(processing.processedEvents.count - 2_048)
        }
        guard processing != state.developerToolIntegration else { return false }
        state.developerToolIntegration = processing
        return true
    }

    private func projectFolderPath(for project: ProjectRecord) -> String? {
        #if os(macOS)
        if let bookmarkData = project.bookmarkData {
            var isStale = false
            if let bookmarkedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return bookmarkedURL.path
            }
        }
        #endif
        return project.folderPath
    }
}
