# Privacy

CodePulse is designed as a local-first coding timer and journal. It does not
require an account and does not include cloud sync, telemetry, product analytics,
advertising, or activity monitoring.

## Data stored on the Mac

CodePulse stores its JSON state under
`~/Library/Application Support/CodePulse`. Depending on how the app is used,
that state can include:

- Projects, including display names, selected folder paths, and security-scoped
  bookmark data.
- Session start and finish times, pause intervals, work types, goals, and
  outcomes.
- Best-effort Git snapshots such as repository paths, branches, commit IDs, and
  aggregate diff statistics.
- App settings and any active session needed for relaunch recovery.

CodePulse reads only the project folders the user selects. Git inspection uses
the local `/usr/bin/git` executable and does not modify repositories.

## Network access

CodePulse does not send session, project, Git, or usage data to a CodePulse
service. Sparkle is the only built-in network client: it checks the CodePulse
appcast and downloads update archives from GitHub Releases. Downloaded updates
are authenticated with an Ed25519 signature before installation.

## Backups

Backup export creates a versioned JSON file at a location chosen by the user.
The backup can contain the same local state described above, including freeform
session text and filesystem paths. CodePulse does not intentionally add
credentials or file contents, but user-entered text may itself be sensitive.
Protect backup files and review them before sharing.

CodePulse currently exports backups but does not restore them automatically.

## Deleting data

Individual saved sessions and projects can be removed inside CodePulse. Removing
a project from CodePulse does not delete the project folder. To remove all local
CodePulse state, quit the app and delete its Application Support data; keep any
backup files only if they are still wanted.
