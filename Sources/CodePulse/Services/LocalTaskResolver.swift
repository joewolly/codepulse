import CodePulseIntegration
import Foundation

protocol LocalTaskResolving {
    func resolve(workingDirectory: String) -> LocalTaskIdentity?
}

/// Resolves only a supplied local path. It never enumerates a directory and
/// identifies broad roots as transient tasks so they cannot become projects.
struct SystemLocalTaskResolver: LocalTaskResolving {
    private let homeDirectory: URL
    private let temporaryDirectory: URL

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.temporaryDirectory = temporaryDirectory.standardizedFileURL
    }

    func resolve(workingDirectory: String) -> LocalTaskIdentity? {
        guard let canonicalPath = DeveloperToolProjectPathMatcher.canonicalPath(for: workingDirectory) else { return nil }
        let broad = canonicalPath == "/" ||
            canonicalPath == homeDirectory.path ||
            DeveloperToolProjectPathMatcher.matches(projectPath: temporaryDirectory.path, workingDirectory: canonicalPath) ||
            canonicalPath == "/tmp"
        let displayName = URL(fileURLWithPath: canonicalPath).lastPathComponent
        return LocalTaskIdentity(
            canonicalPath: canonicalPath,
            displayName: broad ? "Transient local task" : (displayName.isEmpty ? "Local task" : displayName),
            isTransient: broad
        )
    }
}
