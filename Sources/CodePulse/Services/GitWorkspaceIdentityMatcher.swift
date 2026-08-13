import Foundation

enum GitWorkspaceIdentityMatcher {
    /// Exact common-directory/worktree matches win. Sibling worktrees sharing
    /// one Git common directory remain separate; distinct clones can merge by
    /// normalized repository identity and retain multiple roots.
    static func workspaceIndex(for identity: GitWorkspaceIdentity, in graph: ActivityGraph) -> Int? {
        for index in graph.workspaces.indices {
            for root in graph.workspaces[index].roots {
                guard let existing = root.gitIdentity else { continue }
                if existing.commonDirectory == identity.commonDirectory,
                   existing.worktreeRoot == identity.worktreeRoot {
                    return index
                }
            }
        }
        if graph.workspaces.contains(where: { workspace in
            workspace.roots.contains { root in
                guard let existing = root.gitIdentity else { return false }
                return existing.commonDirectory == identity.commonDirectory && existing.worktreeRoot != identity.worktreeRoot
            }
        }) {
            return nil
        }
        if let repository = identity.repository,
           let index = graph.workspaces.indices.first(where: { index in
               graph.workspaces[index].roots.contains { $0.gitIdentity?.repository == repository }
           }) {
            return index
        }
        return graph.workspaces.indices.first(where: { index in
            graph.workspaces[index].roots.contains { $0.gitIdentity?.worktreeRoot == identity.worktreeRoot }
        })
    }
}
