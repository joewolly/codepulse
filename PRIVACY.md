# Privacy

CodePulse is designed as a local-first coding timer and journal. It does not
require an account and does not include cloud sync, telemetry, product analytics,
advertising, or application-usage history. Optional Session Automation performs
local workflow detection only when the user enables it: it reacts to supported
developer-tool lifecycle metadata and, when explicitly configured, the current
frontmost application's bundle identifier.

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
- Optional GitHub snapshots such as the normalized repository identity and
  lightweight pull request metadata (number, title, state, draft status, URL,
  and branch names).
- App settings and any active session needed for relaunch recovery.
- Session Presets, optional Session Automation rules, configured application
  bundle identifiers/display names, the global automation setting, and the
  bounded ownership/timing metadata needed to recover an automatically started
  active session. Raw developer-tool event files and an unbounded application
  activation history are not stored in backups.
- Processed developer-integration event identifiers and processing timestamps for
  local deduplication; this bounded ledger retains at most 2,048 entries and
  prunes entries older than 30 days during event processing. It is machine-local
  replay bookkeeping and is omitted from portable backups.
- A separate bounded internal ledger of processed `codepulsectl` mutation UUIDs
  and privacy-minimal responses may be kept in the live state for exactly-once
  relaunch recovery. It is not a permanent command history and is omitted from
  exported backups. Raw control commands and response files are transient.

CodePulse reads only the project folders the user selects. Git inspection uses
the local `/usr/bin/git` executable and does not modify repositories.

## Optional Developer Integrations

Codex and OpenCode integrations are disabled unless the user enables them in
**Settings → Integrations**. Session Automation is a separate setting in
**Settings → Session Automation** and is disabled by default. When an
integration is enabled, CodePulse records only the minimum
metadata needed to answer which supported developer tool participated in an
active session:

- Tool name (`Codex` or `OpenCode`).
- The tool's external session identifier.
- The tool-reported working directory, after safe path normalization.
- Lifecycle timestamps and a bounded activity-event count.
- An optional model label and optional profile/agent label when the tool
  supplies them reliably.

The integration helper accepts one structured event at a time and atomically
writes it to the local inbox at
`~/Library/Application Support/CodePulse/Integrations/Inbox/`. CodePulse does
not need to be running for an event to wait there. Events are validated,
matched to a selected project by canonical folder hierarchy, deduplicated, and
removed on a best-effort basis after processing. A filesystem failure may leave
an inbox file locally; valid events remain in the bounded ledger to prevent
duplicate attachment. No Project sessions and wrong-project events are not
attached.

CodePulse does **not** persist or inspect prompts, user messages, assistant
messages, conversation transcripts, source-file contents, terminal command
contents, command output, tool-call arguments, tool-call results, permission
decisions, reasoning, conversation summaries, credentials, or API keys. The
Codex adapter does not parse transcript files. The OpenCode adapter does not
scrape conversation storage or subscribe to content/tool events.

The live CodePulse state can contain developer-tool metadata and the
processed-event ledger. Portable backups retain only developer-tool contexts
already attached to saved or active sessions; they omit the live processed-event
ledger and the separate control ledger. Restoring a backup resets both ledgers,
preserves the current Mac's launch-at-login setting, and leaves Session
Automation disabled until the user reviews it. Automation rules and active-session
ownership are local configuration/recovery state; imported active-session
timelines are retained while stale automation claims and pending automatic-save
ownership are cleared. When an application rule is enabled, CodePulse observes
the current frontmost application through native workspace activation
notifications and compares its bundle identifier against configured rules. It
does not inspect windows or persist activation/deactivation history. Disabling
an integration removes only the CodePulse-owned hook or plugin configuration;
it does not delete user-owned tool configuration.

## Backup restore

The **Settings → Data** restore workflow reads a user-selected JSON file locally,
shows a summary before confirmation, and replaces local state only after a
verified recovery backup has been created. Backups can contain paths, bookmarks,
session notes, and metadata, so treat both exported and automatic recovery files
as potentially sensitive. No backup is uploaded to CodePulse or a cloud
service. A moved project whose bookmark cannot resolve remains stored and is
shown as needing relinking; CodePulse does not silently retarget it.

## CSV and Markdown exports

History CSV export contains only completed sessions matching the current History
filters and uses standard UTF-8 at a destination selected by the user. It does
not include project bookmark data, raw repository paths, control or replay
ledgers, automation claims, or external developer-tool session identifiers.
Developer-tool names, model/profile labels, Git aggregates, GitHub repository
and pull-request snapshots, and user-authored goals/outcomes are included when
they are part of the selected session context.

Insights Markdown reports contain the currently selected local timeframe and
project summary and reuse the existing in-memory Insights calculations. Reports
are deterministic local files; CodePulse does not use AI or upload CSV or
Markdown exports to a cloud service.

Application automation does not collect or retain unrelated application
durations, window titles, document names, file names, browser URLs, terminal
contents, clipboard contents, keyboard or mouse input, screen contents, or
accessibility element contents. It does not require Accessibility or Screen
Recording permission.

## External local control

The optional `codepulsectl` executable communicates only with a running CodePulse
app through a CodePulse-owned local command/response path under Application
Support. It sends command metadata needed for the requested action: a version,
UUID, timestamp, action, and—only for a requested start—the selected preset or
existing project/type/optional goal. It does not send prompts, transcripts,
source code, external developer-tool IDs, credentials, GitHub tokens, or
filesystem locations to a service. There is no cloud or network control path.

Commands expire after a short bounded window, malformed or unexpected fields
are rejected, pending storage and response storage are capped, and a bounded
UUID ledger prevents a mutation from executing twice after a relaunch. The
ledger stores no raw command text, and command/response files are cleaned up on
processing or timeout on a best-effort basis.

## Network access

CodePulse does not send session, project, Git, GitHub context, or usage data to
a CodePulse service. Sparkle checks the CodePulse appcast and downloads update
archives from GitHub Releases. When the optional GitHub Context feature is
available, CodePulse invokes the user's local `gh` executable with only the
repository and branch needed to read repository and pull request metadata.
CodePulse does not store GitHub credentials, ask for a Personal Access Token, or
perform GitHub mutations. Downloaded updates are authenticated with an Ed25519
signature before installation.

Insights in CodePulse 0.7 are derived in memory from the local session records
already described above. Timeframe totals, counts, project/work-type
breakdowns, developer-tool participation, Git totals, and GitHub repository/PR
aggregates are not stored in a separate analytics database or uploaded. GitHub
context shown for a historical session is the snapshot saved with that session;
CodePulse does not poll GitHub to rewrite historical analytics. Git Activity is
descriptive metadata only and is not converted into a productivity or efficiency
score.

## Backups

Backup export creates a versioned JSON file at a location chosen by the user.
The backup can contain the same portable local state described above, including
freeform session text, filesystem paths, session presets, configured application
identities, attached developer-tool metadata, automation rules, and active
automation ownership needed for recovery. The machine-local processed-event
ledger, containing event identifiers and processing timestamps (up to 2,048
entries; event processing prunes entries older than 30 days), is omitted. The
separate bounded
`codepulsectl` mutation ledger, raw control commands, response files, transient
status requests, and application activation history are not intentionally
added.
CodePulse does not intentionally add credentials, conversation content, or file
contents, but user-entered text may itself be sensitive. Protect backup files
and review them before sharing.

CodePulse restores backups only when the user explicitly selects a file in
Settings and confirms replacement of local data; it does not restore backups
automatically or contact a cloud service.

## Deleting data

Individual saved sessions and projects can be removed inside CodePulse. Removing
a project from CodePulse does not delete the project folder. To remove all local
CodePulse state, quit the app and delete its Application Support data; keep any
backup files only if they are still wanted.
