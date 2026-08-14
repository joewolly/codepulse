import Foundation

enum LocalInputAcceptance {
    static func accepts(timestamp: Date, after boundary: Date?) -> Bool {
        guard let boundary else { return true }
        // ISO-8601 persistence uses whole-second precision here, so equality
        // must remain rejected to prevent same-second replay after relaunch.
        return timestamp > boundary
    }
}
