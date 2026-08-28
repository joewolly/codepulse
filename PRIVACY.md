# Privacy

CodePulse is designed as a local-first coding timer and journal. It does not
require an account and does not include cloud sync, telemetry, product analytics,
advertising, or application-usage history. Optional Session Automation performs
local workflow detection only when the user enables it: it reacts to supported
developer-tool lifecycle metadata and, when explicitly configured, the current
frontmost application's bundle identifier.

The current 1.4-era implementation has one optional active Session. The
accepted v1.5 architecture (specified in
[`docs/v1.5-concurrent-sessions.md`](docs/v1.5-concurrent-sessions.md)) allows
multiple local active Sessions, but concurrency does not expand data collection
or introduce a cloud service.

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
- App settings and the active-session timeline needed for current 1.4 relaunch
  recovery. Planned v1.5 state may contain a bounded collection of such local
  timelines.
- Session Presets, optional Session Automation rules, configured application
  bundle identifiers/display names, the global automation setting, and the
  bounded ownership/timing metadata needed to recover an automatically started
  active Session. In planned v1.5 backups, the same bounded ownership/timing
  metadata may exist for multiple active Sessions. Raw developer-tool event
  files and an unbounded application activation history are not stored in
  backups.
- Processed developer-integration event identifiers and processing timestamps for
  local deduplication; this bounded ledger retains at most 2,048 entries and
  prunes entries older than 30 days during event processing. It is machine-local
  replay bookkeeping and is omitted from portable backups.
- Planned v1.5 may also retain a separate retired Developer-Tool Thread ledger
  containing only `(tool, externalSessionID)`, `retiredAt`, and
  `lastAcceptedEventAt`. It is bounded to 2,048 entries, protects a retired
  identity for 7 days, prunes expired entries before oldest-first count
  handling, and fails closed rather than evicting a still-protected entry. This
  machine-local metadata is not user-authored history, a transcript, or content,
  and is omitted/reset in portable backups and restore.
- A separate bounded internal ledger of processed `codepulsectl` mutation UUIDs
  and privacy-minimal responses may be kept in the live state for exactly-once
  relaunch recovery. It is not a permanent command history and is omitted from
  exported backups. Raw control commands and response files are transient.

CodePulse reads only the project folders the user selects. Git inspection uses
the local `/usr/bin/git` executable and does not modify repositories.

## Optional Developer Integrations

Codex and OpenCode integrations are disabled unless the user enables them in
**Settings → Automation → Developer Integrations**. Session Automation is a
separate setting in **Settings → Automation → Session Automation** and is
disabled by default. When an
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
matched to a selected project by canonical folder hierarchy in the current 1.4
implementation, deduplicated, and removed on a best-effort basis after
processing. A filesystem failure may leave an inbox file locally; valid events
remain in the bounded ledger to prevent duplicate attachment. No Project
sessions and wrong-project events are not attached. The planned v1.5 routing
contract is defined below and revalidates the resolved Project for every event.

Under the planned v1.5 model, metadata for several simultaneous local
Developer-Tool Threads may exist at once. External session IDs are lifecycle
routing metadata, not message content or Project identity. Every event’s
canonical working directory is resolved and revalidated against the owning
local Project before a Thread-owned Session is mutated; the selected Workspace
and frontmost application do not establish ownership. The same privacy limits
apply to every concurrent Thread: no prompt, transcript, message, command
text, command output, source-code contents, or secret is collected.

CodePulse does **not** persist or inspect prompts, user messages, assistant
messages, conversation transcripts, source-file contents, terminal command
contents, command output, tool-call arguments, tool-call results, permission
decisions, reasoning, conversation summaries, credentials, or API keys. The
Codex adapter does not parse transcript files. The OpenCode adapter does not
scrape conversation storage or subscribe to content/tool events.

The live CodePulse state can contain developer-tool metadata, the
processed-event ledger, and (planned v1.5) the bounded retired-Thread ledger.
Portable backups retain only developer-tool contexts already attached to saved
or active sessions; they omit the live processed-event, retired-Thread, and
separate control ledgers. Restoring a backup resets all three machine-local
ledgers, preserves the current Mac's launch-at-login setting, and leaves
Session Automation disabled until the user reviews it. Automation rules and
active-session ownership are local configuration/recovery state; imported
active-session timelines are retained while stale automation claims and pending
automatic-save ownership are cleared. When an application rule is enabled,
CodePulse observes the current frontmost application through native workspace
activation notifications and compares its bundle identifier against configured
rules. It does not inspect windows or persist activation/deactivation history.
Disabling an integration removes only the CodePulse-owned hook or plugin
configuration; it does not delete user-owned tool configuration.

## Backup restore

The **Settings → Data** restore workflow reads a user-selected JSON file locally,
shows a summary before confirmation, and replaces local state only after a
verified recovery backup has been created. Backups can contain paths, bookmarks,
session notes, and metadata, so treat both exported and automatic recovery files
as potentially sensitive. No backup is uploaded to CodePulse or a cloud
service. A moved project whose bookmark cannot resolve remains stored and is
shown as needing relinking; CodePulse does not silently retarget it. If the
existing primary state cannot be decoded, CodePulse keeps the original bytes
unchanged, disables normal writes, and offers a local recovery window instead
of showing fresh-install onboarding. An explicit restore preserves those
unreadable bytes in a private local recovery copy; that copy is not treated as
a portable backup and is not uploaded.

The current 1.4 restore path is guarded by its single active-session state. The
planned v1.5 path retains the same transactional guard for any running,
paused, or finishing Session and for any in-progress per-Session Git capture;
its backup-v3 preview reports an active-session count rather than only a
boolean. These changes affect local state shape, not the privacy boundary.

## CSV and Markdown exports

History CSV export contains only completed sessions matching the current History
filters and uses standard UTF-8 at a destination selected by the user. It does
not include project bookmark data, raw repository paths, control or replay
ledgers, automation claims, or external developer-tool session identifiers.
Developer-tool names, model/profile labels, Git aggregates, GitHub repository
and pull-request snapshots, and user-authored goals/outcomes are included when
they are part of the selected session context.

Insights Markdown reports contain the currently selected local timeframe and
project summary and reuse the existing in-memory Insights calculations. The
Project Outcomes section may include a bounded set of user-authored Goal/Actual
text shown by Insights when the user explicitly chooses **Export Report…**.
This is local and user-initiated; CodePulse does not use AI or upload CSV or
Markdown exports to a cloud service. Goal vs Actual and Focus Patterns remain
aggregate-only.

## Local daily and weekly digests

Opt-in digest notifications are computed locally from the same Insights data.
They may contain aggregate goal/outcome completion counts or a follow-up count
when completed sessions with goals are missing outcomes, but never the
underlying goal or outcome text. Digests do not include prompts, messages,
transcripts, paths, repository URLs, branches, or pull-request titles.

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

Insights are derived in memory from the local session records already described
above. Timeframe totals, counts, project/work-type breakdowns,
developer-tool participation, Git totals, GitHub repository/PR aggregates,
Focus Patterns, and Project Outcomes are not stored in a separate analytics
database or uploaded. Project Outcomes uses only completed-session timestamps,
project identity, clipped active duration, and the Goal/Outcome text already
recorded by the user. It performs no semantic interpretation: CodePulse does
not decide whether work succeeded, failed, finished, or was abandoned, and it
creates no new telemetry or database. Focus Patterns use only existing session
timestamps, pause
intervals, project identity, session type, selected timeframe, and Calendar to
derive active segments, focus blocks, sustained-focus time/share, project
switches, and local hour/day buckets. They do not inspect application or window
content, keyboard or mouse input, documents, screens, prompts, messages, source
code, terminals, or clipboard data, and create no new telemetry or collection.
Focus metrics are observable timing summaries, not a productivity, cognition,
concentration, distraction, or efficiency score. GitHub context shown for a
historical session is the snapshot saved with that session; CodePulse does not
poll GitHub to rewrite historical analytics. Git Activity is descriptive
metadata only and is not converted into a productivity or efficiency score.

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
