import CodePulseIntegration
import Foundation

protocol LocalTaskResolving {
    func resolve(workingDirectory: String) -> LocalTaskIdentity?
}

/// Resolves only a supplied local path. It never enumerates a directory and
/// identifies broad roots as transient tasks so they cannot become projects.
struct SystemLocalTaskResolver: LocalTaskResolving {
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let temporaryDirectory: URL

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.temporaryDirectory = temporaryDirectory.standardizedFileURL
    }

    func resolve(workingDirectory: String) -> LocalTaskIdentity? {
        guard let canonicalPath = DeveloperToolProjectPathMatcher.canonicalPath(for: workingDirectory) else { return nil }
        let broad = canonicalPath == "/" ||
            canonicalPath == homeDirectory.path ||
            DeveloperToolProjectPathMatcher.matches(projectPath: temporaryDirectory.path, workingDirectory: canonicalPath) ||
            canonicalPath == "/tmp"
        let url = URL(fileURLWithPath: canonicalPath)
        var isDirectory: ObjCBool = false
        let exists = fileManager.fileExists(atPath: canonicalPath, isDirectory: &isDirectory)
        let isFile = exists && !isDirectory.boolValue
        let displayName = url.lastPathComponent
        return LocalTaskIdentity(
            canonicalPath: canonicalPath,
            displayName: broad ? "Transient local task" : (displayName.isEmpty ? "Local task" : displayName),
            isFile: isFile,
            isTransient: broad
        )
    }
}
