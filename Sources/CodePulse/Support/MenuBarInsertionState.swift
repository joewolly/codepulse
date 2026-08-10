import Foundation

enum MenuBarInsertionState {
    static let preferenceKey = "menuBarExtraInserted"
    static let defaultInserted = true

    static func isInserted(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: preferenceKey) != nil else {
            return defaultInserted
        }
        return defaults.bool(forKey: preferenceKey)
    }

    static func restoreOnLaunch(in defaults: UserDefaults = .standard) {
        guard !isInserted(in: defaults) else { return }
        defaults.set(defaultInserted, forKey: preferenceKey)
    }
}
