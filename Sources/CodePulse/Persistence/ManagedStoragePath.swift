import Foundation

enum ManagedStoragePathError: LocalizedError {
    case unsafePath
    case targetEscapesDirectory
    case targetIsNotRegularFile

    var errorDescription: String? {
        "CodePulse storage path is unsafe."
    }
}

/// Narrow path checks for files CodePulse owns. User-selected backup input is
/// intentionally not passed through this type: it is read only after the user
/// explicitly chooses it in the file picker.
enum CodePulseManagedStorage {
    static func validateStateFile(_ fileURL: URL) throws -> URL {
        let directory = fileURL.deletingLastPathComponent().standardizedFileURL
        let target = fileURL.standardizedFileURL
        guard target.deletingLastPathComponent() == directory else {
            throw ManagedStoragePathError.targetEscapesDirectory
        }

        try validateManagedPath(directory, through: directory.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: target.path) {
            guard !isSymbolicLink(target), isRegularFile(target) else {
                throw isSymbolicLink(target)
                    ? ManagedStoragePathError.unsafePath
                    : ManagedStoragePathError.targetIsNotRegularFile
            }
        }
        return directory
    }

    static func ensurePrivateDirectory(_ directory: URL, through boundary: URL) throws {
        try validateManagedPath(directory, through: boundary)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try validateManagedPath(directory, through: boundary)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directory.path
        )
    }

    static func validateDirectChild(_ fileURL: URL, of directory: URL) throws {
        let standardizedDirectory = directory.standardizedFileURL
        let target = fileURL.standardizedFileURL
        guard target.deletingLastPathComponent() == standardizedDirectory else {
            throw ManagedStoragePathError.targetEscapesDirectory
        }

        try validateManagedPath(standardizedDirectory, through: standardizedDirectory.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: target.path), isSymbolicLink(target) {
            throw ManagedStoragePathError.unsafePath
        }
    }

    static func setPrivateFilePermissions(_ fileURL: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: fileURL.path
        )
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink == true
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true
    }

    private static func validateManagedPath(_ path: URL, through boundary: URL) throws {
        let standardizedPath = path.standardizedFileURL
        let standardizedBoundary = boundary.standardizedFileURL
        var current = standardizedPath

        while true {
            if isSymbolicLink(current) {
                throw ManagedStoragePathError.unsafePath
            }
            if current == standardizedBoundary {
                return
            }

            let parent = current.deletingLastPathComponent()
            guard parent != current else {
                throw ManagedStoragePathError.targetEscapesDirectory
            }
            current = parent
        }
    }
}
