# Privacy

CodePulse is designed as a local-first coding timer and journal. It does not
require an account and does not include cloud sync, telemetry, product analytics,
advertising, or activity monitoring.

## Data stored on the Mac

CodePulse stores its versioned JSON state under
`~/Library/Application Support/CodePulse/state.json`. Before a migration or
replacement write, it retains the last readable state at `state.json.backup`.
Depending on how the app is used, that state can include:

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
- Processed legacy developer-integration event identifiers and processing
  timestamps for local deduplication; this bounded ledger retains at most 2,048
  entries and prunes entries older than 30 days during event processing.
- Bounded v2 developer-event diagnostics: receipt status, fixed redacted
  rejection codes, parser/integration versions, and installation-salted event
  fingerprints. Agent runs retain only the integration, salted session
  fingerprint, lifecycle state, and interval timestamps needed for timing.
- Activity-classification records: a constrained work-type or domain label,
  source, confidence, timestamp, and coarse evidence category. These records
  do not contain raw lifecycle metadata, prompts, excerpts, tokens, hashes, or
  embeddings.

CodePulse reads only the project folders the user selects. Git inspection uses
the local `/usr/bin/git` executable and does not modify repositories.

## Optional Developer Integrations

Codex and OpenCode integrations are disabled unless the user enables them in
**Settings → Integrations**. When enabled, CodePulse records only the minimum
metadata needed to answer which supported developer tool participated in an
active session:

- Tool name (`Codex` or `OpenCode`).
- The tool's external session identifier.
- The tool-reported working directory, after safe path normalization.
- Lifecycle timestamps and a bounded activity-event count.
- An optional model label and optional profile/agent label when the tool
  supplies them reliably.

The integration helper accepts one structured event at a time and normalizes it
through the v2 receiver. It writes only validated events and content-free
accepted, duplicate, or rejected receipts under
`~/Library/Application Support/CodePulse/Integrations/`. CodePulse does not
need to be running for an event or receipt to wait there. A filesystem failure
may leave an inbox file locally; the app removes handoffs best-effort after
processing. Agent-run correlation is conservative and is not inferred from
unrelated projects or manual sessions.

CodePulse does **not** persist prompts, user messages, assistant messages,
conversation transcripts, source-file contents, terminal command contents,
command output, tool-call arguments, tool-call results, permission decisions,
reasoning, conversation summaries, credentials, or API keys. The Codex adapter
does not parse transcript files. The OpenCode adapter does not scrape
conversation storage or subscribe to content/tool events. The separately
consented **Use local prompt classification** setting may classify a supported
prompt in memory; it immediately discards the text and retains only the
content-free labels and `ephemeralPrompt` source. It is off by default and has
no effect on lifecycle timing.

Developer-tool metadata, redacted diagnostics, agent-run lifecycle metadata,
and the processed-event ledger remain local as part of CodePulse state and
normal JSON backups. Disabling an integration removes only the CodePulse-owned
hook or plugin configuration; it does not delete user-owned tool configuration.

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
The backup can contain the same local state described above, including freeform
session text, filesystem paths, optional developer-tool metadata, and the
processed-event ledger containing event identifiers and processing timestamps
(up to 2,048 entries; event processing prunes entries older than 30 days).
CodePulse does not intentionally add credentials, conversation content, or file
contents, but user-entered text may itself be sensitive. Protect backup files
and review them before sharing.

CodePulse currently exports backups but does not restore them automatically.

## Deleting data

Individual saved sessions and projects can be removed inside CodePulse. Removing
a project from CodePulse does not delete the project folder. To remove all local
CodePulse state, quit the app and delete its Application Support data; keep any
backup files only if they are still wanted.
