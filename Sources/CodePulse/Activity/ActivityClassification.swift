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
        let workTypeMatch = workTypeMatch(for: event)
        let domainMatch = domainMatch(event: event, workspace: workspace)
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

    private static func workTypeMatch(for event: DeveloperEventV2) -> (value: SessionType, confidence: ActivityClassificationConfidence, evidence: ActivityClassificationEvidenceCategory) {
        switch event.metadata?.actionCategory {
        case .debugging: return (.debugging, .high, .actionCategory)
        case .planning: return (.planning, .high, .actionCategory)
        case .review: return (.review, .high, .actionCategory)
        case .research: return (.research, .high, .actionCategory)
        default: break
        }
        return (.coding, .low, .lifecycle)
    }

    private static func domainMatch(
        event: DeveloperEventV2,
        workspace: Workspace?
    ) -> (value: ActivityDomain, confidence: ActivityClassificationConfidence, evidence: ActivityClassificationEvidenceCategory) {
        switch event.metadata?.actionCategory {
        case .fileOrganization: return (.fileOrganization, .high, .actionCategory)
        case .automation: return (.automation, .high, .actionCategory)
        case .administration: return (.administration, .high, .actionCategory)
        case .documentation: return (.documentation, .high, .actionCategory)
        default: break
        }
        switch event.metadata?.fileType {
        case .documentation: return (.documentation, .medium, .fileType)
        case .automation: return (.automation, .medium, .fileType)
        case .configuration: return (.administration, .medium, .fileType)
        default: break
        }
        if workspace?.source == .transientLocalTask || workspace?.localTaskIdentity != nil { return (.localTask, .medium, .workspace) }
        return (.development, .low, .lifecycle)
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
        case .userOverride: return 1
        }
    }
}
