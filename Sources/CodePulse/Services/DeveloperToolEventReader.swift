import CodePulseIntegration
import Foundation

struct ValidatedDeveloperToolEvent: Equatable {
    let event: DeveloperToolEvent
    let sourceURL: URL
}

final class DeveloperToolEventReader {
    private let inbox: DeveloperToolInbox

    init(inbox: DeveloperToolInbox) {
        self.inbox = inbox
    }

    func drainPending(state: inout AppState, now: Date) -> [ValidatedDeveloperToolEvent] {
        var processing = state.developerToolIntegration ?? DeveloperToolIntegrationProcessingState()
        pruneProcessedEvents(&processing, now: now)

        var processedIDs = Set(processing.processedEvents.map { $0.id })
        var surfacedIDs = Set<UUID>()
        var surfaced: [ValidatedDeveloperToolEvent] = []

        for url in inbox.pendingEventURLs() {
            guard let event = try? inbox.readEvent(from: url, now: now) else {
                // Do not retain malformed input. It may contain content outside
                // CodePulse's privacy boundary, so cleanup remains best effort.
                inbox.remove(url)
                continue
            }

            guard LocalInputAcceptance.accepts(
                timestamp: event.timestamp,
                after: state.localInputAcceptanceDate
            ) else {
                // A restore clears the portable processed-event ledger. Do not
                // let an inbox file from the previous local state become
                // eligible again after that reset.
                inbox.remove(url)
                continue
            }

            guard !processedIDs.contains(event.id), !surfacedIDs.contains(event.id) else {
                inbox.remove(url)
                continue
            }

            surfaced.append(ValidatedDeveloperToolEvent(event: event, sourceURL: url))
            surfacedIDs.insert(event.id)
        }

        if processing.processedEvents.isEmpty {
            state.developerToolIntegration = nil
        } else {
            state.developerToolIntegration = processing
        }
        processedIDs.removeAll(keepingCapacity: false)
        return surfaced
    }

    @discardableResult
    func markProcessed(
        _ pending: ValidatedDeveloperToolEvent,
        in state: inout AppState,
        at date: Date
    ) -> Bool {
        var processing = state.developerToolIntegration ?? DeveloperToolIntegrationProcessingState()
        guard !processing.processedEvents.contains(where: { $0.id == pending.event.id }) else {
            return false
        }

        processing.processedEvents.append(
            DeveloperToolProcessedEvent(id: pending.event.id, processedAt: date)
        )
        processing.processedEvents.sort { $0.processedAt > $1.processedAt }
        if processing.processedEvents.count > DeveloperToolIntegrationLimits.maximumInboxFiles {
            processing.processedEvents.removeLast(
                processing.processedEvents.count - DeveloperToolIntegrationLimits.maximumInboxFiles
            )
        }
        state.developerToolIntegration = processing
        return true
    }

    func cleanup(_ pending: ValidatedDeveloperToolEvent) {
        _ = inbox.remove(pending.sourceURL)
    }

    private func pruneProcessedEvents(
        _ processing: inout DeveloperToolIntegrationProcessingState,
        now: Date
    ) {
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        processing.processedEvents.removeAll { $0.processedAt < cutoff }
        if processing.processedEvents.count > DeveloperToolIntegrationLimits.maximumInboxFiles {
            processing.processedEvents.sort { $0.processedAt > $1.processedAt }
            processing.processedEvents.removeLast(
                processing.processedEvents.count - DeveloperToolIntegrationLimits.maximumInboxFiles
            )
        }
    }
}
