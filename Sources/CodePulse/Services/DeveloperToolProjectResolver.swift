import CodePulseIntegration
import Foundation

enum DeveloperToolProjectResolver {
    static func folderPath(for project: ProjectRecord) -> String? {
        #if os(macOS)
        if let bookmarkData = project.bookmarkData {
            var isStale = false
            if let bookmarkedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return bookmarkedURL.path
            }
        }
        #endif
        return project.folderPath
    }

    static func isUsableFolder(for project: ProjectRecord) -> Bool {
        guard let path = folderPath(for: project) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Resolves a developer-tool working directory to one active CodePulse
    /// project. The path is canonicalized with the same matcher used by the
    /// Developer Integrations inbox, so descendants and symlinked paths use
    /// identical containment semantics everywhere.
    ///
    /// When projects overlap, the most specific configured root owns the
    /// activity. Duplicate roots are ambiguous and fail closed rather than
    /// allowing an event to select an arbitrary automation rule.
    static func projectID(
        for workingDirectory: String,
        in projects: [ProjectRecord]
    ) -> UUID? {
        guard let canonicalWorkingDirectory = DeveloperToolProjectPathMatcher.canonicalPath(
            for: workingDirectory
        ) else {
            return nil
        }

        let matches = projects.compactMap { project -> (id: UUID, depth: Int)? in
            guard project.isActive,
                  let projectPath = folderPath(for: project),
                  isUsableFolder(for: project),
                  let canonicalProjectPath = DeveloperToolProjectPathMatcher.canonicalPath(
                      for: projectPath
                  ),
                  DeveloperToolProjectPathMatcher.matches(
                      projectPath: canonicalProjectPath,
                      workingDirectory: canonicalWorkingDirectory
                  ) else {
                return nil
            }

            return (
                id: project.id,
                depth: URL(fileURLWithPath: canonicalProjectPath).pathComponents.count
            )
        }

        guard let deepest = matches.map({ $0.depth }).max() else { return nil }
        let mostSpecific = matches.filter { $0.depth == deepest }
        guard mostSpecific.count == 1 else { return nil }
        return mostSpecific[0].id
    }
}
