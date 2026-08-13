import Foundation

protocol StatePersisting: AnyObject {
    func load() -> AppState
    func save(_ state: AppState)
}

final class JSONFilePersistence: StatePersisting {
    let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL = JSONFilePersistence.defaultFileURL()) {
        self.fileURL = fileURL

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() -> AppState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? decoder.decode(AppState.self, from: data) else {
            return AppState()
        }
        if Self.requiresAutomationMigration(data) {
            // AppState has already normalized legacy rules into stable preset
            // references. Persist that canonical representation once so the
            // next launch does not need to revisit the compatibility path.
            save(state)
        }
        return state
    }

    func save(_ state: AppState) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(state)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("CodePulse could not save local state: %@", error.localizedDescription)
        }
    }

    static func defaultFileURL() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return directory.appendingPathComponent("CodePulse/state.json")
    }

    private static func requiresAutomationMigration(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        guard let rules = root["automationRules"] as? [[String: Any]], !rules.isEmpty else {
            return false
        }
        guard root["sessionPresets"] != nil else { return true }
        return rules.contains { $0["presetID"] == nil }
    }
}
