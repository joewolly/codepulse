# Security policy

## Supported versions

Security fixes are made for the latest published CodePulse release and the
current `main` branch. Older releases may be asked to update before a report is
investigated or fixed.

## Reporting a vulnerability

Use GitHub's **Report a vulnerability** link on the repository Security tab when
it is available. If private reporting is not available, open a public issue that
asks for a private contact channel without including vulnerability details. Do
not put credentials, private project data, sensitive logs, or an undisclosed
proof of concept in a public issue.

Include the affected CodePulse version and macOS version, a concise description
of the impact, and reproducible steps when possible. No response-time or fix-time
guarantee is offered, but reports will be assessed and handled according to
their demonstrated impact.

## Security model

CodePulse is a local-first macOS application:

- It has no account system, cloud sync, telemetry, product analytics, or remote
  activity-monitoring service. Optional Session Automation performs local
  workflow detection only when enabled, reacting to explicit Codex/OpenCode
  lifecycle metadata and, for an application rule, the current frontmost
  bundle identifier. It does not monitor application usage history, browsers,
  keyboards, mice, clipboards, or general filesystem activity.
- App state is stored locally in the user's Application Support directory.
- Project access is limited to folders the user selects. CodePulse stores a
  security-scoped bookmark so that access can be restored across launches.
- Git capture invokes `/usr/bin/git` with read-only commands to collect local
  repository metadata and diff statistics. CodePulse does not modify the
  selected repository.
- Exported backups are user-controlled JSON files. They can contain project
  names and paths, settings, session goals and outcomes, Git metadata,
  developer-tool lifecycle metadata, and the current active session. Treat
  backup files as potentially sensitive. The accepted v1.5 backup-v3 contract
  extends this to a bounded collection of active sessions without changing
  the local-only trust model.

### Developer integration boundary

Integration events are untrusted external input. The foundation enforces a
versioned schema, UUID identifiers, bounded event and string sizes, timestamp
sanity limits, canonical absolute paths, known tool/event values, and a bounded
deduplication ledger. Inbox writes use temporary files and atomic moves; files
outside the CodePulse-owned inbox, symbolic links, malformed JSON, unsupported
schemas, and invalid events are rejected or removed without execution.

The helper never executes event content and does not use shell interpolation.
The OpenCode plugin invokes the absolute helper path directly and passes only
the validated structured envelope. Neither adapter reads conversation stores or
content-bearing events. CodePulse only associates an event with an active
session whose selected project's canonical folder contains the event working
directory; timestamps alone are never sufficient, and No Project sessions are
excluded.

When Session Automation is enabled, a validated event can influence only the
CodePulse session lifecycle when it matches a user-created Codex/OpenCode rule
for that configured project. An application rule can influence the same path
only when the current frontmost application's bundle identifier matches its
configured preset/project. Manual sessions have no automation ownership, and
manual lifecycle actions disable control for an automatically started session.
Automation never executes event content, invokes a developer tool, runs a path
from an event, changes repository files, or performs GitHub mutations.

### Accepted v1.5 concurrency boundary (planned, not shipped)

The current 1.4-era implementation has one optional active Session. The
accepted v1.5 contract moves to a bounded collection and requires these
additional integrity boundaries:

- Stable Developer-Tool Thread ownership is `(tool, externalSessionID)`;
  Project names, Project IDs, selected Workspaces, and frontmost applications
  cannot substitute for that identity.
- A Thread can own at most one active automated Session. Duplicate ownership,
  duplicate active UUIDs, and equally valid manual targets fail closed rather
  than selecting an arbitrary Session.
- Every lifecycle mutation resolves one Session UUID. A failure affecting one
  Session cannot bleed into another Session’s phase, outcome, automation
  deadline, save, or history record.
- Active state is bounded (planned maximum: 16 Sessions) before durable
  publication and after decode, migration, backup import, or restore. Malformed
  or replayed events cannot create an unbounded number of Sessions.
- Working-directory ownership continues to use canonical, validated Project
  folder containment. Workspace selection and app focus are navigation/context
  only; they never rescue an unknown path or establish ownership.
- Restore validates every active identifier, timeline, ownership key, and
  Project/Workspace reference before replacement, while preserving the
  existing recovery backup, atomic write/readback, rollback, and unreadable
  state protections.
- Git capture is isolated per Session UUID. Concurrent captures cannot block or
  mutate another Session, and same-repository mutation statistics are
  suppressed for affected Sessions (an explicit ambiguity marker may be shown)
  rather than silently attributed to multiple Threads.
- Existing symlink/path validation, inbox bounds, permissions, event-size and
  timestamp checks, and transactional persistence guarantees remain mandatory;
  concurrency is not a reason to weaken any of them.

### External control boundary

`codepulsectl` is a same-user local client, not a privileged or network service.
It writes only a versioned JSON envelope to the CodePulse-owned control inbox
and waits for a bounded response. The envelope is limited to a schema version,
UUID, issued-at timestamp, and an allowlisted lifecycle action. Preset names,
project names, session types, and optional goals have bounded lengths and safe
text validation; no shell command, path, credential, developer-tool session ID,
or arbitrary file operation is accepted.

The transport uses atomic writes, rejects symbolic-link redirection and files
outside its direct command/response directories, caps pending command and
response storage, and removes malformed input without interpreting it. Commands
older than 30 seconds or issued before the current app launch are rejected.
Mutation responses are persisted with the session-state transaction in a
bounded UUID ledger, then acknowledged through the response inbox. If CodePulse
relaunches before deleting a command, it replays the stored response rather than
running the mutation again. Status requests do not enter the mutation ledger.
The CLI never edits `state.json`, invokes private app files, installs a helper
into a system path, or executes input as a process.

### Transactional backup restore

The **Settings → Data → Restore Backup…** workflow accepts only the supported
versioned JSON envelope and applies a 128 MiB input bound. Required projects,
saved sessions, active-session data, identifiers, and session timelines are
validated strictly; replaceable automation configuration is retained or
disabled fail-safe when it references missing projects or presets. Restore
normalizes machine-local state by clearing the control and developer-event
replay ledgers, relinquishing imported automation ownership, and leaving global
automation disabled. It preserves the current Mac's launch-at-login setting
without calling `SMAppService`.

Before replacing `state.json`, CodePulse creates a uniquely named,
pretty-printed recovery backup under
`~/Library/Application Support/CodePulse/Backups/`, writes it atomically, and
reads it back through the normal backup decoder. Managed state and recovery
directories are checked for symbolic-link redirection and use private 0700
directory/0600 file permissions where supported. The normalized candidate is
written to a same-directory temporary file, decoded and compared, atomically
replaces the live state, and is decoded and compared again before
`SessionStore` changes in memory. If a post-replacement verification fails,
CodePulse atomically attempts rollback from the verified pre-restore state and
reports separately if rollback also fails. User-selected input paths are read
only; they are not used as managed write destinations.

If an existing primary `state.json` cannot be read, CodePulse enters a
read-only recovery mode instead of replacing it with a blank state. Explicit
backup restore first copies the malformed bytes byte-for-byte into a private
`Backups/Unreadable State ...json` recovery file, verifies that copy, and then
uses the same candidate validation, atomic replacement, readback, and rollback
boundaries. Until that explicit restore succeeds, lifecycle, onboarding,
automation, control-command, and integration writes are blocked. An
unreadable-state copy is not a portable backup and is not accepted by the
normal backup decoder.

Codex configuration changes are marked and merged with existing hook entries.
An explicit user `hooks = false` setting is respected. OpenCode installation
uses one marked CodePulse-owned file in the global plugin directory and refuses
to overwrite an unrelated file. Disable removes only the marked CodePulse
configuration. Integration errors are fail-soft and cannot control the timer
or prevent session persistence.

## Updates and distribution

CodePulse uses Sparkle to check GitHub Releases for updates. Update archives are
authenticated with an embedded Ed25519 public key before installation. The
private update-signing key is stored outside the repository as a GitHub Actions
secret and must never be committed.

The current DMG and app are intentionally not Developer ID signed or notarized.
Sparkle authentication protects the in-app update archive, but it does not give
the app a Gatekeeper-trusted Apple developer identity. See
[`docs/releasing.md`](docs/releasing.md) for the packaging, verification, and
first-launch details.

## Scope notes

Reports involving unauthorized access to local state, selected project folders,
the Sparkle update path, release artifacts, or the backup format are in scope.
Social engineering, attacks requiring an already-compromised Mac, and issues in
unsupported third-party software may be closed as out of scope unless they show
a CodePulse-specific security impact.
