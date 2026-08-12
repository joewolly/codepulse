import CodePulseIntegration
import Combine
import Foundation

enum DeveloperToolIntegrationError: LocalizedError, Equatable {
    case helperUnavailable
    case toolNotDetected(DeveloperTool)
    case configurationUnreadable(String)
    case configurationPathInUse(String)
    case hooksDisabledByUser
    case configurationWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            return "The CodePulse integration helper is not available in this app build."
        case .toolNotDetected(let tool):
            return "\(tool.title) was not detected on this Mac."
        case .configurationUnreadable(let path):
            return "The existing integration configuration could not be read: \(path)"
        case .configurationPathInUse(let path):
            return "CodePulse will not overwrite the existing user file at \(path)."
        case .hooksDisabledByUser:
            return "Codex hooks are disabled in your Codex configuration. Enable them there before enabling CodePulse integration."
        case .configurationWriteFailed(let message):
            return "The integration configuration could not be updated: \(message)"
        }
    }
}

struct DeveloperToolIntegrationStatus: Equatable, Identifiable {
    let tool: DeveloperTool
    var isDetected: Bool
    var isEnabled: Bool
    var installationDescription: String
    var detail: String
    var errorMessage: String?

    var id: DeveloperTool { tool }
}

protocol DeveloperToolExecutableDetecting {
    func isAvailable(named executableName: String) -> Bool
}

struct SystemDeveloperToolExecutableDetector: DeveloperToolExecutableDetecting {
    func isAvailable(named executableName: String) -> Bool {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let commonLocations = [
            URL(fileURLWithPath: "/opt/homebrew/bin").appendingPathComponent(executableName),
            URL(fileURLWithPath: "/usr/local/bin").appendingPathComponent(executableName),
            homeDirectory.appendingPathComponent(".opencode/bin").appendingPathComponent(executableName),
            homeDirectory.appendingPathComponent(".local/bin").appendingPathComponent(executableName),
            homeDirectory.appendingPathComponent(".bun/bin").appendingPathComponent(executableName),
            homeDirectory.appendingPathComponent(".npm-global/bin").appendingPathComponent(executableName),
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources").appendingPathComponent(executableName)
        ]
        if commonLocations.contains(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            return true
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [executableName]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}

protocol DeveloperToolIntegrationInstalling {
    var installationDescription: String { get }
    func isEnabled() throws -> Bool
    func enable(helperURL: URL) throws
    func disable() throws
}

@MainActor
final class DeveloperToolIntegrationManager: ObservableObject {
    @Published private(set) var statuses: [DeveloperTool: DeveloperToolIntegrationStatus] = [:]

    private let helperURL: URL?
    private let detector: DeveloperToolExecutableDetecting
    private let installers: [DeveloperTool: DeveloperToolIntegrationInstalling]
    private var errors: [DeveloperTool: String] = [:]

    init(
        helperURL: URL? = DeveloperToolIntegrationHelperLocator.locate(),
        detector: DeveloperToolExecutableDetecting = SystemDeveloperToolExecutableDetector(),
        installers: [DeveloperTool: DeveloperToolIntegrationInstalling]? = nil
    ) {
        self.helperURL = helperURL
        self.detector = detector
        self.installers = installers ?? Self.defaultInstallers()
        refresh()
    }

    static func live() -> DeveloperToolIntegrationManager {
        DeveloperToolIntegrationManager()
    }

    func status(for tool: DeveloperTool) -> DeveloperToolIntegrationStatus {
        statuses[tool] ?? DeveloperToolIntegrationStatus(
            tool: tool,
            isDetected: false,
            isEnabled: false,
            installationDescription: "Not installed",
            detail: "\(tool.title) was not detected.",
            errorMessage: nil
        )
    }

    func refresh() {
        var nextStatuses: [DeveloperTool: DeveloperToolIntegrationStatus] = [:]
        for tool in DeveloperTool.allCases {
            guard let installer = installers[tool] else { continue }
            let detected = detector.isAvailable(named: tool == .codex ? "codex" : "opencode")
            let enabled: Bool
            let installerError: String?
            do {
                enabled = try installer.isEnabled()
                installerError = nil
            } catch {
                enabled = false
                installerError = error.localizedDescription
            }

            let errorMessage = errors[tool] ?? installerError
            let detail: String
            if !detected {
                detail = "\(tool.title) was not detected."
            } else if let errorMessage {
                detail = errorMessage
            } else if enabled {
                detail = "Optional metadata only; prompts and responses are never collected."
            } else {
                detail = "Available but disabled."
            }
            nextStatuses[tool] = DeveloperToolIntegrationStatus(
                tool: tool,
                isDetected: detected,
                isEnabled: enabled,
                installationDescription: installer.installationDescription,
                detail: detail,
                errorMessage: errorMessage
            )
        }
        statuses = nextStatuses
    }

    @discardableResult
    func enable(_ tool: DeveloperTool) -> Bool {
        guard let installer = installers[tool] else { return false }
        guard detector.isAvailable(named: tool == .codex ? "codex" : "opencode") else {
            errors[tool] = DeveloperToolIntegrationError.toolNotDetected(tool).localizedDescription
            refresh()
            return false
        }
        guard let helperURL else {
            errors[tool] = DeveloperToolIntegrationError.helperUnavailable.localizedDescription
            refresh()
            return false
        }

        do {
            try installer.enable(helperURL: helperURL)
            errors[tool] = nil
            refresh()
            return true
        } catch {
            errors[tool] = error.localizedDescription
            refresh()
            return false
        }
    }

    @discardableResult
    func disable(_ tool: DeveloperTool) -> Bool {
        guard let installer = installers[tool] else { return false }
        do {
            try installer.disable()
            errors[tool] = nil
            refresh()
            return true
        } catch {
            errors[tool] = error.localizedDescription
            refresh()
            return false
        }
    }

    private static func defaultInstallers() -> [DeveloperTool: DeveloperToolIntegrationInstalling] {
        [
            .codex: CodexIntegrationInstaller(),
            .opencode: OpenCodeIntegrationInstaller()
        ]
    }
}

enum DeveloperToolIntegrationHelperLocator {
    static func locate(bundle: Bundle = .main) -> URL? {
        let candidates = [
            bundle.bundleURL.appendingPathComponent("Contents/Helpers/codepulse-integration", isDirectory: false),
            bundle.resourceURL?.appendingPathComponent("codepulse-integration", isDirectory: false)
        ].compactMap { $0 }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }
}
