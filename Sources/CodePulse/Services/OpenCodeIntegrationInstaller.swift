import CodePulseIntegration
import Foundation

struct OpenCodeIntegrationInstaller: DeveloperToolIntegrationInstalling {
    static let managedMarker = "// CodePulse developer integration (managed)"

    let pluginURL: URL
    private let fileManager: FileManager

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) {
        self.init(
            pluginURL: homeDirectory
                .appendingPathComponent(".config/opencode/plugins", isDirectory: true)
                .appendingPathComponent("codepulse-integration.js", isDirectory: false),
            fileManager: fileManager
        )
    }

    init(pluginURL: URL, fileManager: FileManager = .default) {
        self.pluginURL = pluginURL
        self.fileManager = fileManager
    }

    var installationDescription: String {
        pluginURL.path
    }

    func isEnabled() throws -> Bool {
        guard !managedPathContainsSymbolicLink() else {
            throw DeveloperToolIntegrationError.configurationPathInUse(pluginURL.path)
        }
        guard fileManager.fileExists(atPath: pluginURL.path) else { return false }
        guard let data = try? Data(contentsOf: pluginURL), data.count <= 256 * 1024,
              let source = String(data: data, encoding: .utf8) else {
            throw DeveloperToolIntegrationError.configurationUnreadable(pluginURL.path)
        }
        return source.hasPrefix(Self.managedMarker)
    }

    func enable(helperURL: URL) throws {
        guard helperURL.path.hasPrefix("/") else {
            throw DeveloperToolIntegrationError.configurationWriteFailed("The helper path must be absolute.")
        }
        guard !managedPathContainsSymbolicLink() else {
            throw DeveloperToolIntegrationError.configurationPathInUse(pluginURL.path)
        }
        if fileManager.fileExists(atPath: pluginURL.path) {
            guard try isEnabled() else {
                throw DeveloperToolIntegrationError.configurationPathInUse(pluginURL.path)
            }
        }

        let source = OpenCodePluginSource.make(helperURL: helperURL)
        do {
            try fileManager.createDirectory(
                at: pluginURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try atomicReplace(Data(source.utf8), at: pluginURL)
        } catch {
            throw DeveloperToolIntegrationError.configurationWriteFailed(error.localizedDescription)
        }
    }

    func disable() throws {
        guard !managedPathContainsSymbolicLink() else {
            throw DeveloperToolIntegrationError.configurationPathInUse(pluginURL.path)
        }
        guard fileManager.fileExists(atPath: pluginURL.path) else { return }
        guard try isEnabled() else {
            throw DeveloperToolIntegrationError.configurationPathInUse(pluginURL.path)
        }
        try fileManager.removeItem(at: pluginURL)
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

    private func managedPathContainsSymbolicLink() -> Bool {
        let managedDirectory = pluginURL.deletingLastPathComponent().standardizedFileURL
        var current = pluginURL.standardizedFileURL

        while true {
            if isSymbolicLink(current) {
                return true
            }
            if current == managedDirectory {
                return false
            }
            let parent = current.deletingLastPathComponent()
            if parent == current {
                return false
            }
            current = parent
        }
    }
}

enum OpenCodePluginSource {
    static func make(helperURL: URL) -> String {
        let helperLiteral = javascriptStringLiteral(helperURL.standardizedFileURL.path)
        return """
        // CodePulse developer integration (managed)
        const CODEPULSE_HELPER = \(helperLiteral);
        const CODEPULSE_PLUGIN_VERSION = "opencode-plugin-v1";
        const sessions = new Map();

        function text(value) {
          return typeof value === "string" && value.length > 0 ? value : undefined;
        }

        function modelName(value) {
          if (typeof value === "string") return text(value);
          if (!value || typeof value !== "object") return undefined;
          const id = text(value.id);
          const provider = text(value.providerID);
          if (provider && id) return provider + "/" + id;
          return id || provider;
        }

        function sessionID(properties) {
          return text(properties && properties.sessionID) || text(properties && properties.info && properties.info.id);
        }

        function workingDirectory(record, fallback) {
          return text(record && record.cwd) || text(fallback);
        }

        async function emit(eventType, id, record, fallbackDirectory, discriminator) {
          const cwd = workingDirectory(record, fallbackDirectory);
          if (!id || !cwd) return;
          try {
            const event = {
              event_type: eventType,
              session_id: id,
              cwd,
              model: text(record && record.model),
              agent: text(record && record.profile),
              sequence: Number(discriminator.split(":").pop()) || 0,
              plugin_version: CODEPULSE_PLUGIN_VERSION
            };
            const child = Bun.spawn([CODEPULSE_HELPER, "--opencode-hook"], {
              stdin: "pipe",
              stdout: "ignore",
              stderr: "ignore"
            });
            child.stdin.write(JSON.stringify(event));
            await child.stdin.end();
            await child.exited;
          } catch (_) {
            // Integration delivery is optional and must not affect OpenCode.
          }
        }

        function recordFor(info, fallbackDirectory) {
          const id = text(info && info.id);
          if (!id) return undefined;
          const existing = sessions.get(id);
          const record = existing || {
            cwd: text(info && info.directory) || fallbackDirectory,
            model: modelName(info && info.model),
            profile: text(info && info.agent),
            state: "created",
            sequence: 0
          };
          if (info && info.directory) record.cwd = text(info.directory) || record.cwd;
          if (info && info.model) record.model = modelName(info.model) || record.model;
          if (info && info.agent) record.profile = text(info.agent) || record.profile;
          sessions.set(id, record);
          return record;
        }

        export const CodePulseIntegration = async ({ directory, worktree }) => {
          const fallbackDirectory = text(worktree) || text(directory);
          return {
            event: async ({ event }) => {
              if (!event || typeof event.type !== "string") return;
              const properties = event.properties || {};

              if (event.type === "session.created") {
                const info = properties.info || {};
                const id = text(info.id);
                if (id && sessions.has(id)) return;
                const record = recordFor(info, fallbackDirectory);
                if (record && id) {
                  record.state = "started";
                  record.sequence += 1;
                  await emit("session.started", id, record, fallbackDirectory, "created:" + record.sequence);
                }
                return;
              }

              if (event.type === "session.status") {
                const id = sessionID(properties);
                const record = recordFor({ id }, fallbackDirectory);
                const status = properties.status;
                const state = text(status && status.type) || text(status);
                if (!record || !id || !state || record.state === state) return;
                record.state = state;
                record.sequence += 1;
                if (state === "busy" || state === "retry") {
                  await emit("activity.observed", id, record, fallbackDirectory, state + ":" + record.sequence);
                } else if (state === "idle") {
                  await emit("session.idle", id, record, fallbackDirectory, state + ":" + record.sequence);
                }
                return;
              }

              if (event.type === "session.idle") {
                const id = sessionID(properties);
                const record = recordFor({ id }, fallbackDirectory);
                if (!record || !id || record.state === "idle") return;
                record.state = "idle";
                record.sequence += 1;
                await emit("session.idle", id, record, fallbackDirectory, "idle:" + record.sequence);
                return;
              }

              if (event.type === "session.deleted") {
                const id = sessionID(properties);
                const record = id ? sessions.get(id) : undefined;
                if (record && id) {
                  record.sequence += 1;
                  await emit("session.ended", id, record, fallbackDirectory, "deleted:" + record.sequence);
                  sessions.delete(id);
                }
                return;
              }

              if (event.type === "session.error") {
                const id = sessionID(properties);
                const record = recordFor({ id }, fallbackDirectory);
                if (record && id && record.state !== "error") {
                  record.state = "error";
                  record.sequence += 1;
                  await emit("integration.error", id, record, fallbackDirectory, "error:" + record.sequence);
                }
              }
            }
          };
        };

        export default CodePulseIntegration;
        """
    }

    private static func javascriptStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
    }
}
