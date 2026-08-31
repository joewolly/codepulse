import AppKit
import CodePulseIntegration
import Foundation

public enum CodePulseControlCLIExitCode: Int32 {
    case success = 0
    case invalidArguments = 2
    case appUnavailable = 3
    case invalidStateTransition = 4
    case presetOrProjectNotFound = 5
    case commandRejected = 6
    case internalTransportFailure = 7
}

public enum CodePulseControlCLIParseError: Error, Equatable {
    case invalidArguments(String)
    case help

    public var message: String {
        switch self {
        case .invalidArguments(let message): return message
        case .help: return CodePulseControlCLIParser.helpText
        }
    }
}

public struct CodePulseControlCLIInvocation: Equatable {
    public let command: CodePulseControlCommand
    public let wantsJSONStatus: Bool

    public init(command: CodePulseControlCommand, wantsJSONStatus: Bool = false) {
        self.command = command
        self.wantsJSONStatus = wantsJSONStatus
    }
}

public enum CodePulseControlCLIParser {
    public static let helpText = """
    Usage:
      codepulsectl status [--json]
      codepulsectl start --preset <name>
      codepulsectl start --preset-id <uuid>
      codepulsectl start --project <name> --type <coding|debugging|planning|review|research> [--goal <text>]
      codepulsectl pause [--session-id <uuid>]
      codepulsectl resume [--session-id <uuid>]
      codepulsectl finish [--session-id <uuid>]

    Exit codes:
      0  success
      2  invalid CLI arguments
      3  CodePulse is unavailable or not running
      4  invalid session state transition
      5  preset or project was not found
      6  command rejected or expired
      7  local transport or response failure

    A timeout can occur after CodePulse applies a mutation. Re-read status before retrying a command that exits with code 7.
    """

    public static func parse(
        arguments: [String],
        issuedAt: Date = Date()
    ) throws -> CodePulseControlCLIInvocation {
        guard let commandName = arguments.first else {
            throw CodePulseControlCLIParseError.invalidArguments("A command is required. Use --help for usage.")
        }
        if commandName == "--help" || commandName == "-h" || commandName == "help" {
            throw CodePulseControlCLIParseError.help
        }

        let rest = Array(arguments.dropFirst())
        switch commandName {
        case "status":
            guard rest.isEmpty || rest == ["--json"] else {
                throw CodePulseControlCLIParseError.invalidArguments("status accepts only --json.")
            }
            return CodePulseControlCLIInvocation(
                command: CodePulseControlCommand(issuedAt: issuedAt, action: .status),
                wantsJSONStatus: rest == ["--json"]
            )
        case "start":
            return try parseStart(arguments: rest, issuedAt: issuedAt)
        case "pause":
            return try parseLifecycle(arguments: rest, command: "pause", issuedAt: issuedAt)
        case "resume":
            return try parseLifecycle(arguments: rest, command: "resume", issuedAt: issuedAt)
        case "finish":
            return try parseLifecycle(arguments: rest, command: "finish", issuedAt: issuedAt)
        default:
            throw CodePulseControlCLIParseError.invalidArguments("Unknown command '\(commandName)'. Use --help for usage.")
        }
    }

    private static func parseStart(
        arguments: [String],
        issuedAt: Date
    ) throws -> CodePulseControlCLIInvocation {
        var presetName: String?
        var presetID: UUID?
        var projectName: String?
        var sessionType: String?
        var goal: String?
        var index = 0

        while index < arguments.count {
            let flag = arguments[index]
            guard flag.hasPrefix("--") else {
                throw CodePulseControlCLIParseError.invalidArguments("Unexpected start argument '\(flag)'.")
            }
            guard index + 1 < arguments.count else {
                throw CodePulseControlCLIParseError.invalidArguments("Missing value for \(flag).")
            }
            let value = arguments[index + 1]
            guard !value.isEmpty, !value.hasPrefix("--") else {
                throw CodePulseControlCLIParseError.invalidArguments("Missing value for \(flag).")
            }

            switch flag {
            case "--preset":
                guard presetName == nil else { throw duplicate(flag) }
                presetName = value
            case "--preset-id":
                guard presetID == nil else { throw duplicate(flag) }
                guard let parsed = UUID(uuidString: value) else {
                    throw CodePulseControlCLIParseError.invalidArguments("--preset-id must be a UUID.")
                }
                presetID = parsed
            case "--project":
                guard projectName == nil else { throw duplicate(flag) }
                projectName = value
            case "--type":
                guard sessionType == nil else { throw duplicate(flag) }
                let normalized = value.lowercased()
                guard supportedSessionTypes.contains(normalized) else {
                    throw CodePulseControlCLIParseError.invalidArguments("Unknown session type '\(value)'.")
                }
                sessionType = normalized
            case "--goal":
                guard goal == nil else { throw duplicate(flag) }
                goal = value
            default:
                throw CodePulseControlCLIParseError.invalidArguments("Unknown start option '\(flag)'.")
            }
            index += 2
        }

        let selectorCount = [presetName != nil, presetID != nil, projectName != nil || sessionType != nil || goal != nil]
            .filter { $0 }
            .count
        guard selectorCount == 1 else {
            throw CodePulseControlCLIParseError.invalidArguments(
                "Choose exactly one start selector: --preset, --preset-id, or --project with --type."
            )
        }

        if let presetName {
            guard projectName == nil, sessionType == nil, goal == nil else {
                throw CodePulseControlCLIParseError.invalidArguments("Preset starts cannot include project, type, or goal options.")
            }
            return invocation(action: .startPreset(name: presetName), issuedAt: issuedAt)
        }
        if let presetID {
            guard projectName == nil, sessionType == nil, goal == nil else {
                throw CodePulseControlCLIParseError.invalidArguments("Preset starts cannot include project, type, or goal options.")
            }
            return invocation(action: .startPresetID(presetID), issuedAt: issuedAt)
        }

        guard let projectName, let sessionType else {
            throw CodePulseControlCLIParseError.invalidArguments("Direct starts require both --project and --type.")
        }
        return invocation(
            action: .startManual(projectName: projectName, sessionType: sessionType, goal: goal),
            issuedAt: issuedAt
        )
    }

    private static let supportedSessionTypes: Set<String> = [
        "coding", "debugging", "planning", "review", "research"
    ]

    private static func parseLifecycle(
        arguments: [String],
        command: String,
        issuedAt: Date
    ) throws -> CodePulseControlCLIInvocation {
        guard !arguments.isEmpty else {
            let action: CodePulseControlAction = command == "pause" ? .pause : (command == "resume" ? .resume : .finish)
            return invocation(action: action, issuedAt: issuedAt)
        }
        guard arguments.count == 2, arguments[0] == "--session-id" else {
            if arguments.filter({ $0 == "--session-id" }).count > 1 {
                throw duplicate("--session-id")
            }
            throw CodePulseControlCLIParseError.invalidArguments("\(command) accepts only --session-id <uuid>.")
        }
        guard let id = UUID(uuidString: arguments[1]) else {
            throw CodePulseControlCLIParseError.invalidArguments("--session-id must be a UUID.")
        }
        let action: CodePulseControlAction = command == "pause"
            ? .pauseSession(id)
            : (command == "resume" ? .resumeSession(id) : .finishSession(id))
        return invocation(action: action, issuedAt: issuedAt)
    }

    private static func invocation(
        action: CodePulseControlAction,
        issuedAt: Date
    ) -> CodePulseControlCLIInvocation {
        CodePulseControlCLIInvocation(
            command: CodePulseControlCommand(issuedAt: issuedAt, action: action)
        )
    }

    private static func requireNoArguments(
        _ arguments: [String],
        for command: String
    ) throws {
        guard arguments.isEmpty else {
            throw CodePulseControlCLIParseError.invalidArguments("\(command) does not accept arguments.")
        }
    }

    private static func duplicate(_ flag: String) -> CodePulseControlCLIParseError {
        .invalidArguments("Option \(flag) was provided more than once.")
    }
}

public enum CodePulseControlCLIFormatter {
    public static func humanStatus(_ status: CodePulseControlStatus) -> String {
        if status.schemaVersion == 2 {
            guard !status.sessions.isEmpty else { return "CodePulse: idle" }
            if status.sessions.count > 1 {
                var lines = ["CodePulse: \(status.sessions.count) active sessions"]
                for session in status.sessions {
                    lines.append("\(session.sessionID.uuidString) · \(session.phase) · \(session.projectName ?? "No Project") · \(sessionTypeDisplayName(session.sessionType)) · \(duration(session.elapsedSeconds))")
                }
                return lines.joined(separator: "\n")
            }
            let session = status.sessions[0]
            var lines = ["CodePulse: \(session.phase)", "Session: \(session.sessionID.uuidString)"]
            if let project = session.projectName { lines.append("Project: \(project)") }
            if let workspace = session.workspaceName { lines.append("Workspace: \(workspace)") }
            lines.append("Type: \(sessionTypeDisplayName(session.sessionType))")
            lines.append("Elapsed: \(duration(session.elapsedSeconds))")
            if session.phase == "running" {
                lines.append("Control: \(session.automationControlled ? "automatic" : "manual")")
            }
            return lines.joined(separator: "\n")
        }
        var lines = ["CodePulse: \(status.phase)"]
        if let project = status.project {
            lines.append("Project: \(project)")
        }
        if let sessionType = status.sessionType {
            lines.append("Type: \(sessionTypeDisplayName(sessionType))")
        }
        if status.phase != "idle" {
            lines.append("Elapsed: \(duration(status.elapsedSeconds))")
            if status.phase == "running" {
                lines.append("Control: \(status.automationControlled ? "automatic" : "manual")")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func jsonStatus(_ status: CodePulseControlStatus) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(status)
        guard let output = String(data: data, encoding: .utf8) else {
            throw CodePulseControlCLIParseError.invalidArguments("Could not encode status JSON.")
        }
        return output
    }

    private static func duration(_ seconds: Int) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remaining = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, remaining)
    }

    private static func sessionTypeDisplayName(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + value.dropFirst()
    }
}

public enum CodePulseControlClientError: Error, Equatable {
    case appUnavailable
    case responseTimeout
    case transportFailure
}

public final class CodePulseControlClient {
    private let transport: CodePulseControlTransport
    private let appIsRunning: () -> Bool
    private let now: () -> Date
    private let sleep: (TimeInterval) -> Void

    public init(
        transport: CodePulseControlTransport = CodePulseControlTransport(),
        appIsRunning: @escaping () -> Bool = {
            !NSRunningApplication.runningApplications(withBundleIdentifier: "com.joewolly.CodePulse").isEmpty
        },
        now: @escaping () -> Date = Date.init,
        sleep: @escaping (TimeInterval) -> Void = { interval in
            Thread.sleep(forTimeInterval: interval)
        }
    ) {
        self.transport = transport
        self.appIsRunning = appIsRunning
        self.now = now
        self.sleep = sleep
    }

    public func send(
        _ command: CodePulseControlCommand,
        timeout: TimeInterval = 5
    ) throws -> CodePulseControlResponse {
        guard appIsRunning() else { throw CodePulseControlClientError.appUnavailable }

        do {
            try transport.writeCommand(command)
        } catch {
            throw CodePulseControlClientError.transportFailure
        }

        let deadline = now().addingTimeInterval(max(0, timeout))
        while now() <= deadline {
            do {
                if let response = try transport.readResponse(for: command.id) {
                    _ = transport.removeResponse(for: command.id)
                    return response
                }
            } catch {
                throw CodePulseControlClientError.transportFailure
            }

            if !appIsRunning() {
                _ = transport.removeCommand(at: commandURL(for: command.id))
                throw CodePulseControlClientError.appUnavailable
            }

            let remaining = deadline.timeIntervalSince(now())
            guard remaining > 0 else { break }
            sleep(min(0.05, remaining))
        }

        _ = transport.removeCommand(at: commandURL(for: command.id))
        throw CodePulseControlClientError.responseTimeout
    }

    private func commandURL(for id: UUID) -> URL {
        transport.paths.commandsURL
            .appendingPathComponent("\(id.uuidString.lowercased()).json", isDirectory: false)
    }
}
