import Foundation

/// The only source of truth for recognizing developer tools in frontmost
/// application identities. A frontmost application does not carry repository
/// context, so recognized developer tools must use the event/session path
/// instead of application automation.
enum DeveloperToolApplicationClassifier {
    /// These are exact, normalized display names. Display names are included
    /// because OpenCode is commonly surfaced by a shell-hosted integration
    /// without a stable application bundle identifier.
    private static let recognizedDisplayNames: Set<String> = [
        "codex",
        "opencode"
    ]

    /// Known first-party bundle identifiers. Synthetic or renamed identities
    /// are not inferred from substrings; they must carry one of the exact
    /// display names above or one of these exact bundle identifiers.
    private static let recognizedBundleIdentifiers: Set<String> = [
        "com.openai.codex",
        "com.openai.opencode"
    ]

    static func isDeveloperTool(_ application: ApplicationIdentity) -> Bool {
        recognizedDisplayNames.contains(normalize(application.displayName))
            || isDeveloperToolBundleIdentifier(application.bundleIdentifier)
    }

    static func isDeveloperToolBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        recognizedBundleIdentifiers.contains(normalize(bundleIdentifier))
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
