import CodePulseIntegration
import Foundation

/// Transient per-Session Git work status. It is intentionally not part of
/// AppState persistence: durable Git context contains only completed
/// observation metadata, while in-flight jobs are invalidated on replacement.
enum SessionGitCaptureStatus: Equatable, Sendable {
    case scheduled
    case running
    case succeeded
    case failed
    case ambiguous
}

enum SessionGitCaptureStage: Equatable, Sendable {
    case start
    case final
}

struct SessionGitCaptureState: Equatable, Sendable {
    var startStatus: SessionGitCaptureStatus?
    var finalStatus: SessionGitCaptureStatus?
    var activeStage: SessionGitCaptureStage?
    var pendingFinalCapture: Bool
    var jobToken: UUID?
    var generation: UUID

    init(
        startStatus: SessionGitCaptureStatus? = nil,
        finalStatus: SessionGitCaptureStatus? = nil,
        activeStage: SessionGitCaptureStage? = nil,
        pendingFinalCapture: Bool = false,
        jobToken: UUID? = nil,
        generation: UUID = UUID()
    ) {
        self.startStatus = startStatus
        self.finalStatus = finalStatus
        self.activeStage = activeStage
        self.pendingFinalCapture = pendingFinalCapture
        self.jobToken = jobToken
        self.generation = generation
    }

    var isInFlight: Bool { activeStage != nil }

    var aggregateStatus: SessionGitCaptureStatus? {
        if let activeStage {
            switch activeStage {
            case .start: return startStatus ?? .running
            case .final: return finalStatus ?? .running
            }
        }
        if finalStatus != nil { return finalStatus }
        return startStatus
    }
}

/// Phase 1 bounds and retention values. Keeping these in one domain type makes
/// the persistence and admission rules deterministic for later lifecycle work.
enum ConcurrentSessionLimits {
    static let maximumActiveSessions = 16
    static let maximumProtectedDeveloperToolThreads = 2_048
    static let retiredDeveloperToolRetention: TimeInterval = 7 * 24 * 60 * 60
}

/// A machine-local developer-tool identity. The external session identifier is
/// deliberately kept as supplied so malformed persisted values fail integrity
/// validation instead of being silently repaired.
struct DeveloperToolThreadIdentity: Codable, Equatable, Hashable, Sendable {
    let tool: DeveloperTool
    let externalSessionID: String

    init(tool: DeveloperTool, externalSessionID: String) {
        self.tool = tool
        self.externalSessionID = externalSessionID
    }

    var isValid: Bool {
        let trimmed = externalSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let scalars = externalSessionID.unicodeScalars
        return !externalSessionID.isEmpty &&
            trimmed == externalSessionID &&
            externalSessionID.count <= DeveloperToolIntegrationLimits.maximumExternalSessionIDLength &&
            scalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

struct RetiredDeveloperToolThread: Codable, Equatable, Hashable, Sendable {
    let tool: DeveloperTool
    let externalSessionID: String
    let retiredAt: Date
    let lastAcceptedEventAt: Date

    init(
        tool: DeveloperTool,
        externalSessionID: String,
        retiredAt: Date,
        lastAcceptedEventAt: Date
    ) {
        self.tool = tool
        self.externalSessionID = externalSessionID
        self.retiredAt = retiredAt
        self.lastAcceptedEventAt = lastAcceptedEventAt
    }

    var identity: DeveloperToolThreadIdentity {
        DeveloperToolThreadIdentity(tool: tool, externalSessionID: externalSessionID)
    }

    var isValid: Bool {
        identity.isValid &&
            retiredAt.timeIntervalSinceReferenceDate.isFinite &&
            lastAcceptedEventAt.timeIntervalSinceReferenceDate.isFinite &&
            lastAcceptedEventAt <= retiredAt
    }

    func isProtected(at date: Date) -> Bool {
        date < retiredAt.addingTimeInterval(ConcurrentSessionLimits.retiredDeveloperToolRetention)
    }
}

enum DeveloperToolThreadAdmissionError: LocalizedError, Equatable {
    case invalidIdentity
    case invalidRetirementMetadata
    case identityStillProtected
    case capacityExceeded
    case reservationNotFound

    var errorDescription: String? {
        switch self {
        case .invalidIdentity:
            return "The developer-tool identity is invalid."
        case .invalidRetirementMetadata:
            return "The retired developer-tool metadata has an invalid timestamp."
        case .identityStillProtected:
            return "The developer-tool identity is still protected after retirement."
        case .capacityExceeded:
            return "The protected and active developer-tool identity capacity is full."
        case .reservationNotFound:
            return "The developer-tool identity has no active reservation."
        }
    }
}

extension SessionAutomationClaimSource {
    var developerToolThreadIdentity: DeveloperToolThreadIdentity? {
        guard case .developerTool(let tool, let externalSessionID) = self else { return nil }
        return DeveloperToolThreadIdentity(tool: tool, externalSessionID: externalSessionID)
    }
}

extension ActiveSession {
    /// Ownership is represented by automation metadata. Developer-tool
    /// contexts on a manual/application session are observation data and do
    /// not reserve retired-thread capacity.
    var developerToolOwnershipIdentities: Set<DeveloperToolThreadIdentity> {
        var identities = Set<DeveloperToolThreadIdentity>()
        guard let metadata = automationMetadata else { return identities }
        if let identity = metadata.startedBySource.developerToolThreadIdentity {
            if identity.isValid { identities.insert(identity) }
        }
        for claim in metadata.claims {
            if let identity = claim.source.developerToolThreadIdentity {
                if identity.isValid { identities.insert(identity) }
            }
        }
        return identities
    }

    /// Developer-tool identities whose lifecycle claim is currently active.
    /// This is a lifecycle-signal helper only. It is deliberately not the
    /// ownership, uniqueness, capacity, or retirement set: an inactive claim
    /// still belongs to this active Session until the Session retires.
    var activeDeveloperToolClaimIdentities: Set<DeveloperToolThreadIdentity> {
        var identities = Set<DeveloperToolThreadIdentity>()
        guard let metadata = automationMetadata else { return identities }
        for claim in metadata.claims where claim.isActive {
            if let identity = claim.source.developerToolThreadIdentity,
               identity.isValid {
                identities.insert(identity)
            }
        }
        return identities
    }

    /// Source-compatible lifecycle helper retained for older callers. The
    /// original helper also includes the Session's starting Developer-Tool
    /// source, so preserve that behavior while keeping it out of all
    /// ownership/capacity decisions.
    var activeDeveloperToolOwnershipIdentities: Set<DeveloperToolThreadIdentity> {
        var identities = activeDeveloperToolClaimIdentities
        if let identity = automationMetadata?.startedBySource.developerToolThreadIdentity,
           identity.isValid {
            identities.insert(identity)
        }
        return identities
    }

    var isValidConcurrentTimeline: Bool {
        guard startedAt.timeIntervalSinceReferenceDate.isFinite else { return false }

        switch phase {
        case .idle:
            return false
        case .running:
            guard endedAt == nil else { return false }
        case .paused:
            guard endedAt == nil else { return false }
        case .finishing:
            guard let endedAt,
                  endedAt.timeIntervalSinceReferenceDate.isFinite,
                  endedAt >= startedAt else { return false }
        }

        var intervalIDs = Set<UUID>()
        var openCount = 0
        var previousEnd = startedAt
        var previousIntervalIsOpen = false
        for interval in pauseIntervals {
            guard intervalIDs.insert(interval.id).inserted,
                  interval.startedAt.timeIntervalSinceReferenceDate.isFinite,
                  interval.startedAt >= startedAt,
                  !previousIntervalIsOpen else {
                return false
            }

            if let endedAt = interval.endedAt {
                guard endedAt.timeIntervalSinceReferenceDate.isFinite,
                      endedAt >= interval.startedAt,
                      interval.startedAt >= previousEnd else {
                    return false
                }
                if let sessionEnd = self.endedAt, endedAt > sessionEnd {
                    return false
                }
                previousEnd = endedAt
                previousIntervalIsOpen = false
            } else {
                openCount += 1
                guard phase == .paused,
                      interval.startedAt >= previousEnd else {
                    return false
                }
                previousEnd = interval.startedAt
                previousIntervalIsOpen = true
            }
        }

        guard openCount <= 1 else { return false }
        switch phase {
        case .paused:
            return openCount == 1
        case .running, .finishing:
            return openCount == 0
        case .idle:
            return false
        }
    }
}

extension AppState {
    var activeSessionCount: Int { activeSessions.count }

    func activeSession(id: UUID) -> ActiveSession? {
        let matches = activeSessions.filter { $0.id == id }
        return matches.count == 1 ? matches[0] : nil
    }

    func activeSessionIndex(id: UUID) -> Int? {
        let matches = activeSessions.indices.filter { activeSessions[$0].id == id }
        return matches.count == 1 ? matches[0] : nil
    }

    enum ActiveSessionMutationError: LocalizedError, Equatable {
        case missing(UUID)
        case duplicate(UUID)

        var errorDescription: String? {
            switch self {
            case .missing(let id):
                return "Active session \(id.uuidString) was not found."
            case .duplicate(let id):
                return "Active session \(id.uuidString) is not unique."
            }
        }
    }

    /// Apply an ID-targeted mutation to a candidate state and publish it only
    /// after collection integrity validation succeeds.
    mutating func mutateActiveSession(
        id: UUID,
        _ mutation: (inout ActiveSession) throws -> Void
    ) throws {
        var candidate = self
        let indices = candidate.activeSessions.indices.filter { candidate.activeSessions[$0].id == id }
        guard indices.count == 1, let index = indices.first else {
            if indices.isEmpty { throw ActiveSessionMutationError.missing(id) }
            throw ActiveSessionMutationError.duplicate(id)
        }
        try mutation(&candidate.activeSessions[index])
        try AppStateIntegrityValidator.validate(candidate)
        self = candidate
    }

    mutating func appendActiveSession(_ session: ActiveSession) throws {
        var candidate = self
        candidate.activeSessions.append(session)
        try AppStateIntegrityValidator.validate(candidate)
        self = candidate
    }

    mutating func removeActiveSession(id: UUID) throws -> ActiveSession {
        var candidate = self
        let indices = candidate.activeSessions.indices.filter { candidate.activeSessions[$0].id == id }
        guard indices.count == 1, let index = indices.first else {
            if indices.count > 1 { throw ActiveSessionMutationError.duplicate(id) }
            throw ActiveSessionMutationError.missing(id)
        }
        let removed = candidate.activeSessions.remove(at: index)
        try AppStateIntegrityValidator.validate(candidate)
        self = candidate
        return removed
    }

    /// The authoritative ownership set for all active Sessions. Inactive
    /// claims remain owners until their Session is completed or discarded.
    var developerToolOwnershipIdentities: Set<DeveloperToolThreadIdentity> {
        activeSessions.reduce(into: Set<DeveloperToolThreadIdentity>()) { result, session in
            result.formUnion(session.developerToolOwnershipIdentities)
        }
    }

    /// Lifecycle-signal helper. This excludes inactive claims and is never
    /// used for uniqueness, capacity, admission, or retirement accounting.
    var activeDeveloperToolClaimIdentities: Set<DeveloperToolThreadIdentity> {
        activeSessions.reduce(into: Set<DeveloperToolThreadIdentity>()) { result, session in
            result.formUnion(session.activeDeveloperToolClaimIdentities)
        }
    }

    /// Compatibility alias for older callers. It remains a lifecycle helper
    /// (including each Session's starting source) and is never authoritative
    /// for ownership, uniqueness, capacity, admission, or retirement.
    @available(*, deprecated, message: "Use activeDeveloperToolClaimIdentities for lifecycle activity or developerToolOwnershipIdentities for ownership.")
    var activeDeveloperToolOwnershipIdentities: Set<DeveloperToolThreadIdentity> {
        activeSessions.reduce(into: Set<DeveloperToolThreadIdentity>()) { result, session in
            result.formUnion(session.activeDeveloperToolOwnershipIdentities)
        }
    }

    var reservedDeveloperToolOwnershipIdentities: Set<DeveloperToolThreadIdentity> {
        Set(developerToolIntegration?.reservedDeveloperToolThreads ?? [])
    }

    var activeDeveloperToolOwnedThreadCount: Int {
        // This is intentionally the ownership count, not the lifecycle-claim
        // count. A canonical state has one matching reservation per identity;
        // the broader capacity helper below also includes a staged reservation
        // during reserve-before-append admission.
        developerToolOwnershipIdentities.count
    }

    /// Repairs the one migration-only gap between legacy active automation
    /// metadata and schema-3 machine-local reservations. It never removes an
    /// existing reservation, so an orphan remains visible to integrity
    /// validation instead of being silently accepted or discarded.
    mutating func seedDeveloperToolReservationsFromActiveOwnership(at date: Date = Date()) {
        pruneExpiredRetiredDeveloperToolThreads(at: date)
        let ownership = developerToolOwnershipIdentities
        guard !ownership.isEmpty else { return }

        var processing = developerToolIntegration ?? DeveloperToolIntegrationProcessingState()
        let reserved = Set(processing.reservedDeveloperToolThreads)
        let missing = ownership.subtracting(reserved).sorted {
            if $0.tool != $1.tool { return $0.tool.rawValue < $1.tool.rawValue }
            return $0.externalSessionID < $1.externalSessionID
        }
        processing.reservedDeveloperToolThreads.append(contentsOf: missing)
        developerToolIntegration = processing
    }

    func protectedRetiredDeveloperToolThreadCount(at date: Date = Date()) -> Int {
        let identities = developerToolIntegration?.retiredDeveloperToolThreads
            .filter { $0.isProtected(at: date) }
            .map(\.identity) ?? []
        return Set(identities).count
    }

    func developerToolThreadCapacityUsed(at date: Date = Date()) -> Int {
        // Reservations are normally equal to active ownership. Including the
        // union here keeps the admission transaction safe while a new owner is
        // reserved immediately before its claim is appended. Canonical
        // validation rejects any orphan that would make this differ from the
        // active ownership count after publication.
        let accountedActiveIDs = developerToolOwnershipIdentities
            .union(reservedDeveloperToolOwnershipIdentities)
        return protectedRetiredDeveloperToolThreadCount(at: date) + accountedActiveIDs.count
    }

    mutating func pruneExpiredRetiredDeveloperToolThreads(at date: Date) {
        guard var processing = developerToolIntegration else { return }
        // Invalid records are retained for integrity validation/recovery; a
        // maintenance pass may prune only well-formed entries whose protection
        // window has elapsed.
        let expired = processing.retiredDeveloperToolThreads
            .filter { $0.isValid && !$0.isProtected(at: date) }
            .sorted { lhs, rhs in
                if lhs.retiredAt != rhs.retiredAt { return lhs.retiredAt < rhs.retiredAt }
                if lhs.lastAcceptedEventAt != rhs.lastAcceptedEventAt {
                    return lhs.lastAcceptedEventAt < rhs.lastAcceptedEventAt
                }
                if lhs.tool != rhs.tool { return lhs.tool.rawValue < rhs.tool.rawValue }
                return lhs.externalSessionID < rhs.externalSessionID
            }
        // Walk expired entries in the normative deterministic order, while
        // leaving protected-entry ordering untouched (and leaving a no-op
        // admission candidate byte-for-byte stable).
        for retired in expired {
            processing.retiredDeveloperToolThreads.removeAll {
                $0.identity == retired.identity && $0.isValid && !$0.isProtected(at: date)
            }
        }
        developerToolIntegration = processing.isEmpty ? nil : processing
    }

    mutating func canAdmitDeveloperToolOwner(
        tool: DeveloperTool,
        externalSessionID: String,
        at date: Date
    ) -> Bool {
        guard let identity = validIdentity(tool: tool, externalSessionID: externalSessionID) else { return false }
        pruneExpiredRetiredDeveloperToolThreads(at: date)
        if developerToolIntegration?.retiredDeveloperToolThreads.contains(where: { $0.identity == identity }) == true {
            return false
        }
        let existing = developerToolOwnershipIdentities.union(reservedDeveloperToolOwnershipIdentities)
        guard existing.contains(identity) else {
            return developerToolThreadCapacityUsed(at: date) + 1 <=
                ConcurrentSessionLimits.maximumProtectedDeveloperToolThreads
        }
        return true
    }

    /// Admit/reserve one distinct developer-tool identity. Existing ownership
    /// is idempotent; a protected retired identity is never silently reused.
    mutating func admitDeveloperToolOwner(
        tool: DeveloperTool,
        externalSessionID: String,
        at date: Date
    ) throws {
        guard let identity = validIdentity(tool: tool, externalSessionID: externalSessionID) else {
            throw DeveloperToolThreadAdmissionError.invalidIdentity
        }
        pruneExpiredRetiredDeveloperToolThreads(at: date)
        if developerToolIntegration?.retiredDeveloperToolThreads.contains(where: { $0.identity == identity }) == true {
            throw DeveloperToolThreadAdmissionError.identityStillProtected
        }

        let existing = developerToolOwnershipIdentities.union(reservedDeveloperToolOwnershipIdentities)
        if !existing.contains(identity) {
            guard developerToolThreadCapacityUsed(at: date) + 1 <=
                ConcurrentSessionLimits.maximumProtectedDeveloperToolThreads else {
                    throw DeveloperToolThreadAdmissionError.capacityExceeded
                }
        }

        var processing = developerToolIntegration ?? DeveloperToolIntegrationProcessingState()
        if !processing.reservedDeveloperToolThreads.contains(identity) {
            processing.reservedDeveloperToolThreads.append(identity)
        }
        developerToolIntegration = processing
    }

    /// Convert an admitted reservation into its protected tombstone. Callers
    /// should remove the completed active Session from their candidate state in
    /// the same transaction; the reservation and tombstone then occupy exactly
    /// one capacity slot throughout the conversion.
    mutating func retireDeveloperToolOwner(
        tool: DeveloperTool,
        externalSessionID: String,
        retiredAt: Date,
        lastAcceptedEventAt: Date
    ) throws {
        guard let identity = validIdentity(tool: tool, externalSessionID: externalSessionID) else {
            throw DeveloperToolThreadAdmissionError.invalidIdentity
        }
        guard retiredAt.timeIntervalSinceReferenceDate.isFinite,
              lastAcceptedEventAt.timeIntervalSinceReferenceDate.isFinite,
              lastAcceptedEventAt <= retiredAt else {
            throw DeveloperToolThreadAdmissionError.invalidRetirementMetadata
        }
        pruneExpiredRetiredDeveloperToolThreads(at: retiredAt)

        var processing = developerToolIntegration ?? DeveloperToolIntegrationProcessingState()
        guard processing.reservedDeveloperToolThreads.contains(identity) else {
            throw DeveloperToolThreadAdmissionError.reservationNotFound
        }
        guard !processing.retiredDeveloperToolThreads.contains(where: {
            $0.identity == identity && $0.isProtected(at: retiredAt)
        }) else {
            throw DeveloperToolThreadAdmissionError.identityStillProtected
        }
        processing.reservedDeveloperToolThreads.removeAll { $0 == identity }

        if let index = processing.retiredDeveloperToolThreads.firstIndex(where: { $0.identity == identity }) {
            processing.retiredDeveloperToolThreads[index] = RetiredDeveloperToolThread(
                tool: tool,
                externalSessionID: externalSessionID,
                retiredAt: retiredAt,
                lastAcceptedEventAt: lastAcceptedEventAt
            )
        } else {
            processing.retiredDeveloperToolThreads.append(RetiredDeveloperToolThread(
                tool: tool,
                externalSessionID: externalSessionID,
                retiredAt: retiredAt,
                lastAcceptedEventAt: lastAcceptedEventAt
            ))
        }
        developerToolIntegration = processing
    }

    mutating func retireDeveloperToolOwnership(
        for session: ActiveSession,
        retiredAt: Date,
        lastAcceptedEventAt: Date? = nil
    ) throws {
        let eventDate = lastAcceptedEventAt ?? retiredAt
        guard retiredAt.timeIntervalSinceReferenceDate.isFinite,
              eventDate.timeIntervalSinceReferenceDate.isFinite,
              eventDate <= retiredAt else {
            throw DeveloperToolThreadAdmissionError.invalidRetirementMetadata
        }

        // Work on a candidate so a malformed multi-owner Session cannot leave
        // an earlier identity retired when a later identity fails admission.
        var candidate = self
        let identities = session.developerToolOwnershipIdentities.sorted {
            if $0.tool != $1.tool { return $0.tool.rawValue < $1.tool.rawValue }
            return $0.externalSessionID < $1.externalSessionID
        }
        let activeOwnersBeingRetired = candidate.developerToolOwnershipIdentities
            .intersection(identities)
        let capacityAfterOwnerRemoval = candidate.developerToolThreadCapacityUsed(at: retiredAt)
            - activeOwnersBeingRetired.count
        var newlyRetiredIdentities = Set<DeveloperToolThreadIdentity>()
        for identity in identities {
            if candidate.reservedDeveloperToolOwnershipIdentities.contains(identity) {
                try candidate.retireDeveloperToolOwner(
                    tool: identity.tool,
                    externalSessionID: identity.externalSessionID,
                    retiredAt: retiredAt,
                    lastAcceptedEventAt: eventDate
                )
            } else {
                // A pre-schema-3 active automated Session may not have a
                // reservation record yet. Its active metadata already held a
                // capacity slot, so conversion after removing that Session is
                // still safe and deterministic.
                candidate.pruneExpiredRetiredDeveloperToolThreads(at: retiredAt)
                var processing = candidate.developerToolIntegration ?? DeveloperToolIntegrationProcessingState()
                guard !processing.retiredDeveloperToolThreads.contains(where: { $0.identity == identity }) else {
                    continue
                }
                guard capacityAfterOwnerRemoval + newlyRetiredIdentities.count + 1 <=
                    ConcurrentSessionLimits.maximumProtectedDeveloperToolThreads else {
                    throw DeveloperToolThreadAdmissionError.capacityExceeded
                }
                processing.retiredDeveloperToolThreads.append(RetiredDeveloperToolThread(
                    tool: identity.tool,
                    externalSessionID: identity.externalSessionID,
                    retiredAt: retiredAt,
                    lastAcceptedEventAt: eventDate
                ))
                candidate.developerToolIntegration = processing
                newlyRetiredIdentities.insert(identity)
            }
        }
        self = candidate
    }

    private func validIdentity(tool: DeveloperTool, externalSessionID: String) -> DeveloperToolThreadIdentity? {
        let identity = DeveloperToolThreadIdentity(tool: tool, externalSessionID: externalSessionID)
        return identity.isValid ? identity : nil
    }
}

/// Reconciles repository-wide Git deltas using the actual successful
/// observation windows recorded on each Session. This is a derived property:
/// it may suppress numeric values on more than one Session, but it never
/// changes lifecycle, timeline, ownership, or outcome fields.
enum GitObservationAttributionResolver {
    private struct Observation {
        let id: UUID
        let repositoryRoot: String
        let startedAt: Date?
        let endedAt: Date?
        let attribution: GitDeltaAttribution?
    }

    static func reconcile(_ state: inout AppState) {
        let observations: [Observation] = state.activeSessions.compactMap { session in
            guard let context = session.gitContext,
                  !context.repositoryRoot.isEmpty else { return nil }
            return Observation(
                id: session.id,
                repositoryRoot: canonicalRoot(context.repositoryRoot),
                startedAt: context.observationStartedAt,
                endedAt: context.observationEndedAt,
                attribution: context.deltaAttribution
            )
        } + state.completedSessions.compactMap { session in
            guard let context = session.gitContext,
                  !context.repositoryRoot.isEmpty else { return nil }
            return Observation(
                id: session.id,
                repositoryRoot: canonicalRoot(context.repositoryRoot),
                startedAt: context.observationStartedAt,
                endedAt: context.observationEndedAt,
                attribution: context.deltaAttribution
            )
        }

        var ambiguousIDs = Set(observations.filter { $0.attribution == .ambiguous }.map(\.id))
        for leftIndex in observations.indices {
            guard leftIndex + 1 < observations.count else { continue }
            let left = observations[leftIndex]
            for right in observations[(leftIndex + 1)...] {
                guard left.repositoryRoot == right.repositoryRoot else { continue }
                guard left.id != right.id else { continue }
                if windowsMayOverlap(left, right) {
                    ambiguousIDs.insert(left.id)
                    ambiguousIDs.insert(right.id)
                }
            }
        }

        for index in state.activeSessions.indices {
            guard var context = state.activeSessions[index].gitContext else { continue }
            if ambiguousIDs.contains(state.activeSessions[index].id) {
                suppressNumericDeltas(in: &context, attribution: .ambiguous)
            } else if context.deltaAttribution == .indeterminate {
                suppressNumericDeltas(in: &context, attribution: .indeterminate)
            } else if !context.hasCompleteObservationWindow,
                      context.deltaAttribution == .attributable || hasNumericDelta(in: context) {
                suppressNumericDeltas(in: &context, attribution: .indeterminate)
            } else if context.deltaAttribution == nil,
                      context.hasCompleteObservationWindow {
                context.deltaAttribution = .attributable
            }
            state.activeSessions[index].gitContext = context
        }

        for index in state.completedSessions.indices {
            guard var context = state.completedSessions[index].gitContext else { continue }
            guard ambiguousIDs.contains(state.completedSessions[index].id) ||
                    context.deltaAttribution == .indeterminate ||
                    (context.deltaAttribution == nil && context.hasCompleteObservationWindow) ||
                    !context.hasCompleteObservationWindow else {
                continue
            }

            if ambiguousIDs.contains(state.completedSessions[index].id) {
                suppressNumericDeltas(in: &context, attribution: .ambiguous)
            } else if context.deltaAttribution == .indeterminate {
                suppressNumericDeltas(in: &context, attribution: .indeterminate)
            } else if !context.hasCompleteObservationWindow {
                suppressNumericDeltas(in: &context, attribution: .indeterminate)
            } else if context.deltaAttribution == nil {
                context.deltaAttribution = .attributable
            }
            let existing = state.completedSessions[index]
            state.completedSessions[index] = CompletedSession(
                id: existing.id,
                projectID: existing.projectID,
                projectName: existing.projectName,
                type: existing.type,
                goal: existing.goal,
                outcome: existing.outcome,
                startedAt: existing.startedAt,
                endedAt: existing.endedAt,
                pauseIntervals: existing.pauseIntervals,
                gitContext: context,
                githubContext: existing.githubContext,
                developerToolContexts: existing.developerToolContexts
            )
        }
    }

    private static func windowsMayOverlap(_ left: Observation, _ right: Observation) -> Bool {
        // A missing or failed boundary is indeterminate. The conservative
        // answer is ambiguity whenever another Session observes the same
        // canonical repository.
        guard let leftStart = left.startedAt,
              let leftEnd = left.endedAt,
              let rightStart = right.startedAt,
              let rightEnd = right.endedAt,
              leftStart.timeIntervalSinceReferenceDate.isFinite,
              leftEnd.timeIntervalSinceReferenceDate.isFinite,
              rightStart.timeIntervalSinceReferenceDate.isFinite,
              rightEnd.timeIntervalSinceReferenceDate.isFinite,
              leftStart <= leftEnd,
              rightStart <= rightEnd else {
            return true
        }

        // Observation boundaries are closed: touching endpoints are treated
        // as intersecting because a repository-wide mutation at that instant
        // could be visible to both snapshots.
        return leftStart <= rightEnd && rightStart <= leftEnd
    }

    private static func canonicalRoot(_ value: String) -> String {
        let url = URL(fileURLWithPath: value, isDirectory: true)
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func suppressNumericDeltas(
        in context: inout GitSessionContext,
        attribution: GitDeltaAttribution
    ) {
        context.commitCount = nil
        context.filesChanged = nil
        context.insertions = nil
        context.deletions = nil
        context.deltaAttribution = attribution
    }

    private static func hasNumericDelta(in context: GitSessionContext) -> Bool {
        context.commitCount != nil ||
            context.filesChanged != nil ||
            context.insertions != nil ||
            context.deletions != nil
    }
}

extension AppState {
    /// Public domain entry point for deterministic tests and enrichment code.
    /// Callers should invoke this on a candidate state before persistence.
    mutating func reconcileGitObservationAttribution() {
        GitObservationAttributionResolver.reconcile(&self)
    }
}
