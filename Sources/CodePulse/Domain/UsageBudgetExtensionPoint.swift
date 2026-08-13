import Foundation

/// Reserved schema for a later, separately approved budgets feature. This
/// type is deliberately not referenced by AppState, settings, calculators, or
/// views: Feature 18 ships no policies, alerts, enforcement, or persistence.
struct UsageBudgetPolicy: Codable, Equatable {
    let id: UUID
    let createdAt: Date
    let integration: String?
    let currency: String
    let threshold: Decimal

    init(
        id: UUID = UUID(),
        createdAt: Date,
        integration: String? = nil,
        currency: String,
        threshold: Decimal
    ) {
        self.id = id
        self.createdAt = createdAt
        self.integration = integration
        self.currency = currency
        self.threshold = threshold
    }
}

enum UsageBudgetExtensionPoint {
    static let isEnabled = false
    static let implementationStatus = "reserved-only"
}
