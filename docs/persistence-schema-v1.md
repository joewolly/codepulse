# CodePulse persistence baseline (v1)

This document records the persisted shapes that existed before Feature 01. It is
an inventory and migration reference, not a second source of product behavior.

## Main application state

`~/Library/Application Support/CodePulse/state.json` was a raw JSON encoding of
`AppState`, with no top-level schema version. `AppState` contains:

- `projects`: `ProjectRecord` values, including name, optional folder path and
  security-scoped bookmark, creation time, and last-use time.
- `completedSessions`: `CompletedSession` values, including timing, pause
  intervals, optional project snapshot, work type, optional goal/outcome, and
  optional Git, GitHub, and developer-tool metadata.
- `activeSession`: an optional `ActiveSession` with the same timing/context
  fields plus lifecycle phase.
- `settings`: `CodePulseSettings` for launch-at-login, menu-bar appearance,
  default-project behavior, and the global-shortcut setting.
- `developerToolIntegration`: an optional, bounded ledger of processed event
  identifiers and timestamps.

The v1 decoder supplies defaults for newer optional session/settings fields.
Before Feature 01 a missing or malformed file silently produced an empty
`AppState`; it did not expose a recovery option.

## Other persisted surfaces

- **Portable backup:** a user-selected JSON file encoded as `CodePulseBackup`
  (`format: codepulse-backup`, `version: 1`, `exportedAt`, and `state`). Backup
  decoding validates both format and version. Backups are export-only today.
- **UserDefaults:** `menuBarExtraInserted` controls whether the menu-bar item
  is restored at launch. It is deliberately separate from `AppState` and has a
  default of `true`.
- **Developer integration inbox:** individual validated event JSON files live
  under `CodePulse/Integrations/Inbox/`. They are an intake queue, not app
  state, and are independently atomic/best-effort cleaned after processing.
- **Developer-event v2 intake:** Feature 03 adds a separate `InboxV2/` queue
  plus a bounded `InboxV2Receipts/` queue. Receipt files contain only an
  accepted/duplicate/rejected outcome, a salted event fingerprint, safe
  integration/parser versions, and a fixed rejection code; neither queue is
  app state or a raw-hook archive. An installation-scoped fingerprint secret
  is stored with user-only file permissions under `CodePulse/Integrations/`.
- **Integration configuration:** CodePulse-managed Codex/OpenCode hook/plugin
  files live in the respective developer-tool configuration locations. They
  are not decoded as CodePulse state.
- **Codex usage reader (Feature 13):** the `AppState` payload contains the
  off-by-default consent, privacy-safe usage samples, and bounded checkpoints
  holding only salted source/session fingerprints, offsets, model labels, and
  cumulative counters. It never persists raw Codex JSONL paths, IDs, or
  content. Newly added optional/defaulted fields remain backward decodable;
  they do not require a new envelope migration.
- **Claude usage reader (Feature 14):** the `AppState` payload contains a
  separate off-by-default consent, privacy-safe Claude usage samples, and
  bounded checkpoints. It stores only salted source/session/record
  fingerprints, offsets, metadata counters, and calculation provenance—not
  raw JSONL paths, session IDs, transcript paths, or transcript content.
  Newly added optional/defaulted fields remain backward decodable and do not
  require a new envelope migration.
- **OpenCode usage adapter (Feature 15):** the `AppState` payload contains a
  separate off-by-default consent, privacy-safe OpenCode usage samples, and a
  small optional adapter-health state. A transient app-owned inbox under
  `CodePulse/Integrations/OpenCodeUsageInbox/` contains only validated,
  allowlisted plugin handoffs and is deleted after processing. Persisted samples
  retain salted session fingerprints, metadata counters, provider-reported cost,
  and calculation provenance—not raw session/message IDs, message content,
  prompts, tool data, transcripts, source paths, or OpenCode database records.
  Newly added optional/defaulted fields remain backward decodable and do not
  require a new envelope migration.

## v1 fixture policy

`Tests/CodePulseTests/Fixtures/persistence/v1-state.json` is a synthetic,
anonymized fixture based on the v1 state shape. It contains no user paths,
notes, repository identities, external session identifiers, credentials, or
transcript content.

## Versioned schema evolution

Schema v2 wraps `AppState` in `StatePersistenceEnvelope` with
`schemaVersion`, `createdAt`, `migrationHistory`, and `payload`. The explicit
`v1 → v2` migration transforms legacy raw state once, after an atomic `.backup`
copy has been made. Each subsequent save first preserves the last readable file
as that backup. Schema v3 adds the activity graph and migrates legacy projects
and sessions into workspaces, activities, manual runs, and active/waiting
intervals while retaining the legacy payload for compatibility views. Schema v4
adds the bounded, redacted developer-event diagnostics journal. Schema v5 adds
the persisted review-grace preference (default: 180 seconds) and optional,
fingerprint-only agent-run lifecycle metadata. Unknown future versions are left
in place and presented as a non-destructive recovery condition.
