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
- Pricing-catalog state: only signed provider-published rate metadata (model
  aliases, token-unit rates, effective/expiry dates, source URLs, catalog
  version, key identifier, and signature) plus an optional verified cached
  catalog.
- Optional Codex usage state: installation-salted session and source
  fingerprints, bounded byte offsets/checkpoints, model labels, token deltas,
  unassigned-or-conservatively-matched run/workspace identifiers, and immutable
  pricing provenance. It never contains a raw Codex session ID, path, JSONL
  record, prompt, transcript, command, or source-file text.
- Optional Claude Code usage state: installation-salted session, source, and
  processed-record fingerprints; bounded offsets/checkpoints; timestamps,
  model, effort/service mode, token counters, available provider-reported cost,
  and conservative run/workspace links. It never contains a raw Claude session
  ID, transcript path, message body, prompt, response, tool data, command, or
  source-file text.
- Optional OpenCode usage state: installation-salted session fingerprints,
  timestamps, model/provider and service-mode labels, token counters, available
  provider-reported USD cost, conservative run/workspace links, calculated-cost
  provenance, and a small adapter-health summary. It never contains an OpenCode
  session or message ID, message body, prompt, response, tool data, command,
  database record, transcript, or source-file text.
- Usage-attribution views: derived, in-memory totals and privacy-safe
  reconciliation rows. They use existing sample, workspace, activity, and run
  data; they do not add a raw-identifier index, a new analytics database, or a
  new external data source.
- Usage Insights export: a user-selected local CSV or JSON file for the chosen
  period/project filter. It contains only usage counters, labeled costs and
  available calculation provenance, plus context labels the user explicitly
  selects. Paths, UUIDs, raw source/session identifiers, fingerprints, prompts,
  transcripts, commands, source content, and credentials are never included.

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

CodePulse does **not** inspect or persist prompts, user messages, assistant messages,
conversation transcripts, source-file contents, terminal command contents,
command output, tool-call arguments, tool-call results, permission decisions,
reasoning, conversation summaries, credentials, or API keys. The Codex adapter
does not retain or parse transcript content. When **Track Codex token usage** is
separately enabled, it reads only `session_meta`, `turn_context`, and
`event_msg` records with `token_count` totals from current local
`~/.codex/sessions` JSONL files; it skips all other record types and does not
read archived-session data. The OpenCode adapter does not scrape conversation
storage or subscribe to tool, command, or file events. When **Track OpenCode
token usage** is separately enabled, its CodePulse-owned plugin receives only
an assistant-message update and emits an allowlisted usage record: session and
message identity, working directory, timestamp, model/provider, service mode,
numeric token counters, and a reported USD cost when available. It omits
message text and all other message fields before the local handoff. CodePulse
does not use an OpenCode database fallback. Prompt classification is not
implemented: no integration sends prompt text to CodePulse, and the v2 event
schema rejects prompt-bearing fields.

When **Track Claude Code token usage** is separately enabled, CodePulse opens
current local `~/.claude/projects` JSONL session records solely to parse
assistant-record usage metadata: session identity, timestamp, model,
effort/service mode, token counters, and a reported USD cost when present. The
same source records can contain conversation text, but CodePulse discards that
content during parsing and never persists or exports it. Session identifiers,
file paths, and per-record identifiers are salted before storage. Lifecycle
metadata provides parent/subagent relationships; child samples are stored once.

Codex token tracking is off by default and independent from lifecycle timing.
Turning it off immediately stops CodePulse from enumerating or opening Codex
usage files; it retains already stored local, privacy-safe usage metadata until
the user deletes CodePulse data. Token totals use cumulative deltas to avoid
double-counting repeated records. A sample is attached only to one matching
Codex run; ambiguous or delayed samples remain unassigned.

Claude Code token tracking is also off by default and independent from timing.
Turning it off immediately stops CodePulse from enumerating or opening Claude
usage files. It retains existing privacy-safe local usage history until the
user deletes CodePulse data. A parent roll-up adds parent-exclusive and child
samples once; when a supported parent aggregate explicitly includes children,
the aggregate is used instead to avoid double counting.

OpenCode token tracking is likewise off by default and independent from timing.
The local helper checks this stored consent before decoding or writing any usage
handoff, and the app does not enumerate its usage inbox while disabled. Turning
it off therefore stops CodePulse from accepting or processing new OpenCode usage
records immediately; existing privacy-safe local usage history remains until the
user deletes CodePulse data. A missing, malformed, or future-version plugin
record updates only the optional usage adapter-health state and never changes
lifecycle timing.

Usage attribution does not collect or persist new source data. Its
reconciliation rows display only an ordinal local sample label and safe
dimensions such as workspace/activity names, tool, model, provider, and token
or cost totals. They never display raw session fingerprints, paths, prompts,
transcripts, or source-event identifiers.

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

If a future configured catalog refresh is requested, it fetches only a public
HTTPS pricing manifest. No CodePulse state, token counters, project paths, or
session metadata is sent with that request. The manifest must pass local P-256
signature and monotonic-version checks before it can replace the cached catalog.

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

Backups can include the privacy-safe token/cost metadata and calculation
provenance described above. They do not include raw usage source files, prompts,
transcripts, commands, transcript paths, or external session identifiers.

CodePulse currently exports backups but does not restore them automatically.

Usage Insights exports are separate from backups. They are written only after
the user chooses a destination and are not retained by CodePulse. The default
export excludes workspace and activity labels; users can opt them in for a
specific file. Treat every exported file according to the labels and token/cost
metadata it contains before sharing it.

## Integration deletion and support bundles

**Settings → Integration Data** shows the categories CodePulse holds for local
developer integrations. A confirmed per-tool deletion removes CodePulse's
saved agent runs, usage samples, attributable diagnostics, and reader
checkpoints for that integration, and disables its usage reader. It does not
delete a Codex/Claude/OpenCode source log, user-owned configuration, manual
session, project, or previously exported backup.

The optional redacted support bundle is also a user-chosen local JSON file. It
contains only state schema information, aggregate run/sample counts,
per-integration reader/adapter status, and diagnostic status totals. It never
contains paths, UUIDs, session or source fingerprints, raw event data, prompts,
transcripts, commands, source content, credentials, or freeform session text.
CodePulse does not upload the bundle; inspect it before sharing it manually.

## Deleting data

Individual saved sessions and projects can be removed inside CodePulse. Removing
a project from CodePulse does not delete the project folder. To remove all local
CodePulse state, quit the app and delete its Application Support data; keep any
backup files only if they are still wanted.
