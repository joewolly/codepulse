import CodePulseIntegration
import Foundation

protocol DeveloperEventV2Consuming: AnyObject {
    func processPending(state: inout AppState, now: Date) -> Bool
}

/// Consumes only the v2 diagnostic pipeline. Feature 03 intentionally does
/// not attach these events to timers, sessions, or activity intervals.
final class DeveloperEventV2Consumer: DeveloperEventV2Consuming {
    private let inbox: DeveloperEventV2Inbox

    init(inbox: DeveloperEventV2Inbox = DeveloperEventV2Inbox()) {
        self.inbox = inbox
    }

    @discardableResult
    func processPending(state: inout AppState, now: Date) -> Bool {
        var journal = state.developerEventDiagnostics ?? DeveloperEventDiagnosticsJournal()
        var changed = prune(&journal, now: now)
        var knownFingerprints = Set(journal.entries.compactMap(\.eventFingerprint))
        var receiptFingerprints = Set<String>()

        for url in inbox.pendingReceiptURLs() {
            do {
                let receipt = try inbox.readReceipt(from: url)
                journal.append(DeveloperEventDiagnostic(
                    receivedAt: receipt.receivedAt,
                    status: diagnosticStatus(for: receipt.status),
                    integration: receipt.integration?.rawValue,
                    eventFingerprint: receipt.eventFingerprint,
                    parserVersion: receipt.parserVersion,
                    integrationVersion: receipt.integrationVersion,
                    rejectionCode: receipt.rejectionCode
                ))
                if receipt.status == .accepted, let fingerprint = receipt.eventFingerprint {
                    knownFingerprints.insert(fingerprint)
                }
                if receipt.status != .rejected, let fingerprint = receipt.eventFingerprint {
                    receiptFingerprints.insert(fingerprint)
                }
            } catch {
                journal.append(DeveloperEventDiagnostic(
                    receivedAt: now,
                    status: .rejected,
                    rejectionCode: "receipt-invalid"
                ))
            }
            _ = inbox.remove(url)
            changed = true
        }

        for url in inbox.pendingEventURLs() {
            do {
                let event = try inbox.readEvent(from: url, now: now)
                let fingerprint = inbox.fingerprint(for: event.idempotencyKey)
                // The receiver has already emitted the canonical receipt for
                // this inbox handoff. Do not turn an accepted receipt into a
                // spurious duplicate merely because its event is now read.
                if receiptFingerprints.contains(fingerprint) {
                    // Receipt already persisted the outcome.
                } else if knownFingerprints.contains(fingerprint) {
                    journal.append(DeveloperEventDiagnostic(
                        receivedAt: now,
                        status: .duplicate,
                        integration: event.integration.rawValue,
                        eventFingerprint: fingerprint,
                        parserVersion: event.parserVersion,
                        integrationVersion: event.integrationVersion
                    ))
                } else {
                    journal.append(DeveloperEventDiagnostic(
                        receivedAt: now,
                        status: .accepted,
                        integration: event.integration.rawValue,
                        eventFingerprint: fingerprint,
                        parserVersion: event.parserVersion,
                        integrationVersion: event.integrationVersion
                    ))
                    knownFingerprints.insert(fingerprint)
                }
            } catch {
                journal.append(DeveloperEventDiagnostic(
                    receivedAt: now,
                    status: .rejected,
                    rejectionCode: redactedRejectionCode(for: error)
                ))
            }
            // The receiver's inbox is an untrusted handoff. Diagnostics retain
            // only the safe receipt above, never a copy of the hook input.
            _ = inbox.remove(url)
            changed = true
        }

        guard changed || state.developerEventDiagnostics != journal else { return false }
        state.developerEventDiagnostics = journal
        return true
    }

    private func diagnosticStatus(for status: DeveloperEventReceiptStatus) -> DeveloperEventDiagnosticStatus {
        switch status {
        case .accepted: return .accepted
        case .duplicate: return .duplicate
        case .rejected: return .rejected
        }
    }

    private func prune(_ journal: inout DeveloperEventDiagnosticsJournal, now: Date) -> Bool {
        let original = journal
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        journal.entries.removeAll { $0.receivedAt < cutoff }
        if journal.entries.count > DeveloperEventDiagnosticsJournal.maximumEntries {
            journal.entries.removeFirst(journal.entries.count - DeveloperEventDiagnosticsJournal.maximumEntries)
        }
        return journal != original
    }

    private func redactedRejectionCode(for error: Error) -> String {
        // Error descriptions can include names or untrusted parser details; a
        // fixed code is the only diagnostic persisted for rejected input.
        switch error {
        case is DeveloperEventV2InboxError:
            return "inbox-rejected"
        case is DeveloperEventV2ValidationError:
            return "validation-rejected"
        case is DeveloperEventV2Codec.Error:
            return "schema-rejected"
        default:
            return "invalid-event"
        }
    }
}
