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
}
