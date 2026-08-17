import Foundation

/// Shared, non-mutating presence semantics for journal text.
enum MeaningfulText {
    static func exists(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
