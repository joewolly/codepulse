import Foundation

/// Presentation-only scope used by History and Insights. A workspace scope
/// resolves to the projects that currently belong to that workspace; it never
/// becomes part of session or developer-tool ownership.
enum WorkspaceScope: Hashable, Equatable {
    case allWorkspaces
    case workspaceID(UUID)
}

struct WorkspaceScopeOption: Identifiable, Hashable {
    let id: String
    let title: String
    let scope: WorkspaceScope
}
