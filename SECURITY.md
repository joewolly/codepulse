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
  activity-monitoring service.
- App state is stored locally in the user's Application Support directory.
- Project access is limited to folders the user selects. CodePulse stores a
  security-scoped bookmark so that access can be restored across launches.
- Git capture invokes `/usr/bin/git` with read-only commands to collect local
  repository metadata and diff statistics. CodePulse does not modify the
  selected repository.
- Exported backups are user-controlled JSON files. They can contain project
  names and paths, settings, session goals and outcomes, Git metadata,
  developer-tool lifecycle metadata, and an active session. Treat backup files
  as potentially sensitive.

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
