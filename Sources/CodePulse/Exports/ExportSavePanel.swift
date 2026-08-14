import AppKit
import UniformTypeIdentifiers

@MainActor
enum ExportSavePanel {
    static func chooseURL(
        defaultName: String,
        contentType: UTType,
        prompt: String
    ) -> URL? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = defaultName
        panel.prompt = prompt
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}
