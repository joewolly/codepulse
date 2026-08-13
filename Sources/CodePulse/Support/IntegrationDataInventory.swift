import CodePulseIntegration
import Foundation

/// Human-readable inventory for the local integration boundary. These labels
/// deliberately describe categories, never source paths or identifiers.
struct IntegrationDataInventoryItem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
}

enum IntegrationDataInventory {
    static let items = [
        IntegrationDataInventoryItem(
            id: "timing",
            title: "Agent timing",
            detail: "Integration, salted session identity, lifecycle state, and interval timestamps."
        ),
        IntegrationDataInventoryItem(
            id: "usage",
            title: "Optional usage",
            detail: "Salted source identity, model/service labels, token counters, reported cost, and pricing provenance."
        ),
        IntegrationDataInventoryItem(
            id: "diagnostics",
            title: "Diagnostics",
            detail: "Bounded receipt status, fixed rejection codes, parser versions, and salted event fingerprints."
        ),
        IntegrationDataInventoryItem(
            id: "local-only",
            title: "Never retained",
            detail: "Prompts, responses, transcripts, source content, commands, tool payloads, credentials, and raw external identifiers."
        )
    ]
}

extension DeveloperTool {
    var eventIntegrationRawValue: String { rawValue }
}
