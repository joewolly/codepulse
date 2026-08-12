import CodePulseIntegration
import Foundation

struct CodexIntegrationInstaller: DeveloperToolIntegrationInstalling {
    static let managedMarker = "CodePulse developer integration (managed)"
    private static let managedFeatureMarker = "CodePulse managed developer integration"

    let hooksURL: URL
    let configURL: URL
    private let fileManager: FileManager

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        let codexDirectory = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        self.init(
            hooksURL: codexDirectory.appendingPathComponent("hooks.json", isDirectory: false),
            configURL: codexDirectory.appendingPathComponent("config.toml", isDirectory: false),
            fileManager: fileManager
        )
    }

    init(hooksURL: URL, configURL: URL, fileManager: FileManager = .default) {
        self.hooksURL = hooksURL
        self.configURL = configURL
        self.fileManager = fileManager
    }

    var installationDescription: String {
        hooksURL.path
    }

    func isEnabled() throws -> Bool {
        guard fileManager.fileExists(atPath: hooksURL.path) else { return false }
        let root = try readHooksConfiguration()
        let enabled = containsManagedHook(in: root)
        guard enabled else { return false }
        if try featureState() == .disabled {
            throw DeveloperToolIntegrationError.hooksDisabledByUser
        }
        return true
    }

    func enable(helperURL: URL) throws {
        guard helperURL.path.hasPrefix("/") else {
            throw DeveloperToolIntegrationError.configurationWriteFailed("The helper path must be absolute.")
        }

        var root = try loadHooksConfigurationForUpdate()
        let featureWasChanged = try enableHooksFeatureIfNeeded()
        do {
            var hooks = try hooksTable(from: root)
            removeManagedHookGroups(from: &hooks)

            let command = "\(shellQuote(helperURL.standardizedFileURL.path)) --codex-hook --codepulse-managed"
            let handler: [String: Any] = [
                "type": "command",
                "command": command,
                "timeout": 2,
                "statusMessage": Self.managedMarker
            ]
            var backgroundHandler = handler
            backgroundHandler["async"] = true
            hooks["SessionStart", default: []].append([
                "matcher": "startup|resume|clear|compact",
                "hooks": [backgroundHandler]
            ])
            hooks["Stop", default: []].append(["hooks": [backgroundHandler]])
            hooks["SessionEnd", default: []].append(["hooks": [handler]])
            root["hooks"] = hooks
            try writeHooksConfiguration(root)
        } catch {
            if featureWasChanged {
                try? removeManagedHooksFeatureLine()
            }
            throw error
        }
    }

    func disable() throws {
        guard fileManager.fileExists(atPath: hooksURL.path) == true else {
            try removeManagedHooksFeatureLine()
            return
        }

        var root = try readHooksConfiguration()
        var hooks = try hooksTable(from: root)
        removeManagedHookGroups(from: &hooks)
        root["hooks"] = hooks
        try writeHooksConfiguration(root)
        try removeManagedHooksFeatureLine()
    }

    private func loadHooksConfigurationForUpdate() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: hooksURL.path) else {
            return ["hooks": [String: Any]()]
        }
        return try readHooksConfiguration()
    }

    private func readHooksConfiguration() throws -> [String: Any] {
        guard !isSymbolicLink(hooksURL) else {
            throw DeveloperToolIntegrationError.configurationUnreadable(hooksURL.path)
        }
        guard let data = try? Data(contentsOf: hooksURL), data.count <= 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            throw DeveloperToolIntegrationError.configurationUnreadable(hooksURL.path)
        }
        _ = try hooksTable(from: root)
        return root
    }

    private func hooksTable(from root: [String: Any]) throws -> [String: [Any]] {
        guard let rawHooks = root["hooks"] else { return [:] }
        guard let hooks = rawHooks as? [String: Any] else {
            throw DeveloperToolIntegrationError.configurationUnreadable(hooksURL.path)
        }

        var result: [String: [Any]] = [:]
        for (eventName, value) in hooks {
            guard let groups = value as? [Any] else {
                throw DeveloperToolIntegrationError.configurationUnreadable(hooksURL.path)
            }
            for group in groups {
                guard group is [String: Any] else {
                    throw DeveloperToolIntegrationError.configurationUnreadable(hooksURL.path)
                }
            }
            result[eventName] = groups
        }
        return result
    }

    private func containsManagedHook(in root: [String: Any]) -> Bool {
        guard let rawHooks = root["hooks"] as? [String: Any] else { return false }
        return rawHooks.values
            .compactMap { $0 as? [Any] }
            .flatMap { $0 }
            .contains(where: isManagedGroup)
    }

    private func removeManagedHookGroups(from hooks: inout [String: [Any]]) {
        for eventName in Array(hooks.keys) {
            guard let groups = hooks[eventName] else { continue }
            let remaining = groups.filter { !isManagedGroup($0) }
            if remaining.isEmpty {
                hooks.removeValue(forKey: eventName)
            } else {
                hooks[eventName] = remaining
            }
        }
    }

    private func isManagedGroup(_ value: Any) -> Bool {
        guard let group = value as? [String: Any],
              let handlers = group["hooks"] as? [Any] else { return false }
        return handlers.contains { value in
            guard let handler = value as? [String: Any],
                  handler["type"] as? String == "command",
                  handler["statusMessage"] as? String == Self.managedMarker,
                  let command = handler["command"] as? String else { return false }
            return command.hasSuffix(" --codepulse-managed")
        }
    }

    private func writeHooksConfiguration(_ root: [String: Any]) throws {
        guard !isSymbolicLink(hooksURL) else {
            throw DeveloperToolIntegrationError.configurationPathInUse(hooksURL.path)
        }
        guard JSONSerialization.isValidJSONObject(root) else {
            throw DeveloperToolIntegrationError.configurationWriteFailed("Invalid JSON configuration.")
        }
        do {
            try fileManager.createDirectory(
                at: hooksURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try atomicReplace(data, at: hooksURL)
        } catch {
            throw DeveloperToolIntegrationError.configurationWriteFailed(error.localizedDescription)
        }
    }

    private func atomicReplace(_ data: Data, at url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: [.atomic])
        defer { try? fileManager.removeItem(at: temporary) }

        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: url)
        }
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink == true
    }

    private func shellQuote(_ path: String) -> String {
        "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private enum FeatureState {
        case missing
        case enabled
        case disabled
    }

    private func featureState() throws -> FeatureState {
        guard fileManager.fileExists(atPath: configURL.path) else { return .missing }
        guard !isSymbolicLink(configURL), let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            throw DeveloperToolIntegrationError.configurationUnreadable(configURL.path)
        }

        var inFeatures = false
        var sawEnabled = false
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inFeatures = trimmed == "[features]"
                continue
            }
            guard inFeatures else { continue }
            let uncommented = line.components(separatedBy: "#").first ?? line
            let parts = uncommented.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard key == "hooks" || key == "codex_hooks" else { continue }
            guard value == "true" || value == "false" else {
                throw DeveloperToolIntegrationError.configurationUnreadable(configURL.path)
            }
            if value == "false" { return .disabled }
            sawEnabled = true
        }
        return sawEnabled ? .enabled : .missing
    }

    @discardableResult
    private func enableHooksFeatureIfNeeded() throws -> Bool {
        switch try featureState() {
        case .disabled:
            throw DeveloperToolIntegrationError.hooksDisabledByUser
        case .enabled:
            return false
        case .missing:
            break
        }

        var text = ""
        if fileManager.fileExists(atPath: configURL.path) {
            guard !isSymbolicLink(configURL), let existing = try? String(contentsOf: configURL, encoding: .utf8) else {
                throw DeveloperToolIntegrationError.configurationUnreadable(configURL.path)
            }
            text = existing
        }

        let lines = text.components(separatedBy: .newlines)
        if let featuresIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == "[features]"
        }) {
            var updated = lines
            updated.insert("hooks = true # \(Self.managedFeatureMarker)", at: featuresIndex + 1)
            try writeConfigText(updated.joined(separator: "\n"))
        } else {
            let prefix = text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
            try writeConfigText(prefix + "[features]\nhooks = true # \(Self.managedFeatureMarker)\n")
        }
        return true
    }

    private func removeManagedHooksFeatureLine() throws {
        guard fileManager.fileExists(atPath: configURL.path) else { return }
        guard !isSymbolicLink(configURL), let text = try? String(contentsOf: configURL, encoding: .utf8) else {
            throw DeveloperToolIntegrationError.configurationUnreadable(configURL.path)
        }
        let updated = text.components(separatedBy: .newlines).filter { line in
            !line.contains(Self.managedFeatureMarker)
        }
        let newText = updated.joined(separator: "\n")
        if newText != text {
            try writeConfigText(newText)
        }
    }

    private func writeConfigText(_ text: String) throws {
        guard !isSymbolicLink(configURL) else {
            throw DeveloperToolIntegrationError.configurationPathInUse(configURL.path)
        }
        do {
            try fileManager.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try atomicReplace(Data(text.utf8), at: configURL)
        } catch {
            throw DeveloperToolIntegrationError.configurationWriteFailed(error.localizedDescription)
        }
    }
}
