import CodePulseIntegration
import Foundation

struct SessionPreset: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var projectID: UUID?
    var sessionType: SessionType
    var goal: String?

    private enum CodingKeys: String, CodingKey {
        case id, name, projectID, sessionType, goal
    }

    init(
        id: UUID = UUID(),
        name: String,
        projectID: UUID? = nil,
        sessionType: SessionType = .coding,
        goal: String? = nil
    ) {
        self.id = id
        self.name = Self.cleanName(name)
        self.projectID = projectID
        self.sessionType = sessionType
        self.goal = Self.cleanOptionalText(goal)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "Session Preset",
            projectID: try container.decodeIfPresent(UUID.self, forKey: .projectID),
            sessionType: try container.decodeIfPresent(SessionType.self, forKey: .sessionType) ?? .coding,
            goal: try container.decodeIfPresent(String.self, forKey: .goal)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(projectID, forKey: .projectID)
        try container.encode(sessionType, forKey: .sessionType)
        try container.encodeIfPresent(goal, forKey: .goal)
    }

    /// A small source-compatible alias for callers that use the session model's
    /// shorter terminology. It is not a separate persisted field.
    var type: SessionType {
        get { sessionType }
        set { sessionType = newValue }
    }

    var isValid: Bool {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty,
              cleanName.count <= 200 else {
            return false
        }
        return cleanName.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
    }

    private static func cleanName(_ value: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "Session Preset" }
        return String(cleaned.prefix(200))
    }

    private static func cleanOptionalText(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : String(cleaned.prefix(4_096))
    }
}

struct ApplicationIdentity: Codable, Equatable, Hashable, Identifiable, Sendable {
    var bundleIdentifier: String
    var displayName: String

    init(bundleIdentifier: String, displayName: String) {
        let normalizedBundleIdentifier = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.bundleIdentifier = String(normalizedBundleIdentifier.prefix(512))
        self.displayName = String((normalizedDisplayName.isEmpty ? normalizedBundleIdentifier : normalizedDisplayName).prefix(200))
    }

    var id: String { bundleIdentifier }

    var isValid: Bool {
        !bundleIdentifier.isEmpty &&
            !bundleIdentifier.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) })
    }
}

struct ApplicationAutomationTrigger: Codable, Equatable, Sendable {
    var applications: [ApplicationIdentity]

    init(applications: [ApplicationIdentity]) {
        var seen = Set<String>()
        self.applications = applications.filter { application in
            guard application.isValid, seen.insert(application.bundleIdentifier).inserted else { return false }
            return true
        }
    }

    private enum CodingKeys: String, CodingKey {
        case applications
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(applications: try container.decodeIfPresent([ApplicationIdentity].self, forKey: .applications) ?? [])
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(applications, forKey: .applications)
    }

    var isValid: Bool {
        !applications.isEmpty && applications.allSatisfy(\.isValid)
    }

    func matches(bundleIdentifier: String) -> Bool {
        applications.contains { $0.bundleIdentifier == bundleIdentifier }
    }

    func displayName(for bundleIdentifier: String) -> String? {
        applications.first(where: { $0.bundleIdentifier == bundleIdentifier })?.displayName
    }
}

enum SessionAutomationTrigger: Codable, Equatable, Sendable {
    case developerTool(DeveloperTool)
    case applications(ApplicationAutomationTrigger)

    private enum CodingKeys: String, CodingKey {
        case kind
        case developerTool
        case applications
    }

    private enum Kind: String, Codable {
        case developerTool
        case applications
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .developerTool:
            self = .developerTool(try container.decode(DeveloperTool.self, forKey: .developerTool))
        case .applications:
            self = .applications(try container.decode(ApplicationAutomationTrigger.self, forKey: .applications))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .developerTool(let tool):
            try container.encode(Kind.developerTool, forKey: .kind)
            try container.encode(tool, forKey: .developerTool)
        case .applications(let trigger):
            try container.encode(Kind.applications, forKey: .kind)
            try container.encode(trigger, forKey: .applications)
        }
    }

    var developerTool: DeveloperTool? {
        if case .developerTool(let tool) = self { return tool }
        return nil
    }

    var applicationTrigger: ApplicationAutomationTrigger? {
        if case .applications(let trigger) = self { return trigger }
        return nil
    }
}

enum SessionAutomationClaimSource: Codable, Equatable, Hashable, Sendable {
    case developerTool(tool: DeveloperTool, externalSessionID: String)
    case application(bundleIdentifier: String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case tool
        case externalSessionID
        case bundleIdentifier
    }

    private enum Kind: String, Codable {
        case developerTool
        case application
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .developerTool:
            self = .developerTool(
                tool: try container.decode(DeveloperTool.self, forKey: .tool),
                externalSessionID: try container.decode(String.self, forKey: .externalSessionID)
            )
        case .application:
            self = .application(bundleIdentifier: try container.decode(String.self, forKey: .bundleIdentifier))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .developerTool(let tool, let externalSessionID):
            try container.encode(Kind.developerTool, forKey: .kind)
            try container.encode(tool, forKey: .tool)
            try container.encode(externalSessionID, forKey: .externalSessionID)
        case .application(let bundleIdentifier):
            try container.encode(Kind.application, forKey: .kind)
            try container.encode(bundleIdentifier, forKey: .bundleIdentifier)
        }
    }

    var id: String {
        switch self {
        case .developerTool(let tool, let externalSessionID):
            return "developerTool:\(tool.rawValue):\(externalSessionID)"
        case .application(let bundleIdentifier):
            return "application:\(bundleIdentifier)"
        }
    }

    var developerTool: DeveloperTool? {
        if case .developerTool(let tool, _) = self { return tool }
        return nil
    }
}

struct SessionAutomationRule: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var isEnabled: Bool
    var trigger: SessionAutomationTrigger
    var presetID: UUID
    var pauseDelay: TimeInterval
    var finishDelay: TimeInterval
    var minimumSavedDuration: TimeInterval

    // These fields are deliberately excluded from canonical encoding. They
    // exist only so old callers and direct legacy-rule decoding can be kept
    // source-compatible while AppState normalizes the rule into a preset.
    private var legacyPresetDetails: SessionPreset?

    init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        trigger: SessionAutomationTrigger,
        presetID: UUID,
        pauseDelay: TimeInterval = 60,
        finishDelay: TimeInterval = 300,
        minimumSavedDuration: TimeInterval = 60
    ) {
        self.id = id
        self.name = Self.cleanName(name)
        self.isEnabled = isEnabled
        self.trigger = trigger
        self.presetID = presetID
        self.pauseDelay = max(0, pauseDelay)
        self.finishDelay = max(0, finishDelay)
        self.minimumSavedDuration = max(0, minimumSavedDuration)
        self.legacyPresetDetails = nil
    }

    /// Compatibility initializer for Milestone 1 callers. AppState converts
    /// the embedded configuration into a stable preset and clears this
    /// compatibility payload before saving.
    init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        trigger: SessionAutomationTrigger,
        projectID: UUID,
        sessionType: SessionType = .coding,
        goal: String? = nil,
        pauseDelay: TimeInterval = 60,
        finishDelay: TimeInterval = 300,
        minimumSavedDuration: TimeInterval = 60
    ) {
        let presetID = Self.deterministicPresetID(for: id)
        self.init(
            id: id,
            name: name,
            isEnabled: isEnabled,
            trigger: trigger,
            presetID: presetID,
            pauseDelay: pauseDelay,
            finishDelay: finishDelay,
            minimumSavedDuration: minimumSavedDuration
        )
        self.legacyPresetDetails = SessionPreset(
            id: presetID,
            name: name,
            projectID: projectID,
            sessionType: sessionType,
            goal: goal
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, trigger, presetID
        case projectID, sessionType, goal
        case pauseDelay, finishDelay, minimumSavedDuration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Automation Rule"
        let isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        let trigger = try container.decode(SessionAutomationTrigger.self, forKey: .trigger)
        let pauseDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .pauseDelay) ?? 60
        let finishDelay = try container.decodeIfPresent(TimeInterval.self, forKey: .finishDelay) ?? 300
        let minimumSavedDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .minimumSavedDuration) ?? 60

        if let projectID = try container.decodeIfPresent(UUID.self, forKey: .projectID) {
            self.init(
                id: id,
                name: name,
                isEnabled: isEnabled,
                trigger: trigger,
                projectID: projectID,
                sessionType: try container.decodeIfPresent(SessionType.self, forKey: .sessionType) ?? .coding,
                goal: try container.decodeIfPresent(String.self, forKey: .goal),
                pauseDelay: pauseDelay,
                finishDelay: finishDelay,
                minimumSavedDuration: minimumSavedDuration
            )
        } else {
            self.init(
                id: id,
                name: name,
                isEnabled: isEnabled,
                trigger: trigger,
                presetID: try container.decode(UUID.self, forKey: .presetID),
                pauseDelay: pauseDelay,
                finishDelay: finishDelay,
                minimumSavedDuration: minimumSavedDuration
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(trigger, forKey: .trigger)
        try container.encode(presetID, forKey: .presetID)
        try container.encode(pauseDelay, forKey: .pauseDelay)
        try container.encode(finishDelay, forKey: .finishDelay)
        try container.encode(minimumSavedDuration, forKey: .minimumSavedDuration)

        // Direct encoding of a rule created through the old initializer still
        // round-trips for clients that decode individual rules. AppState's
        // canonicalization clears this payload before normal state is saved.
        if let legacyPresetDetails {
            try container.encode(legacyPresetDetails.projectID, forKey: .projectID)
            try container.encode(legacyPresetDetails.sessionType, forKey: .sessionType)
            try container.encodeIfPresent(legacyPresetDetails.goal, forKey: .goal)
        }
    }

    static func == (lhs: SessionAutomationRule, rhs: SessionAutomationRule) -> Bool {
        lhs.id == rhs.id &&
            lhs.name == rhs.name &&
            lhs.isEnabled == rhs.isEnabled &&
            lhs.trigger == rhs.trigger &&
            lhs.presetID == rhs.presetID &&
            lhs.pauseDelay == rhs.pauseDelay &&
            lhs.finishDelay == rhs.finishDelay &&
            lhs.minimumSavedDuration == rhs.minimumSavedDuration
    }

    var developerTool: DeveloperTool? { trigger.developerTool }
    var applicationTrigger: ApplicationAutomationTrigger? { trigger.applicationTrigger }

    var isValid: Bool {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty,
              cleanName.count <= 200,
              cleanName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              pauseDelay.isFinite,
              finishDelay.isFinite,
              minimumSavedDuration.isFinite,
              pauseDelay >= 0,
              finishDelay >= pauseDelay,
              minimumSavedDuration >= 0 else {
            return false
        }

        switch trigger {
        case .developerTool:
            return true
        case .applications(let trigger):
            return trigger.isValid
        }
    }

    // Source-compatible accessors for Milestone 1 code. Canonical rules use
    // SessionStore/AppState to resolve their preset rather than these values.
    var projectID: UUID? { legacyPresetDetails?.projectID }
    var sessionType: SessionType { legacyPresetDetails?.sessionType ?? .coding }
    var goal: String? { legacyPresetDetails?.goal }

    var legacyPreset: SessionPreset? { legacyPresetDetails }

    func canonicalized() -> SessionAutomationRule {
        var copy = self
        copy.legacyPresetDetails = nil
        return copy
    }

    private static func cleanName(_ value: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "Automation Rule" }
        return String(cleaned.prefix(200))
    }

    private static func deterministicPresetID(for ruleID: UUID) -> UUID {
        var bytes = withUnsafeBytes(of: ruleID.uuid) { Array($0) }
        // UUID version 5/variant bits make the generated value recognizable as
        // a deterministic migration identifier while preserving the rule's
        // stable identity across launches.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

struct SessionAutomationClaim: Codable, Equatable, Identifiable, Sendable {
    var source: SessionAutomationClaimSource
    var isActive: Bool
    var lastSignalAt: Date

    init(
        source: SessionAutomationClaimSource,
        isActive: Bool,
        lastSignalAt: Date
    ) {
        self.source = source
        self.isActive = isActive
        self.lastSignalAt = lastSignalAt
    }

    init(
        tool: DeveloperTool,
        externalSessionID: String,
        isActive: Bool,
        lastSignalAt: Date
    ) {
        self.init(
            source: .developerTool(tool: tool, externalSessionID: externalSessionID),
            isActive: isActive,
            lastSignalAt: lastSignalAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case source
        case tool
        case externalSessionID
        case isActive
        case lastSignalAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let source = try container.decodeIfPresent(SessionAutomationClaimSource.self, forKey: .source) {
            self.init(
                source: source,
                isActive: try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true,
                lastSignalAt: try container.decode(Date.self, forKey: .lastSignalAt)
            )
        } else {
            self.init(
                tool: try container.decode(DeveloperTool.self, forKey: .tool),
                externalSessionID: try container.decode(String.self, forKey: .externalSessionID),
                isActive: try container.decodeIfPresent(Bool.self, forKey: .isActive) ?? true,
                lastSignalAt: try container.decode(Date.self, forKey: .lastSignalAt)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(isActive, forKey: .isActive)
        try container.encode(lastSignalAt, forKey: .lastSignalAt)
    }

    var id: String { source.id }

    // Compatibility accessors for Milestone 1 callers.
    var tool: DeveloperTool? { source.developerTool }
    var externalSessionID: String? {
        if case .developerTool(_, let externalSessionID) = source { return externalSessionID }
        return nil
    }
}

struct SessionAutomationMetadata: Codable, Equatable, Sendable {
    let startedByRuleID: UUID
    let startedByRuleName: String?
    var startedBySource: SessionAutomationClaimSource
    var controlEnabled: Bool
    var lastMatchingSignalAt: Date
    var pauseEligibleAt: Date?
    var finishEligibleAt: Date?
    var pendingAutomaticSave: Bool
    var pauseDelay: TimeInterval
    var finishDelay: TimeInterval
    var minimumSavedDuration: TimeInterval
    var claims: [SessionAutomationClaim]

    init(
        startedByRuleID: UUID,
        startedByRuleName: String?,
        startedBySource: SessionAutomationClaimSource,
        controlEnabled: Bool = true,
        lastMatchingSignalAt: Date,
        pauseEligibleAt: Date? = nil,
        finishEligibleAt: Date? = nil,
        pendingAutomaticSave: Bool = false,
        pauseDelay: TimeInterval,
        finishDelay: TimeInterval,
        minimumSavedDuration: TimeInterval,
        claims: [SessionAutomationClaim] = []
    ) {
        self.startedByRuleID = startedByRuleID
        self.startedByRuleName = startedByRuleName
        self.startedBySource = startedBySource
        self.controlEnabled = controlEnabled
        self.lastMatchingSignalAt = lastMatchingSignalAt
        self.pauseEligibleAt = pauseEligibleAt
        self.finishEligibleAt = finishEligibleAt
        self.pendingAutomaticSave = pendingAutomaticSave
        self.pauseDelay = max(0, pauseDelay)
        self.finishDelay = max(self.pauseDelay, finishDelay)
        self.minimumSavedDuration = max(0, minimumSavedDuration)
        self.claims = Self.normalizedClaims(claims)
    }

    init(
        startedByRuleID: UUID,
        startedByRuleName: String?,
        startedByTool: DeveloperTool,
        controlEnabled: Bool = true,
        lastMatchingSignalAt: Date,
        pauseEligibleAt: Date? = nil,
        finishEligibleAt: Date? = nil,
        pendingAutomaticSave: Bool = false,
        pauseDelay: TimeInterval,
        finishDelay: TimeInterval,
        minimumSavedDuration: TimeInterval,
        claims: [SessionAutomationClaim] = []
    ) {
        let externalSessionID = claims.compactMap { claim -> String? in
            guard case .developerTool(let tool, let externalSessionID) = claim.source,
                  tool == startedByTool,
                  !externalSessionID.isEmpty else {
                return nil
            }
            return externalSessionID
        }.first ?? ""
        self.init(
            startedByRuleID: startedByRuleID,
            startedByRuleName: startedByRuleName,
            startedBySource: .developerTool(tool: startedByTool, externalSessionID: externalSessionID),
            controlEnabled: controlEnabled,
            lastMatchingSignalAt: lastMatchingSignalAt,
            pauseEligibleAt: pauseEligibleAt,
            finishEligibleAt: finishEligibleAt,
            pendingAutomaticSave: pendingAutomaticSave,
            pauseDelay: pauseDelay,
            finishDelay: finishDelay,
            minimumSavedDuration: minimumSavedDuration,
            claims: claims
        )
    }

    private enum CodingKeys: String, CodingKey {
        case startedByRuleID, startedByRuleName, startedBySource, startedByTool
        case controlEnabled, lastMatchingSignalAt, pauseEligibleAt, finishEligibleAt
        case pendingAutomaticSave, pauseDelay, finishDelay, minimumSavedDuration, claims
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let startedBySource: SessionAutomationClaimSource
        if let source = try container.decodeIfPresent(SessionAutomationClaimSource.self, forKey: .startedBySource) {
            startedBySource = source
        } else {
            startedBySource = .developerTool(
                tool: try container.decode(DeveloperTool.self, forKey: .startedByTool),
                externalSessionID: ""
            )
        }
        self.init(
            startedByRuleID: try container.decode(UUID.self, forKey: .startedByRuleID),
            startedByRuleName: try container.decodeIfPresent(String.self, forKey: .startedByRuleName),
            startedBySource: startedBySource,
            controlEnabled: try container.decodeIfPresent(Bool.self, forKey: .controlEnabled) ?? true,
            lastMatchingSignalAt: try container.decode(Date.self, forKey: .lastMatchingSignalAt),
            pauseEligibleAt: try container.decodeIfPresent(Date.self, forKey: .pauseEligibleAt),
            finishEligibleAt: try container.decodeIfPresent(Date.self, forKey: .finishEligibleAt),
            pendingAutomaticSave: try container.decodeIfPresent(Bool.self, forKey: .pendingAutomaticSave) ?? false,
            pauseDelay: try container.decodeIfPresent(TimeInterval.self, forKey: .pauseDelay) ?? 60,
            finishDelay: try container.decodeIfPresent(TimeInterval.self, forKey: .finishDelay) ?? 300,
            minimumSavedDuration: try container.decodeIfPresent(TimeInterval.self, forKey: .minimumSavedDuration) ?? 60,
            claims: try container.decodeIfPresent([SessionAutomationClaim].self, forKey: .claims) ?? []
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startedByRuleID, forKey: .startedByRuleID)
        try container.encodeIfPresent(startedByRuleName, forKey: .startedByRuleName)
        try container.encode(startedBySource, forKey: .startedBySource)
        try container.encode(controlEnabled, forKey: .controlEnabled)
        try container.encode(lastMatchingSignalAt, forKey: .lastMatchingSignalAt)
        try container.encodeIfPresent(pauseEligibleAt, forKey: .pauseEligibleAt)
        try container.encodeIfPresent(finishEligibleAt, forKey: .finishEligibleAt)
        try container.encode(pendingAutomaticSave, forKey: .pendingAutomaticSave)
        try container.encode(pauseDelay, forKey: .pauseDelay)
        try container.encode(finishDelay, forKey: .finishDelay)
        try container.encode(minimumSavedDuration, forKey: .minimumSavedDuration)
        try container.encode(claims, forKey: .claims)
    }

    var startedByTool: DeveloperTool? { startedBySource.developerTool }

    var statusToolCount: Int {
        Set(claims.compactMap(\.tool)).count
    }

    func statusLabel(contexts: [DeveloperToolSessionContext]) -> String {
        let activeClaims = claims.filter(\.isActive)
        let tools = Set(activeClaims.compactMap(\.tool)).union(contexts.map(\.tool))
        let applications = Set(activeClaims.compactMap { claim -> String? in
            if case .application(let bundleIdentifier) = claim.source { return bundleIdentifier }
            return nil
        })

        if tools.count == 1, applications.isEmpty, let tool = tools.first {
            return "Automatic · " + tool.title
        }
        if tools.isEmpty, applications.count == 1 {
            return "Automatic · Application"
        }
        if tools.isEmpty, applications.isEmpty, let tool = startedByTool {
            return "Automatic · " + tool.title
        }
        if tools.isEmpty, applications.isEmpty,
           case .application = startedBySource {
            return "Automatic · Application"
        }
        return "Automatic · Multiple"
    }

    private static func normalizedClaims(_ claims: [SessionAutomationClaim]) -> [SessionAutomationClaim] {
        var indexes: [String: Int] = [:]
        var normalized: [SessionAutomationClaim] = []
        for claim in claims {
            if let index = indexes[claim.id] {
                var merged = normalized[index]
                merged.isActive = claim.isActive
                merged.lastSignalAt = max(merged.lastSignalAt, claim.lastSignalAt)
                normalized[index] = merged
            } else if normalized.count < 64 {
                indexes[claim.id] = normalized.count
                normalized.append(claim)
            }
        }
        return normalized
    }
}
