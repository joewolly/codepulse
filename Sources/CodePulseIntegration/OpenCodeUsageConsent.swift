import Foundation

/// The standalone integration helper cannot import the app target, so it reads
/// just this persisted Boolean before accepting a plugin usage handoff. A
/// missing, unreadable, or malformed state is safely treated as no consent.
public enum OpenCodeUsageConsent {
    public static func isEnabled(
        applicationSupportDirectory: URL = DeveloperToolIntegrationPaths.defaultApplicationSupportDirectory(),
        fileManager: FileManager = .default
    ) -> Bool {
        let stateURL = applicationSupportDirectory
            .appendingPathComponent("CodePulse", isDirectory: true)
            .appendingPathComponent("state.json", isDirectory: false)
        guard fileManager.fileExists(atPath: stateURL.path),
              let data = try? Data(contentsOf: stateURL),
              let object = try? JSONSerialization.jsonObject(with: data) else { return false }
        return value(in: object)
    }

    private static func value(in object: Any) -> Bool {
        if let dictionary = object as? [String: Any] {
            if let value = dictionary["openCodeUsageTrackingEnabled"] as? Bool { return value }
            return dictionary.values.contains(where: value(in:))
        }
        if let values = object as? [Any] { return values.contains(where: value(in:)) }
        return false
    }
}
