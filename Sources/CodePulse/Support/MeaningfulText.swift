import Foundation

/// Shared, non-mutating presence semantics for journal text.
enum MeaningfulText {
    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    static func exists(_ value: String?) -> Bool {
        normalized(value) != nil
    }
}
