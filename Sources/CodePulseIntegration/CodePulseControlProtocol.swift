import Foundation

public enum CodePulseControlLimits {
    public static let maximumCommandBytes = 64 * 1024
    public static let maximumResponseBytes = 64 * 1024
    public static let maximumPendingCommands = 256
    public static let maximumPendingCommandBytes = 2 * 1024 * 1024
    public static let maximumResponses = 256
    public static let maximumResponseBytesTotal = 4 * 1024 * 1024
    public static let maximumCommandAge: TimeInterval = 30
    public static let maximumFutureSkew: TimeInterval = 5
    public static let processedCommandRetention: TimeInterval = 24 * 60 * 60
    public static let maximumProcessedCommands = 512
    public static let maximumPresetNameLength = 200
    public static let maximumProjectNameLength = 200
    public static let maximumGoalLength = 4_096
    public static let maximumSessionTypeLength = 64
    public static let maximumMessageLength = 512
}

public struct CodePulseControlPaths: Equatable, Sendable {
    public let applicationSupportURL: URL
    public let rootURL: URL
    public let commandsURL: URL
    public let responsesURL: URL

    public init(applicationSupportDirectory: URL = CodePulseControlPaths.defaultApplicationSupportDirectory()) {
        let rootURL = applicationSupportDirectory
            .appendingPathComponent("CodePulse", isDirectory: true)
            .appendingPathComponent("Control", isDirectory: true)
        self.applicationSupportURL = applicationSupportDirectory
        self.rootURL = rootURL
        self.commandsURL = rootURL.appendingPathComponent("Commands", isDirectory: true)
        self.responsesURL = rootURL.appendingPathComponent("Responses", isDirectory: true)
    }

    public static func `default`() -> CodePulseControlPaths {
        CodePulseControlPaths()
    }

    public static func defaultApplicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
    }
}

public enum CodePulseControlAction: Codable, Equatable, Sendable {
    case status
    case startPreset(name: String)
    case startPresetID(UUID)
    case startManual(projectName: String, sessionType: String, goal: String?)
    case pause
    case resume
    case finish

    private enum CodingKeys: String, CodingKey {
        case kind
        case name
        case presetID
        case projectName
        case sessionType
        case goal
    }

    private enum Kind: String, Codable {
        case status
        case startPreset
        case startPresetID
        case startManual
        case pause
        case resume
        case finish
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .status:
            self = .status
        case .startPreset:
            self = .startPreset(name: try container.decode(String.self, forKey: .name))
        case .startPresetID:
            self = .startPresetID(try container.decode(UUID.self, forKey: .presetID))
        case .startManual:
            self = .startManual(
                projectName: try container.decode(String.self, forKey: .projectName),
                sessionType: try container.decode(String.self, forKey: .sessionType),
                goal: try container.decodeIfPresent(String.self, forKey: .goal)
            )
        case .pause:
            self = .pause
        case .resume:
            self = .resume
        case .finish:
            self = .finish
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .status:
            try container.encode(Kind.status, forKey: .kind)
        case .startPreset(let name):
            try container.encode(Kind.startPreset, forKey: .kind)
            try container.encode(name, forKey: .name)
        case .startPresetID(let id):
            try container.encode(Kind.startPresetID, forKey: .kind)
            try container.encode(id, forKey: .presetID)
        case .startManual(let projectName, let sessionType, let goal):
            try container.encode(Kind.startManual, forKey: .kind)
            try container.encode(projectName, forKey: .projectName)
            try container.encode(sessionType, forKey: .sessionType)
            try container.encodeIfPresent(goal, forKey: .goal)
        case .pause:
            try container.encode(Kind.pause, forKey: .kind)
        case .resume:
            try container.encode(Kind.resume, forKey: .kind)
        case .finish:
            try container.encode(Kind.finish, forKey: .kind)
        }
    }
}

public struct CodePulseControlCommand: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let id: UUID
    public let issuedAt: Date
    public let action: CodePulseControlAction

    public init(
        schemaVersion: Int = CodePulseControlCommand.currentSchemaVersion,
        id: UUID = UUID(),
        issuedAt: Date,
        action: CodePulseControlAction
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.issuedAt = issuedAt
        self.action = action
    }
}

public enum CodePulseControlResultCode: String, Codable, Equatable, Sendable {
    case success
    case invalidStateTransition
    case presetOrProjectNotFound
    case commandRejected
    case internalFailure
}

public struct CodePulseControlStatus: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let phase: String
    public let project: String?
    public let sessionType: String?
    public let elapsedSeconds: Int
    public let automationControlled: Bool

    public init(
        schemaVersion: Int = CodePulseControlStatus.currentSchemaVersion,
        phase: String,
        project: String? = nil,
        sessionType: String? = nil,
        elapsedSeconds: Int,
        automationControlled: Bool
    ) {
        self.schemaVersion = schemaVersion
        self.phase = phase
        self.project = project
        self.sessionType = sessionType
        self.elapsedSeconds = max(0, elapsedSeconds)
        self.automationControlled = automationControlled
    }
}

public struct CodePulseControlResponse: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let commandID: UUID
    public let result: CodePulseControlResultCode
    public let message: String
    public let status: CodePulseControlStatus?

    public init(
        schemaVersion: Int = CodePulseControlResponse.currentSchemaVersion,
        commandID: UUID,
        result: CodePulseControlResultCode,
        message: String,
        status: CodePulseControlStatus? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.commandID = commandID
        self.result = result
        self.message = String(message.prefix(CodePulseControlLimits.maximumMessageLength))
        self.status = status
    }
}

public enum CodePulseControlValidationError: Error, Equatable {
    case commandTooLarge
    case unsupportedSchemaVersion(Int)
    case commandTooOld
    case commandInFuture
    case invalidEnvelope
    case unexpectedField(String)
    case emptyValue(String)
    case valueTooLong(String)
    case invalidValue(String)
}

public enum CodePulseControlCommandCodec {
    private static let allowedCommandFields: Set<String> = [
        "schemaVersion", "id", "issuedAt", "action"
    ]
    private static let allowedActionFields: [String: Set<String>] = [
        "status": ["kind"],
        "startPreset": ["kind", "name"],
        "startPresetID": ["kind", "presetID"],
        "startManual": ["kind", "projectName", "sessionType", "goal"],
        "pause": ["kind"],
        "resume": ["kind"],
        "finish": ["kind"]
    ]

    public static func encode(_ command: CodePulseControlCommand) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(command)
        guard data.count <= CodePulseControlLimits.maximumCommandBytes else {
            throw CodePulseControlValidationError.commandTooLarge
        }
        return data
    }

    public static func decode(_ data: Data) throws -> CodePulseControlCommand {
        guard data.count <= CodePulseControlLimits.maximumCommandBytes else {
            throw CodePulseControlValidationError.commandTooLarge
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodePulseControlValidationError.invalidEnvelope
        }
        try requireOnly(allowedCommandFields, in: root)
        guard let action = root["action"] as? [String: Any],
              let kind = action["kind"] as? String,
              let allowedFields = allowedActionFields[kind] else {
            throw CodePulseControlValidationError.invalidEnvelope
        }
        try requireOnly(allowedFields, in: action)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(CodePulseControlCommand.self, from: data)
        } catch {
            throw CodePulseControlValidationError.invalidEnvelope
        }
    }

    public static func validateEncodedData(
        _ data: Data,
        now: Date = Date()
    ) throws -> CodePulseControlCommand {
        let command = try decode(data)
        return try CodePulseControlCommandValidator.sanitized(command, now: now)
    }

    private static func requireOnly(
        _ allowed: Set<String>,
        in dictionary: [String: Any]
    ) throws {
        if let unexpected = dictionary.keys.first(where: { !allowed.contains($0) }) {
            throw CodePulseControlValidationError.unexpectedField(unexpected)
        }
    }
}

public enum CodePulseControlCommandValidator {
    public static func sanitized(
        _ command: CodePulseControlCommand,
        now: Date = Date()
    ) throws -> CodePulseControlCommand {
        guard command.schemaVersion == CodePulseControlCommand.currentSchemaVersion else {
            throw CodePulseControlValidationError.unsupportedSchemaVersion(command.schemaVersion)
        }

        let age = now.timeIntervalSince(command.issuedAt)
        guard age <= CodePulseControlLimits.maximumCommandAge else {
            throw CodePulseControlValidationError.commandTooOld
        }
        guard age >= -CodePulseControlLimits.maximumFutureSkew else {
            throw CodePulseControlValidationError.commandInFuture
        }

        let action: CodePulseControlAction
        switch command.action {
        case .status, .pause, .resume, .finish, .startPresetID:
            action = command.action
        case .startPreset(let name):
            action = .startPreset(name: try cleanRequired(
                name,
                field: "preset name",
                maximumLength: CodePulseControlLimits.maximumPresetNameLength
            ))
        case .startManual(let projectName, let sessionType, let goal):
            let cleanType = try cleanRequired(
                sessionType,
                field: "session type",
                maximumLength: CodePulseControlLimits.maximumSessionTypeLength
            ).lowercased()
            let cleanGoal = try cleanOptional(
                goal,
                field: "goal",
                maximumLength: CodePulseControlLimits.maximumGoalLength
            )
            action = .startManual(
                projectName: try cleanRequired(
                    projectName,
                    field: "project name",
                    maximumLength: CodePulseControlLimits.maximumProjectNameLength
                ),
                sessionType: cleanType,
                goal: cleanGoal
            )
        }

        return CodePulseControlCommand(
            schemaVersion: command.schemaVersion,
            id: command.id,
            issuedAt: command.issuedAt,
            action: action
        )
    }

    private static func cleanRequired(
        _ value: String,
        field: String,
        maximumLength: Int
    ) throws -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw CodePulseControlValidationError.emptyValue(field)
        }
        guard cleaned.count <= maximumLength else {
            throw CodePulseControlValidationError.valueTooLong(field)
        }
        guard isSafeString(cleaned) else {
            throw CodePulseControlValidationError.invalidValue(field)
        }
        return cleaned
    }

    private static func cleanOptional(
        _ value: String?,
        field: String,
        maximumLength: Int
    ) throws -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        guard cleaned.count <= maximumLength else {
            throw CodePulseControlValidationError.valueTooLong(field)
        }
        guard isSafeString(cleaned) else {
            throw CodePulseControlValidationError.invalidValue(field)
        }
        return cleaned
    }

    private static func isSafeString(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
    }
}

public enum CodePulseControlResponseCodec {
    private static let allowedResponseFields: Set<String> = [
        "schemaVersion", "commandID", "result", "message", "status"
    ]
    private static let allowedStatusFields: Set<String> = [
        "schemaVersion", "phase", "project", "sessionType", "elapsedSeconds", "automationControlled"
    ]

    public static func encode(_ response: CodePulseControlResponse) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(response)
        guard data.count <= CodePulseControlLimits.maximumResponseBytes else {
            throw CodePulseControlValidationError.commandTooLarge
        }
        return data
    }

    public static func decode(_ data: Data) throws -> CodePulseControlResponse {
        guard data.count <= CodePulseControlLimits.maximumResponseBytes else {
            throw CodePulseControlValidationError.commandTooLarge
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodePulseControlValidationError.invalidEnvelope
        }
        try requireOnly(allowedResponseFields, in: root)
        if let status = root["status"] as? [String: Any] {
            try requireOnly(allowedStatusFields, in: status)
        } else if root["status"] != nil {
            throw CodePulseControlValidationError.invalidEnvelope
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let response = try decoder.decode(CodePulseControlResponse.self, from: data)
            guard response.schemaVersion == CodePulseControlResponse.currentSchemaVersion else {
                throw CodePulseControlValidationError.unsupportedSchemaVersion(response.schemaVersion)
            }
            if let status = response.status,
               status.schemaVersion != CodePulseControlStatus.currentSchemaVersion {
                throw CodePulseControlValidationError.unsupportedSchemaVersion(status.schemaVersion)
            }
            try validate(response)
            return response
        } catch {
            if let error = error as? CodePulseControlValidationError {
                throw error
            }
            throw CodePulseControlValidationError.invalidEnvelope
        }
    }

    private static func requireOnly(
        _ allowed: Set<String>,
        in dictionary: [String: Any]
    ) throws {
        if let unexpected = dictionary.keys.first(where: { !allowed.contains($0) }) {
            throw CodePulseControlValidationError.unexpectedField(unexpected)
        }
    }

    private static func validate(_ response: CodePulseControlResponse) throws {
        guard response.message.count <= CodePulseControlLimits.maximumMessageLength,
              isSafeString(response.message) else {
            throw CodePulseControlValidationError.invalidValue("response message")
        }
        guard let status = response.status else { return }
        guard ["idle", "running", "paused", "finishing"].contains(status.phase),
              status.phase.count <= CodePulseControlLimits.maximumSessionTypeLength,
              isSafeString(status.phase),
              status.elapsedSeconds >= 0 else {
            throw CodePulseControlValidationError.invalidValue("response status")
        }
        if let project = status.project {
            guard project.count <= CodePulseControlLimits.maximumProjectNameLength,
                  isSafeString(project) else {
                throw CodePulseControlValidationError.invalidValue("response project")
            }
        }
        if let sessionType = status.sessionType {
            guard sessionType.count <= CodePulseControlLimits.maximumSessionTypeLength,
                  isSafeString(sessionType) else {
                throw CodePulseControlValidationError.invalidValue("response session type")
            }
        }
    }

    private static func isSafeString(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
    }
}

public final class CodePulseControlTransport {
    public let paths: CodePulseControlPaths
    private let fileManager: FileManager

    public init(
        paths: CodePulseControlPaths = .default(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func writeCommand(_ command: CodePulseControlCommand) throws {
        let data = try CodePulseControlCommandCodec.encode(command)
        try ensureDirectory(paths.commandsURL)
        let target = commandURL(for: command.id)
        guard !isSymbolicLink(target) else {
            throw CodePulseControlValidationError.invalidValue("command path")
        }
        if fileManager.fileExists(atPath: target.path) {
            return
        }
        try ensureCapacity(
            in: paths.commandsURL,
            maximumFiles: CodePulseControlLimits.maximumPendingCommands,
            maximumBytes: CodePulseControlLimits.maximumPendingCommandBytes,
            incomingBytes: data.count
        )
        try atomicallyWrite(data, to: target, prefix: "command")
    }

    public func pendingCommandURLs() -> [URL] {
        directRegularFiles(
            in: paths.commandsURL,
            fileExtension: "json",
            limit: CodePulseControlLimits.maximumPendingCommands
        )
    }

    public func readCommand(from url: URL) throws -> CodePulseControlCommand {
        guard isManagedFile(url, in: paths.commandsURL) else {
            throw CodePulseControlValidationError.invalidValue("command path")
        }
        let data = try boundedData(at: url, maximumBytes: CodePulseControlLimits.maximumCommandBytes)
        return try CodePulseControlCommandCodec.decode(data)
    }

    @discardableResult
    public func removeCommand(at url: URL) -> Bool {
        removeManagedFile(url, from: paths.commandsURL)
    }

    public func writeResponse(_ response: CodePulseControlResponse) throws {
        let data = try CodePulseControlResponseCodec.encode(response)
        try ensureDirectory(paths.responsesURL)
        let target = responseURL(for: response.commandID)
        guard !isSymbolicLink(target) else {
            throw CodePulseControlValidationError.invalidValue("response path")
        }
        if fileManager.fileExists(atPath: target.path) {
            return
        }
        try ensureCapacity(
            in: paths.responsesURL,
            maximumFiles: CodePulseControlLimits.maximumResponses,
            maximumBytes: CodePulseControlLimits.maximumResponseBytesTotal,
            incomingBytes: data.count
        )
        try atomicallyWrite(data, to: target, prefix: "response")
    }

    public func readResponse(for commandID: UUID) throws -> CodePulseControlResponse? {
        let target = responseURL(for: commandID)
        guard fileManager.fileExists(atPath: target.path) else { return nil }
        guard isManagedFile(target, in: paths.responsesURL),
              !managedPathContainsSymbolicLink() else {
            throw CodePulseControlValidationError.invalidValue("response path")
        }
        let data = try boundedData(at: target, maximumBytes: CodePulseControlLimits.maximumResponseBytes)
        let response = try CodePulseControlResponseCodec.decode(data)
        guard response.commandID == commandID else {
            throw CodePulseControlValidationError.invalidValue("response command ID")
        }
        return response
    }

    @discardableResult
    public func removeResponse(for commandID: UUID) -> Bool {
        removeManagedFile(responseURL(for: commandID), from: paths.responsesURL)
    }

    public func pruneResponses(now: Date = Date()) {
        guard !managedPathContainsSymbolicLink(),
              let urls = try? fileManager.contentsOfDirectory(
                  at: paths.responsesURL,
                  includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
                  options: []
              ) else {
            return
        }

        var files = urls.compactMap { url -> (url: URL, date: Date)? in
            guard isManagedFile(url, in: paths.responsesURL),
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                return nil
            }
            return (url, values.contentModificationDate ?? now)
        }
        let staleFiles = files.filter {
            now.timeIntervalSince($0.date) > CodePulseControlLimits.processedCommandRetention
        }
        for file in staleFiles {
            _ = removeManagedFile(file.url, from: paths.responsesURL)
        }
        files.removeAll { now.timeIntervalSince($0.date) > CodePulseControlLimits.processedCommandRetention }
        files.sort { $0.date < $1.date }
        if files.count > CodePulseControlLimits.maximumResponses {
            for file in files.prefix(files.count - CodePulseControlLimits.maximumResponses) {
                _ = removeManagedFile(file.url, from: paths.responsesURL)
            }
        }
    }

    private func commandURL(for id: UUID) -> URL {
        paths.commandsURL.appendingPathComponent("\(id.uuidString.lowercased()).json", isDirectory: false)
    }

    private func responseURL(for id: UUID) -> URL {
        paths.responsesURL.appendingPathComponent("\(id.uuidString.lowercased()).json", isDirectory: false)
    }

    private func ensureDirectory(_ url: URL) throws {
        guard !isSymbolicLink(url), !managedPathContainsSymbolicLink() else {
            throw CodePulseControlValidationError.invalidValue("control path")
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func ensureCapacity(
        in directory: URL,
        maximumFiles: Int,
        maximumBytes: Int,
        incomingBytes: Int
    ) throws {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else {
            throw CodePulseControlValidationError.invalidValue("control storage")
        }

        var fileCount = 0
        var totalBytes = 0
        for url in urls {
            guard !isSymbolicLink(url) else {
                throw CodePulseControlValidationError.invalidValue("control storage")
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { continue }
            fileCount += 1
            totalBytes += values.fileSize ?? maximumBytes
        }
        guard fileCount < maximumFiles,
              totalBytes <= maximumBytes,
              incomingBytes <= maximumBytes - totalBytes else {
            throw CodePulseControlValidationError.invalidValue("control storage capacity")
        }
    }

    private func atomicallyWrite(_ data: Data, to target: URL, prefix: String) throws {
        let temporary = target.deletingLastPathComponent().appendingPathComponent(
            ".\(prefix)-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            try data.write(to: temporary, options: .atomic)
            do {
                try fileManager.moveItem(at: temporary, to: target)
            } catch {
                if !fileManager.fileExists(atPath: target.path) {
                    throw error
                }
                try? fileManager.removeItem(at: temporary)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func directRegularFiles(
        in directory: URL,
        fileExtension: String,
        limit: Int
    ) -> [URL] {
        guard !isSymbolicLink(directory), !managedPathContainsSymbolicLink(),
              let urls = try? fileManager.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                  options: []
              ) else {
            return []
        }

        return urls
            .filter { url in
                guard url.pathExtension.lowercased() == fileExtension,
                      !isSymbolicLink(url),
                      let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                      values.isRegularFile == true else {
                    return false
                }
                return url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(limit)
            .map { $0 }
    }

    private func boundedData(at url: URL, maximumBytes: Int) throws -> Data {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue <= maximumBytes else {
            throw CodePulseControlValidationError.commandTooLarge
        }
        guard let data = try? Data(contentsOf: url) else {
            throw CodePulseControlValidationError.invalidEnvelope
        }
        guard data.count <= maximumBytes else {
            throw CodePulseControlValidationError.commandTooLarge
        }
        return data
    }

    private func removeManagedFile(_ url: URL, from directory: URL) -> Bool {
        guard !managedPathContainsSymbolicLink(),
              isSafeDirectFile(url, in: directory) else { return false }
        do {
            try fileManager.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    private func isManagedFile(_ url: URL, in directory: URL) -> Bool {
        guard !isSymbolicLink(url), !isSymbolicLink(directory), url.pathExtension.lowercased() == "json" else { return false }
        guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return false }
        let expectedName = "\(id.uuidString.lowercased()).json"
        guard url.lastPathComponent == expectedName else { return false }
        return url.deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL == directory
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private func isSafeDirectFile(_ url: URL, in directory: URL) -> Bool {
        guard !isSymbolicLink(url), !isSymbolicLink(directory),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            return false
        }
        return url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink == true
    }

    private func managedPathContainsSymbolicLink() -> Bool {
        let base = paths.applicationSupportURL.standardizedFileURL
        var current = paths.rootURL.standardizedFileURL
        while true {
            if isSymbolicLink(current) { return true }
            if current == base { return false }
            let parent = current.deletingLastPathComponent()
            if parent == current { return false }
            current = parent
        }
    }
}
