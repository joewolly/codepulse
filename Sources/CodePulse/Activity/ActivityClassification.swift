import CodePulseIntegration
import Foundation

/// A durable, content-free explanation of how an activity label was chosen.
/// Values are deliberately constrained to the two existing activity dimensions.
enum ActivityClassificationDimension: String, Codable, CaseIterable, Equatable {
    case workType
    case activityDomain
}

enum ActivityClassificationSource: String, Codable, CaseIterable, Equatable {
    case metadata
    case ephemeralPrompt
    case userOverride
}

enum ActivityClassificationConfidence: String, Codable, CaseIterable, Equatable {
    case low
    case medium
    case high
}

enum ActivityClassificationEvidenceCategory: String, Codable, CaseIterable, Equatable {
    case lifecycle
    case toolMetadata
    case workspace
    case fileType
    case actionCategory
    case ephemeralPrompt
    case userCorrection
}

struct ActivityClassification: Codable, Equatable, Identifiable {
    let id: UUID
    let dimension: ActivityClassificationDimension
    let value: String
    let source: ActivityClassificationSource
    let confidence: ActivityClassificationConfidence
    let classifiedAt: Date
    let evidenceCategory: ActivityClassificationEvidenceCategory

    init?(
        id: UUID = UUID(),
        dimension: ActivityClassificationDimension,
        value: String,
        source: ActivityClassificationSource,
        confidence: ActivityClassificationConfidence,
        classifiedAt: Date,
        evidenceCategory: ActivityClassificationEvidenceCategory
    ) {
        guard Self.isValid(value: value, for: dimension) else { return nil }
        self.id = id
        self.dimension = dimension
        self.value = value
        self.source = source
        self.confidence = confidence
        self.classifiedAt = classifiedAt
        self.evidenceCategory = evidenceCategory
    }

    static func isValid(value: String, for dimension: ActivityClassificationDimension) -> Bool {
        switch dimension {
        case .workType:
            return SessionType(rawValue: value) != nil
        case .activityDomain:
            return ActivityDomain(rawValue: value) != nil
        }
    }

    var workType: SessionType? {
        guard dimension == .workType else { return nil }
        return SessionType(rawValue: value)
    }

    var domain: ActivityDomain? {
        guard dimension == .activityDomain else { return nil }
        return ActivityDomain(rawValue: value)
    }

    private enum CodingKeys: String, CodingKey {
        case id, dimension, value, source, confidence, classifiedAt, evidenceCategory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let dimension = try container.decode(ActivityClassificationDimension.self, forKey: .dimension)
        let value = try container.decode(String.self, forKey: .value)
        let source = try container.decode(ActivityClassificationSource.self, forKey: .source)
        let confidence = try container.decode(ActivityClassificationConfidence.self, forKey: .confidence)
        let classifiedAt = try container.decode(Date.self, forKey: .classifiedAt)
        let evidenceCategory = try container.decode(ActivityClassificationEvidenceCategory.self, forKey: .evidenceCategory)
        guard let classification = ActivityClassification(
            id: id,
            dimension: dimension,
            value: value,
            source: source,
            confidence: confidence,
            classifiedAt: classifiedAt,
            evidenceCategory: evidenceCategory
        ) else {
            throw DecodingError.dataCorruptedError(forKey: .value, in: container, debugDescription: "Classification value does not match its dimension")
        }
        self = classification
    }
}

struct ActivityClassificationRuleEngine {
    static func metadataClassifications(
        event: DeveloperEventV2,
        workspace: Workspace
    ) -> [ActivityClassification] {
        let signals = metadataSignals(event: event)
        let workTypeMatch = workTypeMatch(for: signals)
        let domainMatch = domainMatch(for: signals, workspace: workspace, workingDirectory: event.workingDirectory)
        return [
            ActivityClassification(
                dimension: .workType,
                value: workTypeMatch.value.rawValue,
                source: .metadata,
                confidence: workTypeMatch.confidence,
                classifiedAt: event.observedAt,
                evidenceCategory: workTypeMatch.evidence
            ),
            ActivityClassification(
                dimension: .activityDomain,
                value: domainMatch.value.rawValue,
                source: .metadata,
                confidence: domainMatch.confidence,
                classifiedAt: event.observedAt,
                evidenceCategory: domainMatch.evidence
            )
        ].compactMap { $0 }
    }

    /// This intentionally accepts text only at the call site. The resulting
    /// records retain a coarse source category, never a token, excerpt, hash,
    /// or any other representation of the prompt.
    static func ephemeralPromptClassifications(_ prompt: String, at date: Date) -> [ActivityClassification] {
        let signals = prompt.lowercased()
        let workTypeMatch = workTypeMatch(for: signals)
        let domainMatch = domainMatch(for: signals, workspace: nil, workingDirectory: nil)
        return [
            ActivityClassification(
                dimension: .workType,
                value: workTypeMatch.value.rawValue,
                source: .ephemeralPrompt,
                confidence: workTypeMatch.confidence,
                classifiedAt: date,
                evidenceCategory: .ephemeralPrompt
            ),
            ActivityClassification(
                dimension: .activityDomain,
                value: domainMatch.value.rawValue,
                source: .ephemeralPrompt,
                confidence: domainMatch.confidence,
                classifiedAt: date,
                evidenceCategory: .ephemeralPrompt
            )
        ].compactMap { $0 }
    }

    private static func metadataSignals(event: DeveloperEventV2) -> String {
        [event.eventKind.rawValue, event.metadata?.sourceKind, event.model, event.effort, event.serviceMode]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
    }

    private static func workTypeMatch(for signals: String) -> (value: SessionType, confidence: ActivityClassificationConfidence, evidence: ActivityClassificationEvidenceCategory) {
        if containsAny(signals, ["review", "approve", "audit", "diff"]) { return (.review, .high, .toolMetadata) }
        if containsAny(signals, ["debug", "fix", "error", "failure", "test"]) { return (.debugging, .high, .actionCategory) }
        if containsAny(signals, ["plan", "design", "architect", "proposal"]) { return (.planning, .high, .actionCategory) }
        if containsAny(signals, ["research", "investigate", "explore", "compare"]) { return (.research, .high, .actionCategory) }
        return (.coding, .low, .lifecycle)
    }

    private static func domainMatch(
        for signals: String,
        workspace: Workspace?,
        workingDirectory: String?
    ) -> (value: ActivityDomain, confidence: ActivityClassificationConfidence, evidence: ActivityClassificationEvidenceCategory) {
        if containsAny(signals, ["file-organ", "organize", "rename", "move-file"]) { return (.fileOrganization, .high, .actionCategory) }
        if containsAny(signals, ["automation", "workflow", "ci", "script", "build"]) { return (.automation, .high, .actionCategory) }
        if containsAny(signals, ["admin", "setting", "config", "account"]) { return (.administration, .high, .toolMetadata) }
        if containsAny(signals, ["documentation", "readme", "markdown", "docs"]) || hasDocumentationExtension(workingDirectory) { return (.documentation, .high, .fileType) }
        if workspace?.source == .transientLocalTask || workspace?.localTaskIdentity != nil { return (.localTask, .medium, .workspace) }
        return (.development, .low, .lifecycle)
    }

    private static func containsAny(_ value: String, _ terms: [String]) -> Bool {
        terms.contains { value.localizedCaseInsensitiveContains($0) }
    }

    private static func hasDocumentationExtension(_ path: String?) -> Bool {
        guard let path else { return false }
        return ["md", "mdx", "rst", "txt"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
}

extension Activity {
    mutating func applyClassifications(_ incoming: [ActivityClassification]) {
        for classification in incoming {
            classifications.removeAll {
                $0.dimension == classification.dimension && $0.source == classification.source
            }
            classifications.append(classification)
        }
        applyEffectiveClassifications()
    }

    mutating func removeUserOverride(for dimension: ActivityClassificationDimension) {
        classifications.removeAll { $0.dimension == dimension && $0.source == .userOverride }
        applyEffectiveClassifications()
    }

    func effectiveClassification(for dimension: ActivityClassificationDimension) -> ActivityClassification? {
        classifications
            .filter { $0.dimension == dimension }
            .max { lhs, rhs in
                let lhsPriority = Self.priority(for: lhs.source)
                let rhsPriority = Self.priority(for: rhs.source)
                if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
                return lhs.classifiedAt < rhs.classifiedAt
            }
    }

    private mutating func applyEffectiveClassifications() {
        if let workType = effectiveClassification(for: .workType)?.workType { self.workType = workType }
        if let domain = effectiveClassification(for: .activityDomain)?.domain { self.domain = domain }
    }

    private static func priority(for source: ActivityClassificationSource) -> Int {
        switch source {
        case .metadata: return 0
        case .ephemeralPrompt: return 1
        case .userOverride: return 2
        }
    }
}
