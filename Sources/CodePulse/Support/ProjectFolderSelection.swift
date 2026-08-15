import AppKit

@MainActor
enum ProjectFolderSelection {
    static func chooseFolder(prompt: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    @discardableResult
    static func addProject(to store: SessionStore, folderURL: URL?) -> UUID? {
        guard let folderURL else { return nil }
        return store.addProject(name: folderURL.lastPathComponent, folderURL: folderURL)
    }

    @discardableResult
    static func chooseAndAddProject(to store: SessionStore, prompt: String) -> UUID? {
        addProject(to: store, folderURL: chooseFolder(prompt: prompt))
    }
}
