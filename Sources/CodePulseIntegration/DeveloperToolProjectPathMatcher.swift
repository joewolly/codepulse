import Foundation

public enum DeveloperToolProjectPathMatcher {
    public static func canonicalPath(for path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= DeveloperToolIntegrationLimits.maximumPathLength,
              trimmed.hasPrefix("/"),
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return nil
        }

        let url = URL(fileURLWithPath: trimmed, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let canonical = url.path
        guard canonical.hasPrefix("/") else { return nil }
        return canonical
    }

    public static func matches(projectPath: String, workingDirectory: String) -> Bool {
        guard let canonicalProject = canonicalPath(for: projectPath),
              let canonicalWorkingDirectory = canonicalPath(for: workingDirectory) else {
            return false
        }

        let projectComponents = URL(fileURLWithPath: canonicalProject).pathComponents
        let workingComponents = URL(fileURLWithPath: canonicalWorkingDirectory).pathComponents
        guard workingComponents.count >= projectComponents.count else { return false }
        return Array(workingComponents.prefix(projectComponents.count)) == projectComponents
    }
}
