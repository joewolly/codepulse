import Foundation

enum CodePulseBackupError: LocalizedError, Equatable {
    case unsupportedFormat
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            return "This file is not a CodePulse backup."
        case .unsupportedVersion(let version):
            return "This CodePulse backup uses unsupported version \(version)."
        }
    }
}

struct CodePulseBackup: Codable, Equatable {
    static let format = "codepulse-backup"
    static let currentVersion = 1

    let format: String
    let version: Int
    let exportedAt: Date
    let state: AppState

    init(exportedAt: Date, state: AppState, version: Int = CodePulseBackup.currentVersion) {
        self.format = Self.format
        self.version = version
        self.exportedAt = exportedAt
        self.state = state
    }
}

enum CodePulseBackupCodec {
    static func encode(state: AppState, exportedAt: Date) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(CodePulseBackup(exportedAt: exportedAt, state: state))
    }

    static func decode(_ data: Data) throws -> CodePulseBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(CodePulseBackup.self, from: data)
        guard backup.format == CodePulseBackup.format else {
            throw CodePulseBackupError.unsupportedFormat
        }
        guard backup.version == CodePulseBackup.currentVersion else {
            throw CodePulseBackupError.unsupportedVersion(backup.version)
        }
        return backup
    }
}
