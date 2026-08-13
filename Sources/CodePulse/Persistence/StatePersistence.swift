import Foundation

protocol StatePersisting: AnyObject {
    func load() -> AppState
    func save(_ state: AppState)
}

struct StateRestoreReceipt {
    let recoveryBackupURL: URL
}

protocol StateRestoring: AnyObject {
    var fileURL: URL { get }

    func replaceStateTransactionally(
        with state: AppState,
        recoverySnapshot: AppState,
        exportedAt: Date
    ) throws -> StateRestoreReceipt
}

enum StateRestoreFailurePoint {
    case recoveryWrite
    case recoveryVerification
    case candidateWrite
    case candidateVerification
    case liveReplacement
    case afterLiveReplacement
    case liveVerification
    case rollbackWrite
    case rollbackVerification
}

enum StatePersistenceError: LocalizedError {
    case unsafeStoragePath
    case recoveryBackupWriteFailed(URL, Error)
    case recoveryBackupVerificationFailed(URL, Error)
    case candidateWriteFailed(Error)
    case candidateVerificationFailed(Error)
    case liveReplacementFailed(Error)
    case liveVerificationFailed(Error)
    case restoreFailedRollbackSucceeded(URL, Error)
    case restoreFailedRollbackFailed(URL, Error, Error)

    var errorDescription: String? {
        switch self {
        case .unsafeStoragePath:
            return "CodePulse could not safely access its local storage path, so your current data was not changed."
        case .recoveryBackupWriteFailed:
            return "CodePulse could not create a recovery backup, so your current data was not changed."
        case .recoveryBackupVerificationFailed:
            return "CodePulse could not verify the recovery backup, so your current data was not changed."
        case .candidateWriteFailed, .candidateVerificationFailed, .liveReplacementFailed, .liveVerificationFailed:
            return "The restore failed. Your current CodePulse data was not changed."
        case .restoreFailedRollbackSucceeded(let url, _):
            return "The restore failed. Your previous CodePulse data was restored automatically. Recovery backup: \(url.path)"
        case .restoreFailedRollbackFailed(let url, _, _):
            return "The restore failed and automatic rollback could not be completed. Your recovery backup is available at: \(url.path)"
        }
    }

    var technicalDescription: String {
        switch self {
        case .unsafeStoragePath:
            return errorDescription ?? "unsafe storage path"
        case .recoveryBackupWriteFailed(let url, let error):
            return "recovery backup write at \(url.path): \(error.localizedDescription)"
        case .recoveryBackupVerificationFailed(let url, let error):
            return "recovery backup verification at \(url.path): \(error.localizedDescription)"
        case .candidateWriteFailed(let error):
            return "candidate write: \(error.localizedDescription)"
        case .candidateVerificationFailed(let error):
            return "candidate verification: \(error.localizedDescription)"
        case .liveReplacementFailed(let error):
            return "live replacement: \(error.localizedDescription)"
        case .liveVerificationFailed(let error):
            return "live verification: \(error.localizedDescription)"
        case .restoreFailedRollbackSucceeded(let url, let error):
            return "restore failed after live replacement (\(error.localizedDescription)); rollback succeeded from \(url.path)"
        case .restoreFailedRollbackFailed(let url, let error, let rollbackError):
            return "restore failed after live replacement (\(error.localizedDescription)); rollback from \(url.path) failed: \(rollbackError.localizedDescription)"
        }
    }

    var logIdentifier: String {
        switch self {
        case .unsafeStoragePath:
            return "unsafe-storage-path"
        case .recoveryBackupWriteFailed:
            return "recovery-backup-write-failed"
        case .recoveryBackupVerificationFailed:
            return "recovery-backup-verification-failed"
        case .candidateWriteFailed:
            return "candidate-write-failed"
        case .candidateVerificationFailed:
            return "candidate-verification-failed"
        case .liveReplacementFailed:
            return "live-replacement-failed"
        case .liveVerificationFailed:
            return "live-verification-failed"
        case .restoreFailedRollbackSucceeded:
            return "rollback-succeeded"
        case .restoreFailedRollbackFailed:
            return "rollback-failed"
        }
    }
}

final class JSONFilePersistence: StatePersisting, StateRestoring {
    let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager
    private let failureInjector: ((StateRestoreFailurePoint) throws -> Void)?

    static let automaticRecoveryRetentionCount = 5

    init(
        fileURL: URL = JSONFilePersistence.defaultFileURL(),
        fileManager: FileManager = .default,
        failureInjector: ((StateRestoreFailurePoint) throws -> Void)? = nil
    ) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        self.failureInjector = failureInjector

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() -> AppState {
        guard (try? CodePulseManagedStorage.validateStateFile(fileURL)) != nil else {
            NSLog("CodePulse refused to load an unsafe local state path.")
            return AppState()
        }
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
            let data = try encoder.encode(state)
            try writeStateDataAtomically(data)
        } catch {
            NSLog("CodePulse could not save local state: %@", error.localizedDescription)
        }
    }

    func replaceStateTransactionally(
        with state: AppState,
        recoverySnapshot: AppState,
        exportedAt: Date = Date()
    ) throws -> StateRestoreReceipt {
        let storageDirectory: URL
        do {
            storageDirectory = try CodePulseManagedStorage.validateStateFile(fileURL)
        } catch {
            throw StatePersistenceError.unsafeStoragePath
        }

        let boundary = storageDirectory.deletingLastPathComponent()
        do {
            try CodePulseManagedStorage.ensurePrivateDirectory(storageDirectory, through: boundary)
        } catch {
            throw StatePersistenceError.unsafeStoragePath
        }
        let recoveryDirectory = storageDirectory.appendingPathComponent("Backups", isDirectory: true)
        do {
            try CodePulseManagedStorage.ensurePrivateDirectory(recoveryDirectory, through: boundary)
        } catch {
            throw StatePersistenceError.unsafeStoragePath
        }

        let recoveryURL: URL
        do {
            recoveryURL = try nextRecoveryURL(in: recoveryDirectory, exportedAt: exportedAt)
        } catch {
            throw StatePersistenceError.recoveryBackupWriteFailed(
                recoveryDirectory,
                error
            )
        }

        let recoveryData: Data
        do {
            recoveryData = try CodePulseBackupCodec.encode(state: recoverySnapshot, exportedAt: exportedAt)
        } catch {
            throw StatePersistenceError.recoveryBackupWriteFailed(recoveryURL, error)
        }

        do {
            try inject(.recoveryWrite)
            try writeNewFileAtomically(recoveryData, to: recoveryURL, in: recoveryDirectory)
        } catch {
            throw StatePersistenceError.recoveryBackupWriteFailed(recoveryURL, error)
        }

        do {
            try inject(.recoveryVerification)
            try verifyRecoveryBackup(at: recoveryURL, expectedState: recoverySnapshot)
        } catch {
            throw StatePersistenceError.recoveryBackupVerificationFailed(recoveryURL, error)
        }

        // Retention is deliberately after a new recovery file has been
        // durably written and verified. Only our exact automatic filename
        // prefix is eligible; user-exported JSON is never scanned or pruned.
        pruneAutomaticRecoveryBackups(in: recoveryDirectory)

        let candidateData: Data
        do {
            candidateData = try encoder.encode(state)
        } catch {
            throw StatePersistenceError.candidateWriteFailed(error)
        }

        let candidateURL = storageDirectory.appendingPathComponent(
            ".state.restore-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        var liveReplacementStarted = false
        defer {
            try? fileManager.removeItem(at: candidateURL)
        }

        do {
            do {
                try inject(.candidateWrite)
                try writeTemporaryFile(candidateData, to: candidateURL, in: storageDirectory)
            } catch {
                throw StatePersistenceError.candidateWriteFailed(error)
            }

            do {
                try inject(.candidateVerification)
                try verifyStateFile(at: candidateURL, expectedState: state)
            } catch {
                throw StatePersistenceError.candidateVerificationFailed(error)
            }

            do {
                // Treat the replacement as started before invoking the file
                // operation. If the operation fails after mutating the target,
                // rollback is still attempted conservatively.
                try inject(.liveReplacement)
                liveReplacementStarted = true
                try replaceLiveState(with: candidateURL, in: storageDirectory)
            } catch {
                throw StatePersistenceError.liveReplacementFailed(error)
            }

            do {
                try inject(.afterLiveReplacement)
                try inject(.liveVerification)
                try verifyStateFile(at: fileURL, expectedState: state)
            } catch {
                throw StatePersistenceError.liveVerificationFailed(error)
            }
        } catch let error as StatePersistenceError {
            guard liveReplacementStarted else { throw error }

            do {
                try rollbackState(to: recoverySnapshot, in: storageDirectory)
            } catch let rollbackError as StatePersistenceError {
                throw StatePersistenceError.restoreFailedRollbackFailed(
                    recoveryURL,
                    error,
                    rollbackError
                )
            } catch let rollbackError {
                throw StatePersistenceError.restoreFailedRollbackFailed(
                    recoveryURL,
                    error,
                    rollbackError
                )
            }
            throw StatePersistenceError.restoreFailedRollbackSucceeded(recoveryURL, error)
        } catch let restoreError {
            if liveReplacementStarted {
                do {
                    try rollbackState(to: recoverySnapshot, in: storageDirectory)
                } catch let rollbackError {
                    throw StatePersistenceError.restoreFailedRollbackFailed(
                        recoveryURL,
                        restoreError,
                        rollbackError
                    )
                }
                throw StatePersistenceError.restoreFailedRollbackSucceeded(recoveryURL, restoreError)
            }
            throw StatePersistenceError.candidateWriteFailed(restoreError)
        }

        return StateRestoreReceipt(recoveryBackupURL: recoveryURL)
    }

    static func defaultFileURL() -> URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return directory.appendingPathComponent("CodePulse/state.json")
    }

    private func writeStateDataAtomically(_ data: Data) throws {
        let storageDirectory = try CodePulseManagedStorage.validateStateFile(fileURL)
        try CodePulseManagedStorage.ensurePrivateDirectory(
            storageDirectory,
            through: storageDirectory.deletingLastPathComponent()
        )

        let temporary = storageDirectory.appendingPathComponent(
            ".state.save-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporary) }
        try writeTemporaryFile(data, to: temporary, in: storageDirectory)
        try replaceLiveState(with: temporary, in: storageDirectory)
    }

    private func writeNewFileAtomically(_ data: Data, to target: URL, in directory: URL) throws {
        try CodePulseManagedStorage.validateDirectChild(target, of: directory)
        guard !fileManager.fileExists(atPath: target.path) else {
            throw ManagedStoragePathError.unsafePath
        }

        let temporary = directory.appendingPathComponent(
            ".\(target.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporary) }
        try writeTemporaryFile(data, to: temporary, in: directory)
        guard !fileManager.fileExists(atPath: target.path) else {
            throw ManagedStoragePathError.unsafePath
        }
        try fileManager.moveItem(at: temporary, to: target)
        try CodePulseManagedStorage.setPrivateFilePermissions(target)
    }

    private func writeTemporaryFile(_ data: Data, to temporary: URL, in directory: URL) throws {
        try CodePulseManagedStorage.validateDirectChild(temporary, of: directory)
        guard !fileManager.fileExists(atPath: temporary.path) else {
            throw ManagedStoragePathError.unsafePath
        }
        try data.write(to: temporary, options: .atomic)
        try CodePulseManagedStorage.setPrivateFilePermissions(temporary)
    }

    private func replaceLiveState(with temporary: URL, in directory: URL) throws {
        try CodePulseManagedStorage.validateDirectChild(temporary, of: directory)
        _ = try CodePulseManagedStorage.validateStateFile(fileURL)
        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: fileURL)
        }
        try CodePulseManagedStorage.setPrivateFilePermissions(fileURL)
    }

    private func verifyRecoveryBackup(at url: URL, expectedState: AppState) throws {
        let data = try Data(contentsOf: url)
        let backup = try CodePulseBackupCodec.decode(data)
        guard backup.state == CodePulseBackupCodec.portableState(from: expectedState) else {
            throw VerificationMismatch()
        }
    }

    private func verifyStateFile(at url: URL, expectedState: AppState) throws {
        let data = try Data(contentsOf: url)
        let decoded = try decoder.decode(AppState.self, from: data)
        guard decoded == expectedState else {
            throw VerificationMismatch()
        }
    }

    private func rollbackState(to state: AppState, in directory: URL) throws {
        try inject(.rollbackWrite)
        let data = try encoder.encode(state)
        let temporary = directory.appendingPathComponent(
            ".state.rollback-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporary) }
        try writeTemporaryFile(data, to: temporary, in: directory)
        try replaceLiveState(with: temporary, in: directory)
        try inject(.rollbackVerification)
        try verifyStateFile(at: fileURL, expectedState: state)
    }

    private func nextRecoveryURL(in directory: URL, exportedAt: Date) throws -> URL {
        let baseName = "Pre-Restore Backup \(Self.recoveryTimestampFormatter.string(from: exportedAt))"
        for suffix in 0..<10_000 {
            let name = suffix == 0 ? baseName : "\(baseName)-\(suffix)"
            let candidate = directory.appendingPathComponent("\(name).json", isDirectory: false)
            try CodePulseManagedStorage.validateDirectChild(candidate, of: directory)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw ManagedStoragePathError.unsafePath
    }

    private func pruneAutomaticRecoveryBackups(in directory: URL) {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let automatic = urls.filter { url in
            guard url.pathExtension.lowercased() == "json",
                  url.lastPathComponent.hasPrefix("Pre-Restore Backup "),
                  !CodePulseManagedStorage.isSymbolicLink(url),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return false
            }
            return true
        }
        let newestFirst = automatic.sorted { lhs, rhs in
            let leftDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            let rightDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
            return lhs.lastPathComponent > rhs.lastPathComponent
        }
        for url in newestFirst.dropFirst(Self.automaticRecoveryRetentionCount) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func inject(_ point: StateRestoreFailurePoint) throws {
        try failureInjector?(point)
    }

    private static let recoveryTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return formatter
    }()

    private struct VerificationMismatch: LocalizedError {
        var errorDescription: String? { "The durable CodePulse state did not match the expected state." }
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
