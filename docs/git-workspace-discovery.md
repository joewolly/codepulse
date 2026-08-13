# Git workspace discovery

When **Automatically create Git workspaces from agent events** is enabled,
CodePulse resolves only the event's supplied local working directory with
bounded Git commands. It does not scan the disk or inspect repository files.

For a valid Git worktree, CodePulse retains the canonical worktree root, Git
common directory, current branch when available, linked-worktree relation, and
a normalized `owner/repository` identity only for a valid GitHub remote. It does
not retain remote URLs, credentials, or unrecognized remote addresses.

The identity order prevents accidental merges: the same Git common directory
plus worktree root is an exact match; sibling worktrees stay separate; separate
clones of the same normalized remote can be one workspace with multiple roots;
and a canonical local root is the final fallback. Renaming a discovered
workspace never changes its identity or name on later events.

Disable discovery globally in **Settings → Workspace Discovery** to prevent new
workspaces. Existing history is retained. You can also disable automatic updates
for an individual discovered workspace without deleting it.
