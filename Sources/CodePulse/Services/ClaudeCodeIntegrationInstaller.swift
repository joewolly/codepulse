import CodePulseIntegration
import Foundation

/// Safely manages only CodePulse-marked entries in Claude Code's documented
/// user-level settings file. Project and managed settings are never modified.
struct ClaudeCodeIntegrationInstaller: DeveloperToolIntegrationInstalling {
    static let managedMarker = "CodePulse Claude Code lifecycle integration (managed)"

    let settingsURL: URL
    private let fileManager: FileManager

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.init(
            settingsURL: homeDirectory
                .appendingPathComponent(".claude", isDirectory: true)
                .appendingPathComponent("settings.json", isDirectory: false),
            fileManager: fileManager
        )
    }

    init(settingsURL: URL, fileManager: FileManager = .default) {
        self.settingsURL = settingsURL
        self.fileManager = fileManager
    }

    var installationDescription: String { settingsURL.path }

    func isEnabled() throws -> Bool {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return false }
        return containsManagedHook(in: try readSettings())
    }

    func enable(helperURL: URL) throws {
        guard helperURL.path.hasPrefix("/") else {
            throw DeveloperToolIntegrationError.configurationWriteFailed("The helper path must be absolute.")
        }
        var root = try loadSettingsForUpdate()
        var hooks = try hooksTable(from: root)
        removeManagedHookGroups(from: &hooks)

        let command = "\(shellQuote(helperURL.standardizedFileURL.path)) --claude-code-hook --codepulse-managed"
        let handler: [String: Any] = [
            "type": "command",
            "command": command,
            "timeout": 2,
            "statusMessage": Self.managedMarker,
            "async": true
        ]
        for eventName in [
            "SessionStart", "UserPromptSubmit", "PermissionRequest", "PostToolUse",
            "Stop", "SessionEnd", "SubagentStart", "SubagentStop"
        ] {
            hooks[eventName, default: []].append(["hooks": [handler]])
        }
        root["hooks"] = hooks
        try writeSettings(root)
    }

    func disable() throws {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return }
        var root = try readSettings()
        guard containsManagedHook(in: root) else { return }
        var hooks = try hooksTable(from: root)
        removeManagedHookGroups(from: &hooks)
        root["hooks"] = hooks
        try writeSettings(root)
    }

    private func loadSettingsForUpdate() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return [:] }
        return try readSettings()
    }

    private func readSettings() throws -> [String: Any] {
        guard !managedPathContainsSymbolicLink(settingsURL),
              let data = try? Data(contentsOf: settingsURL), data.count <= 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw DeveloperToolIntegrationError.configurationUnreadable(settingsURL.path)
        }
        _ = try hooksTable(from: root)
        return root
    }

    private func hooksTable(from root: [String: Any]) throws -> [String: [Any]] {
        guard let rawHooks = root["hooks"] else { return [:] }
        guard let hooks = rawHooks as? [String: Any] else {
            throw DeveloperToolIntegrationError.configurationUnreadable(settingsURL.path)
        }
        var result: [String: [Any]] = [:]
        for (eventName, value) in hooks {
            guard let groups = value as? [Any], groups.allSatisfy({ $0 is [String: Any] }) else {
                throw DeveloperToolIntegrationError.configurationUnreadable(settingsURL.path)
            }
            result[eventName] = groups
        }
        return result
    }

    private func containsManagedHook(in root: [String: Any]) -> Bool {
        (root["hooks"] as? [String: Any])?.values
            .compactMap { $0 as? [Any] }
            .flatMap { $0 }
            .contains(where: isManagedGroup) ?? false
    }

    private func removeManagedHookGroups(from hooks: inout [String: [Any]]) {
        for eventName in Array(hooks.keys) {
            let remaining = (hooks[eventName] ?? []).filter { !isManagedGroup($0) }
            if remaining.isEmpty { hooks.removeValue(forKey: eventName) }
            else { hooks[eventName] = remaining }
        }
    }

    private func isManagedGroup(_ value: Any) -> Bool {
        guard let group = value as? [String: Any], let handlers = group["hooks"] as? [Any] else { return false }
        return handlers.contains {
            ($0 as? [String: Any])?["statusMessage"] as? String == Self.managedMarker
        }
    }

    private func writeSettings(_ root: [String: Any]) throws {
        guard !managedPathContainsSymbolicLink(settingsURL), JSONSerialization.isValidJSONObject(root) else {
            throw DeveloperToolIntegrationError.configurationPathInUse(settingsURL.path)
        }
        do {
            try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            let temporary = settingsURL.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
            try data.write(to: temporary, options: [.atomic])
            defer { try? fileManager.removeItem(at: temporary) }
            if fileManager.fileExists(atPath: settingsURL.path) {
                _ = try fileManager.replaceItemAt(settingsURL, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: settingsURL)
            }
        } catch {
            throw DeveloperToolIntegrationError.configurationWriteFailed(error.localizedDescription)
        }
    }

    private func managedPathContainsSymbolicLink(_ url: URL) -> Bool {
        let managedDirectory = url.deletingLastPathComponent().standardizedFileURL
        var current = url.standardizedFileURL
        while true {
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return true }
            if current == managedDirectory { return false }
            let parent = current.deletingLastPathComponent()
            if parent == current { return false }
            current = parent
        }
    }

    private func shellQuote(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\\\''"))'"
    }
}
