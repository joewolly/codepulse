import Foundation

enum LocalInputAcceptance {
    static func accepts(timestamp: Date, after boundary: Date?) -> Bool {
        guard let boundary else { return true }
        return timestamp >= boundary
    }
}
